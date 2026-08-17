## drive.gd -- script the port with retail's own autopilot grammar, so one
## step list drives both engines and the two can be compared at the same
## moment rather than at two moments nobody wrote down.
##
##   godot --resolution 1024x768 --path . -- \
##       --drive="1000 click 512 300; 2000 key iso_right 1500" \
##       --shots=0,2000,5000 --drive-out=/tmp/drive-x/port
##
## The grammar is `ms verb args`, semicolon-separated, taken verbatim from
## analysis/tools/shim/autopilot.c so a script written for retail runs here
## unchanged. Two deliberate divergences, both additive:
##
##   key NAME [MS]  -- retail's `key` is press+release. Here NAME is an Input
##                     Map ACTION (iso_left/iso_right/iso_up/iso_down) or a
##                     Godot key name, and the optional MS holds it down.
##                     Panning is read by IsoCamera through Input.get_vector,
##                     which samples HELD state -- a press+release inside one
##                     frame moves the camera by nothing at all.
##   text           -- not implemented. The port takes no typed input; a
##                     script using it fails loudly rather than silently
##                     doing nothing.
##
## Actions are injected as InputEventAction rather than as key events on
## purpose: project.godot binds panning to *physical* keycodes, so a synthetic
## InputEventKey would have to reproduce that mapping and would go stale the
## day somebody rebinds a key. InputEventAction updates the same action state
## Input.get_vector reads, and cannot disagree with the Input Map.
##
## ponytail: no alignment, no retry, no per-frame video. Shots are "the first
## frame at or after ms" and the line printed for each says the ms actually
## reached, so a slow settle is visible instead of averaged away.
class_name Drive
extends RefCounted

## Retail's glReadPixels grab is hard-coded to 1024x768 (autopilot.c shot_w /
## shot_h). Comparing a port frame of any other size against it compares
## nothing -- png_delta.py refuses on a size mismatch, and a human eyeballing
## two differently-framed pictures is worse than refusing. So --shots= is
## gated on this exact size.
const RETAIL_W := 1024
const RETAIL_H := 768

## How long to keep rendering after the last step and the last shot. Without
## it the process quits on the same frame it captured, and a shot scheduled at
## the very end races the quit.
const TAIL_MS := 300


static func wanted(argv: Array) -> bool:
	for a: String in argv:
		if a.begins_with("--drive=") or a.begins_with("--shots="):
			return true
	return false


static func _flag(argv: Array, prefix: String, fallback: String) -> String:
	for a: String in argv:
		if a.begins_with(prefix):
			return a.trim_prefix(prefix)
	return fallback


## "1000 click 512 300; 2500 key iso_right 1500" -> [{ms, verb, args}, ...],
## sorted by ms. A malformed step is fatal: a driver that silently drops the
## one step the run was about produces a capture of nothing happening, which
## is indistinguishable from the bug it was launched to find.
static func parse(script: String) -> Array[Dictionary]:
	var steps: Array[Dictionary] = []
	for raw in script.split(";", false):
		var f := raw.strip_edges().split(" ", false)
		if f.is_empty():
			continue
		if f.size() < 2 or not f[0].is_valid_int():
			printerr("drive\tmalformed step (want `ms verb args`): %s" % raw.strip_edges())
			return []
		steps.append({"ms": int(f[0]), "verb": f[1], "args": f.slice(2)})
	steps.sort_custom(func(a, b): return a["ms"] < b["ms"])
	return steps


static func _mouse(pos: Vector2, button: int, pressed: bool, mask: int) -> void:
	var e := InputEventMouseButton.new()
	e.position = pos
	e.global_position = pos
	e.button_index = button
	e.pressed = pressed
	e.button_mask = mask
	Input.parse_input_event(e)


static func _motion(from: Vector2, to: Vector2, mask: int) -> void:
	var e := InputEventMouseMotion.new()
	e.position = to
	e.global_position = to
	e.relative = to - from
	e.button_mask = mask
	Input.parse_input_event(e)


## Input.action_press/release, NOT parse_input_event(InputEventAction). A
## synthetic InputEventAction propagates through the SceneTree to _input
## handlers but never reaches the singleton's own action state, so
## Input.get_vector -- which is how IsoCamera pans -- keeps reading zero.
## Measured: a 1200ms `key iso_right` through InputEventAction moved the camera
## by 0.25% of pixels, i.e. by nothing but the hero's own animation.
static func _action(name: String, pressed: bool) -> void:
	if pressed:
		Input.action_press(StringName(name), 1.0)
	else:
		Input.action_release(StringName(name))


static func _key(name: String, pressed: bool) -> void:
	var code := OS.find_keycode_from_string(name)
	if code == KEY_NONE:
		printerr("drive\tunknown key/action: %s" % name)
		return
	var e := InputEventKey.new()
	e.keycode = code
	e.physical_keycode = code
	e.pressed = pressed
	Input.parse_input_event(e)


