extends RefCounted
## User-local conversion, not an engine import or a ResourceLoader entry point.
## Host ffmpeg/ffprobe are independently installed executables; never bundled.
## Source: LGP install/movie MPEG-1 + MP2 (research row 84); Bink is accepted
## only when the installed host actually decodes its video AND embedded audio.
## Recipe changes require a new version. No commercial media belongs in res://.
const Pak := preload("res://formats/pak.gd")
const MOVIES := ["intro", "introuw", "act1", "act2", "act3", "act4", "extro", "extrouw", "ascaron", "oem"]
const CACHE_ROOT := "user://media/theora-v1"
const RECIPE := "theora-v1:yuv420p:qv7:vorbis-qa5:44100-stereo:original-timestamps"
const MAX_BYTES := 512 * 1024 * 1024
const MAX_SECONDS := 600.0
const DEADLINE_MSEC := 300000
const LOG_BYTES := 65536
var _thread: Thread
var _mutex := Mutex.new()
var _cancelled := false
var _started := 0
var _phase := ""

## Call only on the main thread; logical ids, never paths from saved state.
func begin(install: String, movie_id: String, ffmpeg: String = "ffmpeg", ffprobe: String = "ffprobe") -> String:
	if _thread != null:
		return "a media conversion is already active"
	if movie_id not in MOVIES:
		return "unknown installed movie id: %s" % movie_id
	var source := _source(install, movie_id)
	if source == "":
		return "missing or unsafe installed movie: %s (expected movie/%s.mpg or .bik)" % [movie_id, movie_id]
	_cancelled = false
	_started = Time.get_ticks_msec()
	_thread = Thread.new()
	var error := _thread.start(_prepare.bind(source, movie_id, ffmpeg, ffprobe))
	if error != OK:
		_thread = null
		return "cannot start media worker: %s" % error_string(error)
	return ""

func is_busy() -> bool:
	return _thread != null

func is_complete() -> bool:
	return _thread != null and not _thread.is_alive()

## Non-blocking callers check is_complete first. Exit owners cancel then join.
func take_result() -> Dictionary:
	if not is_complete():
		return {}
	var result: Dictionary = _thread.wait_to_finish()
	_thread = null
	return result

func cancel() -> void:
	_mutex.lock()
	_cancelled = true
	_mutex.unlock()

func shutdown() -> void:
	cancel()
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null

func phase_text() -> String:
	_mutex.lock()
	var value := _phase
	_mutex.unlock()
	return value

func _set_phase(value: String) -> void:
	_mutex.lock()
	_phase = value
	_mutex.unlock()

func _stopped() -> bool:
	_mutex.lock()
	var value := _cancelled
	_mutex.unlock()
	return value or Time.get_ticks_msec() - _started > DEADLINE_MSEC

func _stop_error() -> String:
	_mutex.lock()
	var value := _cancelled
	_mutex.unlock()
	return "media preparation cancelled" if value else "media preparation exceeded 300 seconds"

