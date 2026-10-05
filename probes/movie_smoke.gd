extends "res://checks/check.gd"
## Explicit opt-in, real installed media smoke; NOT a headless forwarding test.
## Captures decoded frames under user:// and measures nonzero embedded audio
## on an isolated bus. Native route selection drives the production controller.
## --movie=intro|introuw --movie-ui=100|25 --movie-native=2
## --movie-action=skip|cancel|end --movie-disabled --movie-cache-replacement
## Run explicitly, outside run.sh's headless *_check.gd suite:
## godot --path godot-port --script res://probes/movie_smoke.gd -- --movie=intro --movie-action=skip
## Output movie_smoke records outcome, differing frame count, measured audio
## peak and preserved owner; movie_replacement records old/new exact cache keys.
## Disabled/preparation-cancellation cases validate their own outcomes, never
## count as evidence that a cinematic actually animated with embedded audio.
const SacredData := preload("res://sacred.gd")
const Profile := preload("res://formats/mod_manifest.gd")
const MoviePlayer := preload("res://movie_player.gd")
const MediaCache := preload("res://formats/media_cache.gd")
var _options: Dictionary = {}
var _player: MoviePlayer
var _capture: AudioEffectCapture
var _bus := -1
var _returned: Dictionary = {}
var _return_count := 0
var _peak := 0.0
var _hashes: Array[String] = []
var _capture_count := 0

func _init() -> void:
	super()
	allow_frames(900000)
	for argument: String in OS.get_cmdline_user_args():
		var parts := argument.trim_prefix("--").split("=", true, 1)
		_options[parts[0]] = parts[1] if parts.size() == 2 else "true"
	_run.call_deferred()

func _run() -> void:
	var install := SacredData.find_install()
	if not expect(install != "", "installed retail content is required"):
		finish(1)
		return
	if _options.has("movie-cache-replacement"):
		await _replacement(install)
		finish()
		return
	if not expect(DisplayServer.get_name() != "headless" or _options.has("movie-disabled") or _options.has("movie-cancel-preparation"), "animation/audio smoke needs a display and actual audio driver"):
		finish(1)
		return
	var action: String = _options.get("movie-action", "skip")
	if not expect(action in ["skip", "cancel", "end"], "movie action must be skip, cancel or end"):
		finish(1)
		return
	var profile := Profile.new(install)
	if not expect(SacredData.Pak.configure_profile(profile) == "", profile.error_text()):
		finish(1)
		return
	root.size = Vector2i(960, 720)
	_bus = AudioServer.bus_count
	AudioServer.add_bus()
	AudioServer.set_bus_name(_bus, "MovieSmoke")
	_capture = AudioEffectCapture.new()
	_capture.buffer_length = 0.5
	AudioServer.add_bus_effect(_bus, _capture)
	_player = MoviePlayer.new()
	_player.audio_bus = &"MovieSmoke"
	_player.movies_enabled = not _options.has("movie-disabled")
	_player.returned.connect(_on_returned)
	root.add_child(_player)
	await process_frame
	# A paused gameplay tree must not pause the dedicated movie/audio controller.
	paused = true
	var movie_id: String = _options.get("movie", "intro")
	var problem: String
	if _options.has("movie-ui"):
		problem = _player.play_native_ui(install, int(_options["movie-ui"]), &"extras-smoke")
	elif _options.has("movie-native"):
		problem = _player.play_native_movie(install, int(_options["movie-native"]), &"extras-smoke")
	else:
		problem = _player.play_movie(install, movie_id, &"extras-smoke")
	if not expect(problem == "", problem):
		_cleanup()
		finish(1)
		return
	var request_time := Time.get_ticks_msec()
	var cancel_preparation := _options.has("movie-cancel-preparation")
	var cancel_after := 200 if _options.get("movie-cancel-preparation", "true") == "true" else int(_options["movie-cancel-preparation"])
	while _player.is_active():
		_collect_audio()
		var position: float = _player.playback_position()
		if cancel_preparation and Time.get_ticks_msec() - request_time >= cancel_after:
			_player.cancel()
		if _capture_count < 2 and position >= 2.0 + 2.0 * _capture_count:
			_capture_frame()
		if position >= 6.0 and action != "end":
			if action == "skip":
				_player.skip()
			else:
				_player.cancel()
		await process_frame
	expect(_return_count == 1, "accepted movie request must return exactly once")
	expect(_returned.get("owner") == &"extras-smoke", "movie must preserve its exact opaque owner")
	var expected := &"disabled" if _options.has("movie-disabled") else (&"cancelled" if cancel_preparation else (&"skipped" if action == "skip" else (&"cancelled" if action == "cancel" else &"ended")))
	expect(_returned.get("outcome") == expected, "expected %s, got %s: %s" % [expected, _returned.get("outcome"), _returned.get("message")])
	if not _options.has("movie-disabled") and not cancel_preparation:
		expect(_hashes.size() == 2 and _hashes[0] != _hashes[1], "two actual decoded frames must differ")
		expect(_peak > 0.0001, "embedded audio must produce nonzero mixer samples; peak=%f" % _peak)
		_capture.clear_buffer()
		await create_timer(0.25, true).timeout
		var tail := _capture.get_buffer(_capture.get_frames_available())
		var tail_peak := 0.0
		for sample: Vector2 in tail:
			tail_peak = maxf(tail_peak, maxf(absf(sample.x), absf(sample.y)))
		expect(tail_peak < 0.0001, "movie return must stop its embedded audio; peak=%f" % tail_peak)
	print("movie_smoke\tmovie=%s\toutcome=%s\tframes=%d\taudio_peak=%f\towner=%s" % [_returned.get("movie"), _returned.get("outcome"), _hashes.size(), _peak, _returned.get("owner")])
	_cleanup()
	finish()

