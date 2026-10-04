extends CanvasLayer
## Exact profile hashing runs on one owned worker with private file cursors.
## Nothing mounts or constructs gameplay until the main thread joins it.
const Profile := preload("res://formats/mod_manifest.gd")
var _worker: Thread
var _label: Label

func prepare(install: String, roots: Array[String]) -> RefCounted:
	# Batch/CI quit-after counts frames; preserve its synchronous startup contract.
	if DisplayServer.get_name() == "headless":
		return Profile.new(install, roots)
	layer = 100
	var centre := CenterContainer.new()
	add_child(centre)
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label = Label.new()
	_label.text = "Verifying retail resources and mod profile…"
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", 22)
	_label.add_theme_constant_override("outline_size", 4)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	centre.add_child(_label)
	_worker = Thread.new()
	var error := _worker.start(_build_profile.bind(install, roots))
	if error != OK:
		push_error("content verification worker: %s" % error_string(error))
		_worker = null
		return null
	var started := Time.get_ticks_msec()
	var last_second := -1
	while _worker.is_alive():
		var second := (Time.get_ticks_msec() - started) / 1000
		if second != last_second:
			_label.text = "Verifying retail resources and mod profile… %d s" % second
			last_second = second
		await get_tree().process_frame
		if not is_inside_tree():
			return null
	var result: RefCounted = _worker.wait_to_finish()
	_worker = null
	return result

static func _build_profile(install: String, roots: Array[String]) -> RefCounted:
	return Profile.new(install, roots)

func _exit_tree() -> void:
	# The worker never reads this node or the active scene tree. Join every exit
	# path before its owner disappears; do not abandon a hashing task on quit.
	if _worker != null:
		_worker.wait_to_finish()
		_worker = null