static func _absolute(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		return ProjectSettings.globalize_path(path).simplify_path().trim_suffix("/")
	return (path if path.is_absolute_path() else OS.get_environment("PWD").path_join(path)).simplify_path().trim_suffix("/")

static func _has_link(path: String) -> bool:
	var current := path
	while current != "" and current != current.get_base_dir():
		var parent := DirAccess.open(current.get_base_dir())
		if parent != null and parent.is_link(current.get_file()):
			return true
		current = current.get_base_dir()
	return false

static func _source(install: String, movie_id: String) -> String:
	var root := _absolute(install)
	if _has_link(root):
		return ""
	var parent_dir := DirAccess.open(root)
	if parent_dir == null:
		return ""
	var directories: Array[String] = []
	for name: String in parent_dir.get_directories():
		if name.to_lower() == "movie":
			directories.append(name)
	if directories.size() != 1:
		return ""
	var directory := root.path_join(directories[0])
	if _has_link(directory):
		return ""
	# Match retail's case-insensitive logical names without accepting a path.
	var dir := DirAccess.open(directory)
	if dir == null:
		return ""
	for extension: String in ["mpg", "bik"]:
		var candidates: Array[String] = []
		for file: String in dir.get_files():
			if file.to_lower() == movie_id + "." + extension:
				candidates.append(file)
		if candidates.size() > 1:
			return ""
		if candidates.size() == 1:
			var logical := directory.path_join(candidates[0])
			var resolved := _absolute(Pak.resolve(logical))
			if resolved != logical or _has_link(resolved):
				return ""
			return resolved
	return ""

func _prepare(source: String, movie_id: String, ffmpeg: String, ffprobe: String) -> Dictionary:
	var root := _absolute(CACHE_ROOT)
	if _has_link(root) or DirAccess.make_dir_recursive_absolute(root) != OK:
		return {"error": "cannot create safe user media cache: %s" % root}
	var work := root.path_join("work-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	if DirAccess.make_dir_absolute(work) != OK:
		return {"error": "cannot create private media work directory"}
	var result := _convert(source, movie_id, ffmpeg, ffprobe, root, work)
	# All paths are fixed names under this worker's private directory.
	for name: String in ["source.mpg", "source.bik", "movie.ogv", "metadata.json"]:
		var path := work.path_join(name)
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	if DirAccess.dir_exists_absolute(work):
		DirAccess.remove_absolute(work)
	return result

func _convert(source: String, movie_id: String, ffmpeg: String, ffprobe: String, root: String, work: String) -> Dictionary:
	_set_phase("Hashing installed movie")
	var fingerprint := _hash(source)
	if fingerprint.has("error"):
		return fingerprint
	var version := _run(ffmpeg, PackedStringArray(["-version"]))
	if version.has("error"):
		return version
	var probe_version := _run(ffprobe, PackedStringArray(["-version"]))
	if probe_version.has("error"):
		return probe_version
	var identity := "%s\n%s\n%s\n%s\n%s" % [fingerprint["sha256"], RECIPE, version["stdout"], probe_version["stdout"], Engine.get_version_info()["string"]]
	var key := identity.sha256_text()
	var destination := root.path_join(key)
	var output := destination.path_join("movie.ogv")
	var metadata := destination.path_join("metadata.json")
	if _has_link(destination) or _has_link(output) or _has_link(metadata):
		return {"error": "symlinked media cache entry refused"}
	if FileAccess.file_exists(output) and FileAccess.file_exists(metadata):
		var manifest := FileAccess.open(metadata, FileAccess.READ)
		if manifest == null or manifest.get_length() > LOG_BYTES:
			return {"error": "invalid or oversized media cache metadata"}
		var saved: Variant = JSON.parse_string(manifest.get_as_text())
		manifest.close()
		if saved is Dictionary and saved.get("key", "") == key and _validate_streams(saved, true) == "":
			var cached := _hash(output)
			if cached.has("error"):
				return cached
			if cached["sha256"] == saved.get("output_sha256", ""):
				return {"path": output, "movie_id": movie_id, "metadata": saved, "cache_hit": true}
		return {"error": "corrupt media cache entry; remove %s and retry" % destination}
	if DirAccess.dir_exists_absolute(destination):
		return {"error": "incomplete media cache entry; remove %s and retry" % destination}
	# Snapshot after hashing prevents same-path replacement during ffmpeg reads.
	var snapshot := work.path_join("source." + source.get_extension().to_lower())
	var copied := _hash(source, snapshot)
	if copied.has("error"):
		return copied
	if copied["sha256"] != fingerprint["sha256"]:
		return {"error": "installed movie changed while preparing playback; retry after content is stable"}
	_set_phase("Inspecting installed video and embedded audio")
	var info := _probe(ffprobe, snapshot)
	if info.has("error"):
		return info
	var problem := _validate_streams(info, false)
	if problem != "":
		return {"error": problem}
	_set_phase("Converting installed movie (Theora + Vorbis)")
	var temporary := work.path_join("movie.ogv")
	var args := PackedStringArray(["-nostdin", "-hide_banner", "-loglevel", "error", "-xerror", "-y", "-threads", "2", "-filter_threads", "2", "-protocol_whitelist", "file", "-i", snapshot, "-map", "0:v:0", "-map", "0:a:0", "-map_metadata", "-1", "-sn", "-dn", "-c:v", "libtheora", "-q:v", "7", "-pix_fmt", "yuv420p", "-threads", "2", "-c:a", "libvorbis", "-q:a", "5", "-ar", "44100", "-ac", "2", "-fs", str(MAX_BYTES), "-f", "ogg", temporary])
	var converted := _run(ffmpeg, args)
	if converted.has("error"):
		return converted
	_set_phase("Verifying converted animation and audio")
	var derived := _probe(ffprobe, temporary)
	if derived.has("error"):
		return derived
	problem = _validate_streams(derived, true)
	if problem != "":
		return {"error": problem}
	if absf(float(derived["format"]["duration"]) - float(info["format"]["duration"])) > 1.0:
		return {"error": "converted movie duration differs from source (truncated or unsynchronized output)"}
	var decoded := _run(ffmpeg, PackedStringArray(["-nostdin", "-hide_banner", "-loglevel", "error", "-xerror", "-threads", "2", "-protocol_whitelist", "file", "-i", temporary, "-map", "0:v:0", "-map", "0:a:0", "-f", "null", "-"]))
	if decoded.has("error"):
		return decoded
	var final_hash := _hash(temporary)
	if final_hash.has("error"):
		return final_hash
	var source_now := _hash(source)
	if source_now.has("error"):
		return source_now
	if source_now["sha256"] != fingerprint["sha256"]:
		return {"error": "installed movie replaced during conversion; retry after content is stable"}
	derived["key"] = key
	derived["source_sha256"] = fingerprint["sha256"]
	derived["output_sha256"] = final_hash["sha256"]
	derived["recipe"] = RECIPE
	var file := FileAccess.open(work.path_join("metadata.json"), FileAccess.WRITE)
	if file == null:
		return {"error": "cannot write media cache metadata"}
	file.store_string(JSON.stringify(derived))
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		return {"error": "cannot finish media cache metadata: %s" % error_string(write_error)}
	if _stopped():
		return {"error": _stop_error()}
	if DirAccess.remove_absolute(snapshot) != OK:
		return {"error": "cannot remove temporary movie snapshot before cache publication"}
	# Directory rename publishes the validated stream and identity together.
	# Another process winning the same key is harmless, never overwrite it.
	if DirAccess.dir_exists_absolute(destination):
		return {"error": "media cache entry was published concurrently; retry playback"}
	var published := DirAccess.rename_absolute(work, destination)
	if published != OK:
		return {"error": "cannot publish media cache: %s" % error_string(published)}
	return {"path": output, "movie_id": movie_id, "metadata": derived, "cache_hit": false}

func _hash(path: String, copy_path: String = "") -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() <= 0 or file.get_length() > MAX_BYTES:
		return {"error": "missing, empty or oversized movie/cache file: %s" % path}
	var copy: FileAccess
	if copy_path != "":
		copy = FileAccess.open(copy_path, FileAccess.WRITE)
		if copy == null:
			return {"error": "cannot create source movie snapshot"}
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	var remaining := file.get_length()
	while remaining > 0:
		if _stopped():
			return {"error": _stop_error()}
		var count := mini(remaining, 1024 * 1024)
		var bytes := file.get_buffer(count)
		if bytes.size() != count:
			return {"error": "movie changed or failed while reading: %s" % path}
		hash.update(bytes)
		if copy != null:
			copy.store_buffer(bytes)
			if copy.get_error() != OK:
				return {"error": "cannot write source movie snapshot"}
		remaining -= count
	if file.get_length() != file.get_position():
		return {"error": "movie length changed while reading: %s" % path}
	if copy != null:
		copy.flush()
		if copy.get_error() != OK:
			return {"error": "cannot flush source movie snapshot"}
		copy.close()
	file.close()
	return {"sha256": hash.finish().hex_encode()}

func _probe(executable: String, path: String) -> Dictionary:
	var result := _run(executable, PackedStringArray(["-v", "error", "-protocol_whitelist", "file", "-show_entries", "format=duration,format_name:stream=codec_name,codec_type,width,height,avg_frame_rate,sample_rate,channels", "-of", "json", path]))
	if result.has("error"):
		return result
	var parsed: Variant = JSON.parse_string(result["stdout"])
	if not parsed is Dictionary:
		return {"error": "ffprobe returned invalid movie metadata"}
	return parsed

static func _validate_streams(info: Dictionary, derived: bool) -> String:
	if not info.get("format") is Dictionary or not info.get("streams") is Array:
		return "invalid movie stream metadata"
	var duration_text: Variant = info["format"].get("duration")
	if not duration_text is String or not duration_text.is_valid_float():
		return "invalid movie duration metadata"
	var duration := float(info.get("format", {}).get("duration", 0))
	if not is_finite(duration) or duration <= 0 or duration > MAX_SECONDS:
		return "missing or unsupported movie duration (limit 600 seconds)"
	var video: Dictionary = {}
	var audio: Dictionary = {}
	for entry: Variant in info["streams"]:
		if not entry is Dictionary:
			return "invalid movie stream entry"
		var stream: Dictionary = entry
		if stream.get("codec_type", "") == "video" and video.is_empty():
			video = stream
		if stream.get("codec_type", "") == "audio" and audio.is_empty():
			audio = stream
	if video.is_empty() or audio.is_empty():
		return "movie must contain actual video AND embedded audio"
	for field: String in ["width", "height"]:
		if typeof(video.get(field)) not in [TYPE_INT, TYPE_FLOAT]:
			return "invalid movie dimension metadata"
	if not video.get("avg_frame_rate") is String or not audio.get("sample_rate") is String or typeof(audio.get("channels")) not in [TYPE_INT, TYPE_FLOAT]:
		return "invalid movie frame-rate/audio metadata"
	var video_codecs := ["theora"] if derived else ["mpeg1video", "mpeg2video", "binkvideo"]
	var audio_codecs := ["vorbis"] if derived else ["mp2", "binkaudio_dct", "binkaudio_rdft"]
	if video.get("codec_name", "") not in video_codecs or audio.get("codec_name", "") not in audio_codecs:
		return "unsupported installed movie codecs: %s / %s" % [video.get("codec_name", "?"), audio.get("codec_name", "?")]
	var width := int(video.get("width", 0))
	var height := int(video.get("height", 0))
	if width <= 0 or height <= 0 or width > 1920 or height > 1080:
		return "unsupported movie dimensions (maximum 1920x1080)"
	var rate := str(video.get("avg_frame_rate", "0/0")).split("/")
	if rate.size() != 2 or float(rate[1]) <= 0 or float(rate[0]) / float(rate[1]) <= 0 or float(rate[0]) / float(rate[1]) > 60:
		return "unsupported movie frame rate (maximum 60 fps)"
	if int(audio.get("channels", 0)) not in [1, 2] or int(audio.get("sample_rate", 0)) not in [22050, 32000, 44100, 48000]:
		return "unsupported embedded movie audio format"
	return ""

## No shell, no inherited stdin, only local-file protocols. Both pipes are
## drained so decoder errors cannot deadlock the child. Cancellation kills and
## reaps the owned process before the worker returns; output memory is bounded.
func _run(executable: String, args: PackedStringArray) -> Dictionary:
	if _stopped():
		return {"error": _stop_error()}
	var child := OS.execute_with_pipe(executable, args, false)
	if child.is_empty():
		return {"error": "cannot launch %s; install user-local ffmpeg and ffprobe with Theora/Vorbis support" % executable}
	var pid: int = child["pid"]
	var stdout_bytes := PackedByteArray()
	var stderr_bytes := PackedByteArray()
	var stopped := false
	while true:
		var out: PackedByteArray = child["stdio"].get_buffer(4096)
		var err: PackedByteArray = child["stderr"].get_buffer(4096)
		if stdout_bytes.size() < LOG_BYTES:
			stdout_bytes.append_array(out.slice(0, LOG_BYTES - stdout_bytes.size()))
		if stderr_bytes.size() < LOG_BYTES:
			stderr_bytes.append_array(err.slice(0, LOG_BYTES - stderr_bytes.size()))
		if not OS.is_process_running(pid):
			# Drain the remaining buffered tail after process exit.
			if out.is_empty() and err.is_empty():
				break
		elif _stopped() and not stopped:
			OS.kill(pid)
			stopped = true
		OS.delay_msec(10)
	var exit_code := OS.get_process_exit_code(pid)
	child["stdio"].close()
	child["stderr"].close()
	if stopped or _stopped():
		return {"error": _stop_error()}
	if exit_code != 0:
		return {"error": "%s failed (exit %d): %s" % [executable, exit_code, stderr_bytes.get_string_from_utf8().strip_edges()]}
	return {"stdout": stdout_bytes.get_string_from_utf8(), "stderr": stderr_bytes.get_string_from_utf8()}
