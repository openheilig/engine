class_name IsoCamera
extends Camera3D
## Orthographic camera over Sacred's isometric cell grid.
##
## The projection is  sx = (x-y)*HW,  sy = -(x+y)*HH, so world units here are
## retail screen pixels at 1x zoom. HW/HH describe the 96x48 world lattice,
## not the padded terrain atlas. Everything the streamer needs to know about
## what is on screen comes from visible_cells().

## The true iso cell is 96x48. Not derived from the terrain atlas -- that gives
## 104x50, which is the slot PITCH including padding, and 100x49 of drawn art,
## which overlaps its cell by ~2 px the way hand-authored iso tiles usually do.
## 96x48 comes from the object data, which is ground truth: fitting every static
## object's stored position against its cell gives ox = 48.0058*(cx-cy) and
## oy = 24.0235*(cx+cy) over 32428 samples, with the residual quantised to
## sub-cell offsets. Terrain samples retail's four asymmetric atlas UV tips
## and renders each cell with a 0.2-pixel overdraw margin at its tips.
const HW := 48.0    ## iso half-width
const HH := 24.0    ## iso half-height

## Retail centres its view ONE WORLD UNIT up-left of cell_to_world's answer,
## and this constant is the follow ANCHOR: the offset between the follow
## target and the view centre, in world units.
##
## MEASURED twice, agreeing. 2026-08-16: retail driven to the Seraphim's
## campaign start, both engines captured, and the port's frame was retail's
## frame translated by exactly (1,1) screen pixels -- a bare wall patch became
## bit-identical after the shift (mean |delta| = 0.00 over 80x100 px). Row
## 1104 then measured hero centroids within 0.5 px on independent runs. The
## offset DOUBLES with the zoom step (shift=1,1 at 1.0x, shift=2,2 at 2.0x,
## drive-serazoom2), which is what a world-unit constant does and a
## screen-space one cannot.
##
## What owns the unit is no longer open: the apitrace of the walking game
## (tmp/apitrace/walk.trace, 2026-08-29) shows retail has NO camera matrix --
## a fixed glOrtho(0,1024,768,0) for the whole session and the scroll living
## in the modelview translation, i.e. everything is CPU-transformed into
## screen pixels exactly as this port does. The modelview translation series
## across the walk is the follow law transcribed below; this constant is that
## law's rest offset, and it sits here, not in cell_to_world, because it
## belongs to the view and not to the geometry.
const VIEW_ORIGIN := Vector2(-1.0, 1.0)

## The follow ease, transcribed from the same walk trace as the law below:
## each update halves the remaining distance to the target (measured steps
## 34.94, 17.21, 8.87, 4.17, 2.08, 1.05, 0.52 -- ratios 0.49-0.51), i.e.
## cam += (target - cam) * 0.5 once per sim tick, pixel-quantized at render.
const FOLLOW_K := 0.5

## Beyond this many world units of follow distance the ease is bypassed and
## the camera snaps. Retail never crossed a teleport while followed in the
## captured runs, so the eased law is unmeasured there; 40 cells is far
## beyond any walk a click can produce and far below any sector jump.
const TELEPORT_SNAP_DIST := 1920.0

## The eased camera's continuous world position (pre-pixel-snap). Rendered
## position is always the snapped one; this carries the ease between ticks.
var _cam_world := Vector2.ZERO
var _cam_valid := false

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
	# `size` is DERIVED from viewport height (see set_zoom_index), so a resize
	# invalidates it. Without this the camera keeps snapping to a grid that is
	# no longer the pixel grid -- follow_cell's whole reason to exist -- and it
	# does so silently, which is the one failure mode this class is written to
	# refuse. Guarded because _ready runs again on re-parent and a second
	# connect to the same callable is an error.
	var vp := get_viewport()
	if vp != null and not vp.size_changed.is_connected(_on_viewport_resized):
		vp.size_changed.connect(_on_viewport_resized)
	set_zoom_index(zoom_index)


## Re-derives `size` from the new viewport height, keeping the current step.
func _on_viewport_resized() -> void:
	set_zoom_index(zoom_index)


## Camera panning is visual, not simulation, so it belongs in _process --
## _physics_process would tie it to the fixed tick and judder on other refresh
## rates. (Continuous *gameplay* movement is the case that wants physics.)
func _process(delta: float) -> void:
	var dir := Input.get_vector(PAN_LEFT, PAN_RIGHT, PAN_DOWN, PAN_UP)
	if dir != Vector2.ZERO:
		_move(dir * pan_speed * delta / zoom_scale())


