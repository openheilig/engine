class_name IsoCamera
extends Camera3D
## Orthographic camera over Sacred's isometric cell grid.
##
## The projection is  sx = (x-y)*HW,  sy = -(x+y)*HH, so world units here are
## retail screen pixels at 1x zoom. HW/HH come from the terrain atlas lattice
## (Sacred.slot_uv): diamonds are 100 wide and 50 tall, packed on a 104/52/25
## grid. Everything the streamer needs to know about what is on screen comes
## from visible_cells().

## The true iso cell is 96x48. Not derived from the terrain atlas -- that gives
## 104x50, which is the slot PITCH including padding, and 100x49 of drawn art,
## which overlaps its cell by ~2 px the way hand-authored iso tiles usually do.
## 96x48 comes from the object data, which is ground truth: fitting every static
## object's stored position against its cell gives ox = 48.0058*(cx-cy) and
## oy = 24.0235*(cx+cy) over 32428 samples, with the residual quantised to
## sub-cell offsets. Terrain geometry uses these; the art is sampled from the
## 100x49 bbox and so is squeezed ~4%, which is invisible and keeps the corner
## sharing that the height field depends on.
const HW := 48.0    ## iso half-width
const HH := 24.0    ## iso half-height

## Cell coordinate limits. Sacred's world is 100x100 sectors of 64 cells.
@export var cell_limit := Vector2(6400.0, 6400.0)
@export var pan_speed := 900.0        ## world units/second at the widest zoom

## Sacred has THREE discrete zoom steps, not a continuous zoom, and the wheel
## steps between them. Values are scale factors: 1.0 draws one world unit per
## screen pixel, which is the engine's native size since world units here ARE
## retail screen pixels.
##
## MEASURED from the retail game, 2026-08-07, not guessed. Method: added mouse
## wheel support to install/shim/autopilot.c (SDL 1.2 buttons 4/5), loaded the
## shipped save headlessly under Xvfb, stepped the wheel and captured each step,
## then recovered the ratio by resizing one capture until it best correlated
## with the next. One step down is 0.50x (corr 0.84) and one step up is 2.00x
## (corr 0.96); further steps in either direction change nothing, confirming
## exactly three levels. Which one is native comes from the tile pitch in the
## reference screenshots -- 48 px, i.e. the 96x48 cell -- so the MIDDLE step is
## 1:1, the closest upscales 2x and the widest halves.
const ZOOM_SCALES: Array[float] = [2.0, 1.0, 0.5]

## Bounding the zoom bounds the number of streamed sectors, which is what
## stopped the texture cache thrashing at the old 12000 free-zoom.
var zoom_index := 0

signal move_click(cell: Vector2i)

## Input Map actions, defined in project.godot [input] (WASD + arrows). Held as
## StringName literals so the per-frame Input.get_vector does not allocate.
const PAN_LEFT := &"iso_left"
const PAN_RIGHT := &"iso_right"
const PAN_UP := &"iso_up"
const PAN_DOWN := &"iso_down"


func _ready() -> void:
	projection = PROJECTION_ORTHOGONAL
	far = 4000.0
	for action: StringName in [PAN_LEFT, PAN_RIGHT, PAN_UP, PAN_DOWN]:
		if not InputMap.has_action(action):
			push_error("IsoCamera: action '%s' missing from the Input Map "
				% action + "(project.godot [input]). Panning will not work.")


## Camera panning is visual, not simulation, so it belongs in _process --
## _physics_process would tie it to the fixed tick and judder on other refresh
## rates. (Continuous *gameplay* movement is the case that wants physics.)
func _process(delta: float) -> void:
	var dir := Input.get_vector(PAN_LEFT, PAN_RIGHT, PAN_DOWN, PAN_UP)
	if dir != Vector2.ZERO:
		_move(dir * pan_speed * delta / zoom_scale())


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion and e.button_mask & MOUSE_BUTTON_MASK_LEFT:
		_move(Vector2(-e.relative.x, e.relative.y) * (size / 1000.0))
	elif e is InputEventMouseButton and e.pressed:
		if e.button_index == MOUSE_BUTTON_WHEEL_UP:
			set_zoom_index(zoom_index - 1)
		elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			set_zoom_index(zoom_index + 1)
		elif e.button_index == MOUSE_BUTTON_LEFT:
			move_click.emit(viewport_to_cell(e.position))
			get_viewport().set_input_as_handled()


## Centre the view on a cell coordinate.
func look_at_cell(cell: Vector2) -> void:
	var p := cell_to_world(cell)
	position = Vector3(p.x, p.y, 1000.0)