func _on_returned(movie_id: String, owner: StringName, outcome: StringName, message: String) -> void:
	_return_count += 1
	_returned = {"movie": movie_id, "owner": owner, "outcome": outcome, "message": message}

func _collect_audio() -> void:
	var frames := _capture.get_frames_available()
	if frames <= 0:
		return
	for sample: Vector2 in _capture.get_buffer(frames):
		_peak = maxf(_peak, maxf(absf(sample.x), absf(sample.y)))

func _capture_frame() -> void:
	var texture: Texture2D = _player.current_frame()
	if not expect(texture != null, "movie frame must be a real decoder texture"):
		return
	var image := texture.get_image()
	if not expect(image != null and not image.is_empty(), "decoder texture must contain actual pixels"):
		return
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(image.get_data())
	_hashes.append(hash.finish().hex_encode())
	var directory := ProjectSettings.globalize_path("user://media-check/frames")
	DirAccess.make_dir_recursive_absolute(directory)
	var movie_id: String = _options.get("movie", "native-route")
	# Never incorporate an unvalidated CLI path into the capture destination.
	var tag := movie_id if movie_id in MediaCache.MOVIES else "native-route"
	var path := directory.path_join("%s-%d.png" % [tag, _capture_count])
	expect(image.save_png(path) == OK, "actual frame capture must write %s" % path)
	_capture_count += 1

func _cleanup() -> void:
	paused = false
	if is_instance_valid(_player):
		_player.free()
	if _bus >= 0:
		AudioServer.remove_bus(_bus)
	SacredData.Pak.clear_profile()

## Same basename + same logical id but different actual installed bytes: path,
## timestamps or movie id must never suffice to reuse the old decoded stream.
func _replacement(install: String) -> void:
	SacredData.Pak.clear_profile()
	var root_path := ProjectSettings.globalize_path("user://media-check/replacement")
	var directory := root_path.path_join("movie")
	if not expect(DirAccess.make_dir_recursive_absolute(directory) == OK, "replacement fixture directory must be user-local"):
		return
	var target := directory.path_join("intro.mpg")
	var cache := MediaCache.new()
	var results: Array[Dictionary] = []
	for name: String in ["intro", "introuw"]:
		var source := install.path_join("movie/%s.mpg" % name)
		if not expect(DirAccess.copy_absolute(source, target) == OK, "fixture must copy actual installed %s" % name):
			break
		var problem := cache.begin(root_path, "intro")
		if not expect(problem == "", problem):
			break
		while not cache.is_complete():
			await process_frame
		var result := cache.take_result()
		if not expect(not result.has("error"), str(result.get("error", ""))):
			break
		results.append(result)
	if results.size() == 2:
		expect(results[0]["path"] != results[1]["path"], "same-path replacement must produce a different content-addressed entry")
		expect(results[0]["metadata"]["source_sha256"] != results[1]["metadata"]["source_sha256"], "cache identities must be exact actual source hashes")
		print("movie_replacement\told=%s\tnew=%s" % [results[0]["metadata"]["key"], results[1]["metadata"]["key"]])
	cache.shutdown()
	DirAccess.remove_absolute(target)
	DirAccess.remove_absolute(directory)
	DirAccess.remove_absolute(root_path)
