extends CanvasLayer
## Developer overlay: resolution, framerate, camera, player, sim and streaming
## state, on one text block toggled with F3. Hidden until asked for, so a
## capture run photographs exactly what it photographed before.
##
## It lives at the project ROOT rather than in `view/` for the same reason
## `iso_camera.gd` does: it owns a `_process`, and `parity/verify.gd`'s
## LAYER_RULES forbids one there. It reads the live objects it is handed and
## writes to none of them.
##
## No `class_name`: a newly added global class is not in Godot's script-class
## cache for a `--path` run until the project is reimported (see
## `view/rig_placement.gd`). main.gd preloads the script instead.

const SECT: int = Sacred.SECT
## Text is rebuilt at this cadence, not every frame -- an unreadable 144 Hz
## flicker of digits is worse than a quarter-second-old one, and cheaper.
const REFRESH := 0.25

var _cam: IsoCamera
var _view: SectorView
var _sim: Sim
var _registry: ActorRegistry
var _label: Label
var _accum := REFRESH


## The label is built HERE rather than in _ready so the overlay is usable the
## moment it is constructed -- a node added to the tree before the tree starts
## running does not get its _ready until the first frame, which is exactly the
## window checks/overlay_check.gd exercises it in.
func _init() -> void:
	layer = 128   # above the taskbar
	visible = false
	var settings := LabelSettings.new()
	settings.font_size = 14
	settings.outline_size = 4
	settings.outline_color = Color.BLACK
	_label = Label.new()
	_label.label_settings = settings
	_label.position = Vector2(8, 8)


func _ready() -> void:
	add_child(_label)


func setup(cam: IsoCamera, view: SectorView, sim: Sim, registry: ActorRegistry) -> void:
	_cam = cam
	_view = view
	_sim = sim
	_registry = registry


func _unhandled_input(e: InputEvent) -> void:
	var k := e as InputEventKey
	if k != null and k.pressed and not k.echo and k.keycode == KEY_F3:
		visible = not visible
		_accum = REFRESH   # redraw on the frame it appears, not a quarter later
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not visible:
		return
	_accum += delta
	if _accum < REFRESH:
		return
	_accum = 0.0
	_label.text = "\n".join(_lines())


func _lines() -> PackedStringArray:
	var out := PackedStringArray()
	var win := DisplayServer.window_get_size()
	# Null whenever this overlay is not in a running tree -- the gate builds it
	# in exactly that state, so every use of it below is guarded rather than
	# assumed.
	var vp := get_viewport()
	out.append("%d fps   %.2f ms process   %.2f ms physics" % [
		Engine.get_frames_per_second(),
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0])
	out.append("window %dx%d   viewport %s" % [win.x, win.y,
		"-" if vp == null else str(vp.get_visible_rect().size)])

	if _cam != null:
		var at := _cam.world_to_cell(Vector2(_cam.position.x, _cam.position.y))
		out.append("cam cell %d,%d (sector %d,%d)   zoom %d = %.2fx   ortho %.0f" % [
			at.x, at.y, at.x / SECT, at.y / SECT,
			_cam.zoom_index, _cam.zoom_scale(), _cam.size])
		if vp != null:
			var mouse := _cam.viewport_to_cell(vp.get_mouse_position())
			out.append("mouse cell %d,%d (sector %d,%d)" % [
				mouse.x, mouse.y, mouse.x / SECT, mouse.y / SECT])

	if _sim != null:
		out.append("sim tick %d @ %d Hz   dropped %d   actors %d" % [
			_sim.tick, _sim.tick_hz, _sim.dropped,
			0 if _registry == null else _registry.count()])
		var player := null if _registry == null else _registry.get_actor(_sim.focus_actor_id)
		if player != null:
			out.append("player #%d cell %.2f,%.2f (sector %d,%d)   hp %d/%d   facing %.2f,%.2f" % [
				player.id, player.cell.x, player.cell.y,
				int(player.cell.x) / SECT, int(player.cell.y) / SECT,
				player.hp, player.hp_max, player.facing.x, player.facing.y])

	# Reads SectorView's own residency fields rather than adding accessors for
	# one read-only caller. is_settled() rebuilds the wanted set, which is why
	# nothing here runs more often than REFRESH.
	if _view != null:
		out.append("sectors %d resident   %d queued   %s" % [
			_view._loaded.size(), _view._pending.size(),
			"settled" if _view.is_settled() else "streaming"])

	out.append("draw %d calls   %d prims   %d objects   %d nodes" % [
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
		Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
		Performance.get_monitor(Performance.OBJECT_NODE_COUNT)])
	out.append("mem %.0f MB static   %.0f MB video   Godot %s" % [
		Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
		Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		Engine.get_version_info()["string"]])
	return out