## Runs the timeline, writes each shot, quits. Assumes the caller has already
## built the world -- this is invoked from main.gd's _ready in place of
## _maybe_screenshot(), and shares its settle so a t=0 capture is a finished
## view and not whatever one frame of streaming happened to produce.
static func run(host: Node, argv: Array) -> void:
	var out := _flag(argv, "--drive-out=", "/tmp/drive/port")
	var script := _flag(argv, "--drive=", "")
	var shots: Array[int] = []
	for s in _flag(argv, "--shots=", "").split(",", false):
		if not s.strip_edges().is_valid_int():
			printerr("drive\t--shots= wants a comma-separated ms list, got: %s" % s)
			host.get_tree().quit(1)
			return
		shots.append(int(s.strip_edges()))
	shots.sort()

	var steps := parse(script)
	if script != "" and steps.is_empty():
		host.get_tree().quit(1)
		return

	if not shots.is_empty():
		var size := host.get_viewport().get_visible_rect().size
		if int(size.x) != RETAIL_W or int(size.y) != RETAIL_H:
			printerr("drive\tviewport is %dx%d; retail captures at %dx%d and "
				% [int(size.x), int(size.y), RETAIL_W, RETAIL_H]
				+ "a cross-engine comparison at two sizes compares nothing.\n"
				+ "drive\trelaunch with: godot --resolution %dx%d --path . -- ..."
				% [RETAIL_W, RETAIL_H])
			host.get_tree().quit(1)
			return
		if DirAccess.make_dir_recursive_absolute(out) != OK:
			printerr("drive\tcannot create output directory %s" % out)
			host.get_tree().quit(1)
			return

	# The same settle every --shot= capture uses. A second, differently-timed
	# wait here is exactly the mistake _await_settled() was factored out to
	# prevent, so this calls it rather than reimplementing it.
	if not await host._await_settled():
		return

	var t0 := Time.get_ticks_msec()
	var last_ms: int = 0
	for s in steps:
		last_ms = maxi(last_ms, int(s["ms"]))
	for m in shots:
		last_ms = maxi(last_ms, m)

	var si := 0
	var shi := 0
	var mask := 0
	var pos := Vector2(RETAIL_W, RETAIL_H) * 0.5
	var releases: Array[Dictionary] = []   ## scheduled key-ups: {ms, name, is_action}

	print("drive\tsteps=%d\tshots=%d\tout=%s" % [steps.size(), shots.size(), out])
	while true:
		await RenderingServer.frame_post_draw
		if not is_instance_valid(host):
			return
		var t := Time.get_ticks_msec() - t0

		while si < steps.size() and int(steps[si]["ms"]) <= t:
			var step: Dictionary = steps[si]
			si += 1
			var a: PackedStringArray = step["args"]
			match String(step["verb"]):
				"move":
					var to := Vector2(float(a[0]), float(a[1]))
					_motion(pos, to, mask)
					pos = to
				"click":
					var to2 := Vector2(float(a[0]), float(a[1]))
					_motion(pos, to2, mask)
					pos = to2
					_mouse(pos, MOUSE_BUTTON_LEFT, true, MOUSE_BUTTON_MASK_LEFT)
					_mouse(pos, MOUSE_BUTTON_LEFT, false, 0)
				"hold":
					var to3 := Vector2(float(a[0]), float(a[1]))
					_motion(pos, to3, mask)
					pos = to3
					mask = MOUSE_BUTTON_MASK_LEFT
					_mouse(pos, MOUSE_BUTTON_LEFT, true, mask)
				"release":
					mask = 0
					_mouse(pos, MOUSE_BUTTON_LEFT, false, 0)
				"wheel":
					# Retail's SDL 1.2 numbering: 4 = up, 5 = down, a[1] repeats.
					var btn := MOUSE_BUTTON_WHEEL_UP if int(a[0]) == 4 else MOUSE_BUTTON_WHEEL_DOWN
					for _i in maxi(1, int(a[1]) if a.size() > 1 else 1):
						_mouse(pos, btn, true, 0)
						_mouse(pos, btn, false, 0)
				"key":
					var key_name := a[0]
					var is_action := InputMap.has_action(StringName(key_name))
					if is_action:
						_action(key_name, true)
					else:
						_key(key_name, true)
					var hold_ms := int(a[1]) if a.size() > 1 else 0
					releases.append({"ms": t + hold_ms, "name": key_name, "action": is_action})
				"text":
					printerr("drive\t`text` is not implemented -- the port takes no typed input")
					host.get_tree().quit(1)
					return
				_:
					printerr("drive\tunknown verb: %s" % step["verb"])
					host.get_tree().quit(1)
					return
			print("drive\tt=%d\t%s %s" % [t, step["verb"], " ".join(a)])

		var still: Array[Dictionary] = []
		for r in releases:
			if int(r["ms"]) <= t:
				if bool(r["action"]):
					_action(String(r["name"]), false)
				else:
					_key(String(r["name"]), false)
			else:
				still.append(r)
		releases = still

		while shi < shots.size() and shots[shi] <= t:
			var want: int = shots[shi]
			shi += 1
			var path := "%s/port-%d.png" % [out, want]
			var err := host.get_viewport().get_texture().get_image().save_png(path)
			# `at` is the ms actually reached, which is >= want by however long
			# the frame took. Printed so a slow frame is visible rather than
			# quietly folded into the label on the file.
			print("shot\t%s\twant=%d\tat=%d\t%s" % [path, want, t, error_string(err)])

		if si >= steps.size() and shi >= shots.size() and releases.is_empty() \
				and t > last_ms + TAIL_MS:
			break

	host.get_tree().quit()
