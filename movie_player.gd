extends CanvasLayer
## Actual Theora animation + embedded Vorbis through one VideoStreamPlayer.
## The owner, not this controller, suspends simulation/music and restores game/menu.
## Every accepted request emits exactly one returned signal after audio stops
## and its owned conversion worker joins. Back is cancellation, not completion.
## Native evidence: LGP original 0x83D0FB4 selects movie ids; 0x82C9F02
## maps opcode 132 commands 23/24/25 and 100..107; opcode 120 calls 0x82C7012
## (Ancaria ending). These are dispatch facts, not guessed plot conditions.
const MediaCache := preload("res://formats/media_cache.gd")
const NATIVE_MOVIE_IDS := {1: "intro", 2: "extro", 3: "act1", 4: "act2", 5: "act3", 6: "act4", 7: "act5", 8: "act6", 9: "act7", 10: "act8", 11: "extrouw", 12: "introuw"}
const NATIVE_UI_MOVIES := {23: "intro", 24: "introuw", 25: "extrouw", 100: "act1", 101: "act2", 102: "act3", 103: "act4", 104: "act5", 105: "act6", 106: "act7", 107: "act8"}
signal started(movie_id: String, return_owner: StringName)
signal completed(movie_id: String, return_owner: StringName, outcome: StringName)
signal cancelled(movie_id: String, return_owner: StringName)
signal failed(movie_id: String, return_owner: StringName, message: String)
## Canonical owner restoration hook. Connect this OR the above terminal signals,
## not both. Outcomes: ended, skipped, disabled, cancelled, error.
signal returned(movie_id: String, return_owner: StringName, outcome: StringName, message: String)

## Explicit preference: false never means a decoder-error fallback.
var movies_enabled := true
## Executable settings come from trusted launch/config, never session state.
var ffmpeg_executable := "ffmpeg"
var ffprobe_executable := "ffprobe"
var audio_bus: StringName = &"Master"
var volume_db := 0.0
var _cache: MediaCache
var _root: Control
var _video: VideoStreamPlayer
var _status: Label
var _skip_button: Button
var _back_button: Button
var _movie_id := ""
var _return_owner: StringName = &""
var _active := false
var _request_serial := 0
var _preparing := false
var _ending: StringName = &""
var _ratio := 4.0 / 3.0
var _duration := 0.0
var _play_started := 0
var _last_position := 0.0
var _last_progress := 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 110
	_root = Control.new()
	add_child(_root)
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.resized.connect(_layout)
	var background := ColorRect.new()
	background.color = Color.BLACK
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(background)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_video = VideoStreamPlayer.new()
	_video.expand = true
	_video.loop = false
	_video.audio_track = 0
	_video.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_video.finished.connect(_on_video_finished)
	_root.add_child(_video)
	var panel := VBoxContainer.new()
	_root.add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	panel.offset_top = -120
	panel.offset_left = 24
	panel.offset_right = -24
	panel.offset_bottom = -16
	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_constant_override("outline_size", 4)
	_status.add_theme_color_override("font_outline_color", Color.BLACK)
	panel.add_child(_status)
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	panel.add_child(buttons)
	_skip_button = Button.new()
	_skip_button.text = "Skip (Space)"
	_skip_button.custom_minimum_size = Vector2(150, 44)
	_skip_button.pressed.connect(skip)
	buttons.add_child(_skip_button)
	_back_button = Button.new()
	_back_button.text = "Back (Esc)"
	_back_button.custom_minimum_size = Vector2(150, 44)
	_back_button.pressed.connect(cancel)
	buttons.add_child(_back_button)
	_root.hide()
	set_process(false)
	set_process_input(false)

## Empty return means accepted; nonempty means caller must retain its owner.
## Add this node to the tree before calling. The owner token is opaque, never a
## scene/resource path, and is returned unchanged on every terminal outcome.
func play_movie(install: String, movie_id: String, return_owner: StringName) -> String:
	if _active:
		return "movie controller is already active"
	if not is_node_ready():
		return "movie controller must be added and ready before playback"
	if movie_id not in MediaCache.MOVIES:
		return "unknown or unshipped installed movie id: %s" % movie_id
	if AudioServer.get_bus_index(audio_bus) < 0:
		return "movie audio bus does not exist: %s" % audio_bus
	_movie_id = movie_id
	_return_owner = return_owner
	_active = true
	_request_serial += 1
	_ending = &""
	_video.bus = audio_bus
	_video.volume_db = volume_db
	_root.show()
	set_process(true)
	set_process_input(true)
	_back_button.grab_focus()
	if not movies_enabled:
		_status.text = "Movies disabled by preference"
		_deferred_return.call_deferred(&"disabled", "", _request_serial)
		return ""
	_cache = MediaCache.new()
	var problem: String = _cache.begin(install, movie_id, ffmpeg_executable, ffprobe_executable)
	if problem != "":
		_deferred_return.call_deferred(&"error", problem, _request_serial)
		return ""
	_preparing = true
	_skip_button.disabled = false
	_status.text = "Preparing installed movie…"
	return ""

func _deferred_return(outcome: StringName, message: String, request: int) -> void:
	if _active and request == _request_serial:
		if outcome == &"error":
			_fail(message)
		else:
			_finish(outcome, message)