## Follow entry point for a continuously-moving target (the player), added
## beside look_at_cell rather than folded into it -- --at=, --sector= and the
## probe route all call look_at_cell directly and must keep placing the
## camera exactly where they place it today.
##
## The player's cell is continuous; the camera's position is not allowed to
## be, or every pixel comparison this project makes becomes meaningless. At
## scale s a world-integer point lands on a pixel integer only when the
## camera's own coordinate is itself a multiple of 1/s, so the snapped
## coordinate is the world coordinate times s, rounded, divided by s. At the
## middle zoom step (s=1.0) that is exactly "round to the nearest whole
## world unit" -- Success Criterion 4's case -- and the same formula covers
## the other two measured steps without special-casing any of them.
##
## Half the viewport enters the same arithmetic (`position` is the view's
## centre), so an odd viewport height puts the centre on a half pixel no
## matter how the camera itself is snapped -- checked here at follow time
## and reported with push_error rather than silently rendering a frame that
## cannot be compared, the same runtime-check-not-assert posture the sim's
## radius ordering uses.
func follow_cell(cell: Vector2) -> void:
	var h := get_viewport().get_visible_rect().size.y
	if int(h) % 2 != 0:
		push_error("IsoCamera: viewport height %d is odd -- the view centre falls on a half pixel, breaking follow's pixel-grid snap" % int(h))
	var p := cell_to_world(cell)
	var s := zoom_scale()
	position = Vector3(roundf(p.x * s) / s, roundf(p.y * s) / s, 1000.0)


static func cell_to_world(cell: Vector2) -> Vector2:
	return Vector2((cell.x - cell.y) * HW, -(cell.x + cell.y) * HH)


static func world_to_cell(w: Vector2) -> Vector2:
	var u := w.x / HW      # x - y
	var v := -w.y / HH     # x + y
	return Vector2((v + u) * 0.5, (v - u) * 0.5)


## Converts a viewport click to the containing world cell. Orthographic camera
## projection is renderer-independent here: the viewport centre maps to the
## camera's XY position, and screen-down maps to decreasing world Y.
func viewport_to_cell(viewport_position: Vector2) -> Vector2i:
	var viewport_size := get_viewport().get_visible_rect().size
	var world := viewport_to_world(viewport_position, viewport_size,
		Vector2(position.x, position.y), size)
	var cell := world_to_cell(world)
	return Vector2i(floori(cell.x), floori(cell.y))


## Pure form used by the deterministic click-equivalent check as well as the
## node method above. `camera_world` is the camera XY position and `camera_size`
## is the orthographic world height visible in the viewport.
static func viewport_to_world(viewport_position: Vector2, viewport_size: Vector2,
		camera_world: Vector2, camera_size: float) -> Vector2:
	var scale := camera_size / viewport_size.y if viewport_size.y > 0.0 else 1.0
	var centre := viewport_size * 0.5
	return camera_world + Vector2(
		(viewport_position.x - centre.x) * scale,
		-(viewport_position.y - centre.y) * scale)


## Cell-space bounding box of what the viewport currently covers, grown by
## `margin` cells. The iso projection turns the screen rectangle into a diamond
## in cell space, so this is the diamond's AABB -- deliberately generous.
func visible_cells(margin: float = 0.0) -> Rect2:
	var half_y := size * 0.5
	var half_x := half_y * _aspect()
	var c := Vector2(position.x, position.y)
	var box := Rect2()
	for i in 4:
		var corner := c + Vector2(half_x if i & 1 else -half_x, half_y if i & 2 else -half_y)
		var cell := world_to_cell(corner)
		if i == 0:
			box = Rect2(cell, Vector2.ZERO)
		else:
			box = box.expand(cell)
	return box.grow(margin)


func _aspect() -> float:
	var vp := get_viewport().get_visible_rect().size
	return vp.x / vp.y if vp.y > 0.0 else 1.0


func _move(screen_delta: Vector2) -> void:
	var p := Vector2(position.x, position.y) + screen_delta
	# Clamp in cell space, not screen space: the world is a diamond on screen.
	var cell := world_to_cell(p).clamp(Vector2.ZERO, cell_limit)
	var w := cell_to_world(cell)
	position = Vector3(w.x, w.y, position.z)


## Snap to one of Sacred's three zoom steps. Orthographic `size` is the world
## height the viewport covers, so at scale 1.0 that is the viewport's pixel
## height and one world unit lands on one pixel.
func set_zoom_index(i: int) -> void:
	zoom_index = clampi(i, 0, ZOOM_SCALES.size() - 1)
	size = get_viewport().get_visible_rect().size.y / ZOOM_SCALES[zoom_index]


func zoom_scale() -> float:
	return ZOOM_SCALES[zoom_index]