## The cell the current left-drag last re-targeted, so holding the button still
## while the pointer jitters inside one cell does not re-path every motion
## event. Reset on release so the next drag always re-targets at least once.
var _drag_cell := Vector2i(-1, -1)


## LEFT DRAG WALKS, IT DOES NOT PAN. Holding the button and moving the pointer
## re-targets the hero every time the pointer crosses into a new cell, which is
## the continuous "keep walking where I point" this genre runs on and what the
## port was missing -- a single click could only ever schedule one path.
##
## Panning the camera on left-drag, which this did before, was already DEAD in
## normal play and not a behaviour being taken away: main.gd:735 calls
## follow_cell(p.cell) every tick, so any drag-pan was overwritten before the
## next frame. It survives on MIDDLE drag, where it is actually reachable --
## the --at=/--sector= inspection modes build no player and so never follow.
func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion and e.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
		_move(Vector2(-e.relative.x, e.relative.y) * (size / 1000.0))
	elif e is InputEventMouseMotion and e.button_mask & MOUSE_BUTTON_MASK_LEFT:
		var cell := viewport_to_cell(e.position)
		if cell != _drag_cell:
			_drag_cell = cell
			move_click.emit(cell)
			get_viewport().set_input_as_handled()
	elif e is InputEventMouseButton:
		if not e.pressed:
			if e.button_index == MOUSE_BUTTON_LEFT:
				_drag_cell = Vector2i(-1, -1)
			return
		if e.button_index == MOUSE_BUTTON_WHEEL_UP:
			set_zoom_index(zoom_index - 1)
		elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			set_zoom_index(zoom_index + 1)
		elif e.button_index == MOUSE_BUTTON_LEFT:
			_drag_cell = viewport_to_cell(e.position)
			move_click.emit(_drag_cell)
			get_viewport().set_input_as_handled()


## Centre the view on a cell coordinate.
func look_at_cell(cell: Vector2) -> void:
	var p := cell_to_world(cell) + VIEW_ORIGIN
	position = Vector3(p.x, p.y, 1000.0)


## Follow entry point for a continuously-moving target (the player), added
## beside look_at_cell rather than folded into it -- --at=, --sector= and the
## probe route all call look_at_cell directly and must keep placing the
## camera exactly where they place it today.
## Retail's follow law, transcribed from an apitrace of the walking game
## (tmp/apitrace/walk.trace, 2026-08-29; findings row 1189). The camera eases
## toward the follow target, HALVING the remaining distance each update --
## the trace's remaining steps run 34.94, 17.21, 8.87, 4.17, 2.08, 1.05,
## 0.52, 0.52 world units across eight updates and then rest exactly -- and
## the rendered position is quantized to whole screen pixels (the tail steps
## are 0.5215 world units = one pixel at the 1.0 zoom step). Retail updates
## once per sim tick: in the trace each camera position holds for exactly two
## rendered frames. There is no cell snapping anywhere in it; the old
## per-tick cell snap this replaces jumped the view 48 px at every cell
## boundary, which is the judder that made motion look wrong.
##
## The player's cell is continuous; the camera's position is still not
## allowed to carry sub-pixel information, or every pixel comparison this
## project makes becomes meaningless. At scale s a world-integer point lands
## on a pixel integer only when the camera's own coordinate is itself a
## multiple of 1/s, so after the ease the coordinate is snapped: world times
## s, rounded, divided by s. Half the viewport enters the same arithmetic
## (`position` is the view's centre), so an odd viewport height puts the
## centre on a half pixel no matter how the camera is snapped -- checked
## here and reported with push_error rather than silently rendering a frame
## that cannot be compared.
func follow_cell(cell: Vector2) -> void:
	var h := get_viewport().get_visible_rect().size.y
	if int(h) % 2 != 0:
		push_error("IsoCamera: viewport height %d is odd -- the view centre falls on a half pixel, breaking follow's pixel-grid snap" % int(h))
	var target := cell_to_world(cell) + VIEW_ORIGIN
	if not _cam_valid:
		# First frame after a load follows retail's first world frame: the
		# view is already settled on the hero, not easing in from anywhere.
		_cam_world = target
		_cam_valid = true
	elif _cam_world.distance_to(target) > TELEPORT_SNAP_DIST:
		# ponytail: retail was never observed crossing a teleport while
		# followed, so the law for it is unmeasured; snap rather than ease
		# across the map. Ceiling: revisited when a teleport capture exists.
		_cam_world = target
	else:
		_cam_world += (target - _cam_world) * FOLLOW_K
	var s := zoom_scale()
	position = Vector3(roundf(_cam_world.x * s) / s, roundf(_cam_world.y * s) / s, 1000.0)



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