func play_native_ui(install: String, command: int, return_owner: StringName) -> String:
	if not NATIVE_UI_MOVIES.has(command):
		return "native UI command %d is not a verified movie event" % command
	return play_movie(install, NATIVE_UI_MOVIES[command], return_owner)

func play_native_movie(install: String, native_id: int, return_owner: StringName) -> String:
	if not NATIVE_MOVIE_IDS.has(native_id):
		return "native movie id %d is not a single installed movie" % native_id
	return play_movie(install, NATIVE_MOVIE_IDS[native_id], return_owner)

func is_active() -> bool:
	return _active

## The real decoded frame and clock are available to parent capture/smoke tools.
func current_frame() -> Texture2D:
	return _video.get_video_texture() if _video != null else null

func playback_position() -> float:
	return _video.stream_position if _video != null else 0.0

func skip() -> void:
	_request_return(&"skipped")

func cancel() -> void:
	_request_return(&"cancelled")

func _request_return(outcome: StringName) -> void:
	if not _active or _ending != &"":
		return
	_video.stop()
	if _cache != null and _cache.is_busy():
		_ending = outcome
		_cache.cancel()
		_skip_button.disabled = true
		_back_button.disabled = true
		_status.text = "Stopping movie preparation…"
	else:
		_finish(outcome, "")

func _process(_delta: float) -> void:
	if _preparing:
		_status.text = _cache.phase_text() + "…" if _ending == &"" else "Stopping movie preparation…"
		if not _cache.is_complete():
			return
		var result: Dictionary = _cache.take_result()
		_preparing = false
		if _ending != &"":
			_finish(_ending, "")
		elif result.has("error"):
			_fail(result["error"])
		else:
			_start_stream(result)
	elif _active and _video.stream != null:
		var now := Time.get_ticks_msec()
		var position := _video.stream_position
		if position > _last_position + 0.01:
			_last_progress = now
			_last_position = position
		if not _video.is_playing() or now - _last_progress > 5000 or now - _play_started > int((_duration + 10.0) * 1000.0):
			_fail("installed movie playback stopped or stalled before completion")

func _start_stream(result: Dictionary) -> void:
	var info: Dictionary = result["metadata"]
	for stream: Dictionary in info["streams"]:
		if stream.get("codec_type", "") == "video":
			_ratio = float(stream["width"]) / float(stream["height"])
	_duration = float(info["format"]["duration"])
	# Construct a fixed native decoder, never load a path as a Godot Resource.
	var stream := VideoStreamTheora.new()
	stream.file = result["path"]
	_video.stream = stream
	_video.paused = false
	_layout()
	_status.text = ""
	_video.play()
	_play_started = Time.get_ticks_msec()
	_last_progress = _play_started
	_last_position = 0.0
	started.emit(_movie_id, _return_owner)

func _on_video_finished() -> void:
	if not _active or _preparing or _ending != &"":
		return
	# A corrupt decoder ending immediately is not a successful cinematic.
	if _video.stream_position + 1.0 < _duration:
		_fail("installed movie ended before its verified audio/video duration")
	else:
		_finish(&"ended", "")

func _fail(problem: String) -> void:
	if not _active:
		return
	push_error("Movie %s: %s" % [_movie_id, problem])
	_finish(&"error", problem)

func _finish(outcome: StringName, message: String) -> void:
	if not _active:
		return
	if _cache != null:
		_cache.shutdown()
		_cache = null
	_video.stop()
	_video.stream = null
	_root.hide()
	_active = false
	_preparing = false
	_ending = &""
	_skip_button.disabled = false
	_back_button.disabled = false
	set_process(false)
	set_process_input(false)
	var movie_id := _movie_id
	var owner := _return_owner
	_movie_id = ""
	_return_owner = &""
	match outcome:
		&"cancelled":
			cancelled.emit(movie_id, owner)
		&"error":
			failed.emit(movie_id, owner, message)
		_:
			completed.emit(movie_id, owner, outcome)
	returned.emit(movie_id, owner, outcome, message)

func _layout() -> void:
	if _video == null or _root == null:
		return
	var available := _root.size
	var width := minf(available.x, available.y * _ratio)
	_video.size = Vector2(width, width / _ratio)
	_video.position = (available - _video.size) * 0.5

func _input(event: InputEvent) -> void:
	if not _active:
		return
	# Pointer/touch events must reach the overlay's real GUI buttons. Its
	# full-window STOP control consumes them during the subsequent GUI phase.
	if event is InputEventMouse or event is InputEventScreenTouch or event is InputEventScreenDrag:
		return
	# Consume movie input before underlying gameplay _unhandled_input sees it.
	# Parent must gate its own _input handlers while is_active() is true.
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			cancel()
		elif event.keycode in [KEY_SPACE, KEY_ENTER, KEY_KP_ENTER]:
			skip()
	elif event is InputEventJoypadButton and event.pressed:
		if event.button_index == JOY_BUTTON_B:
			cancel()
		elif event.button_index == JOY_BUTTON_A:
			skip()
	get_viewport().set_input_as_handled()

func _exit_tree() -> void:
	if _cache != null:
		_cache.shutdown()
		_cache = null
	if _video != null:
		_video.stop()
	if _active:
		_active = false
		cancelled.emit(_movie_id, _return_owner)
		returned.emit(_movie_id, _return_owner, &"cancelled", "")
