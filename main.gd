extends Node3D
## OpenSacred composition root: resolves the retail install, constructs the
## shared readers (pak/world/static/mixed/items), parses every CLI flag,
## prints the startup banner, and owns the actor world layer (registry,
## record store, sim) and the camera.
##
## Sector streaming and mesh assembly live in view/sector_view.gd
## (SectorView) -- this file constructs it once in _ready(), drives it from
## _process() alongside the sim accumulator, and never duplicates its logic.
## _process() is the single per-frame entry point: it calls SectorView.stream()
## then Sim.advance() (via _advance_sim), never two independently-ordered node
## callbacks (R10.2).
##
## Two modes:
##   (default)          stream sectors around the camera
##   --region=cx,cy,r   load exactly that fixed block, print the counts, stop
##                      streaming. This is the regression check -- 50,50,1 must
##                      stay "28672 quads, 63 textures".

const SECT: int = Sacred.SECT

@export var start_cell := Vector2(3232.0, 3232.0)  ## middle of sector 50,50

var _cam: IsoCamera
var _view: SectorView

## Actor world layer (world/actor_registry.gd, world/sim.gd). Constructed
## once in _ready(), never added to the scene tree -- see
## world/actor_registry.gd's header for why (the OpenMW-regret this phase
## exists to avoid).
var _registry: ActorRegistry
var _records: RecordStore
var _sim: Sim
var _tick_hz: int = Sim.TICK_HZ           ## --tickhz=N override, clamped [1,240]
var _probe_ticks := 0                     ## --actor-probe=N; <= 0 disables the probe
var _probe_route := "a"                   ## --probe-route=a|b
var _probe_active := false                ## true while _actor_probe() drives ticks by exact count
const PROBE_FOCUS := Vector2(3232.0, 3232.0)  ## middle of sector 50,50
const PROBE_FRAME_BUDGET := 600           ## matches _maybe_screenshot's settle budget

# Phase 4: record / replay. Nothing below is read unless --record= or
# --replay= is present -- every other mode's behaviour is byte-for-byte
# unchanged from before this phase.
var _record_path := ""                    ## --record=PATH: write intent+tick to this recording file
var _replay_path := ""                    ## --replay=PATH: replay a recording from this file instead of live input
var _dump_path := ""                      ## --dump=PATH: per-tick state-dump destination, record or replay mode
var _autoplay_ticks := 0                  ## --autoplay=N: ticks to record before quitting; <= 0 disables
var _has_spawn_override := false          ## true once --spawn=cx,cy has been parsed
var _spawn_override := Vector2.ZERO       ## --spawn=cx,cy: skip derivation, use this cell exactly
var _falsify_tick := -1                   ## --falsify=TICK: perturb this tick during replay (Task 2); < 0 disables
var _falsify_mode := ""                   ## --falsify-mode=nudge|skip, paired with --falsify=
var _player_id: int = ActorRegistry.INVALID_ID
var _recorder: Replay.Recorder
var _dumper: Replay.Dumper
var _replay_active := false               ## true while replay drives ticks by count -- suppresses _process()'s normal advance call, exactly like _probe_active
const RECORD_FRAME_BUDGET := 20000        ## generous upper bound; --autoplay=600 finishes in a small fraction of this

# Plan 04-02: sliding path window. Nothing below is read unless a record or
# replay run is in progress -- every other mode is untouched.
var _path_window: PathWindow = null
var _goal_cell := PathWindow.NO_GOAL      ## BFS-derived once per record/replay run; NO_GOAL if none could be derived
const GOAL_REQUEST_TICK := 250            ## the one scripted tick that requests a path (well after spawn, well before autoplay ends)

## Task 3's origin perturbation: a plain number, sourced here at the
## composition root, never inside godot-port/world/ -- large enough
## (one whole window edge) to guarantee the shifted window never coincides
## with the true one, regardless of the actor's exact position.
const ORIGIN_PERTURB_OFFSET := Vector2i(PathWindow.WINDOW_EDGE, PathWindow.WINDOW_EDGE)

# Plan 04-03: the player view (the real posed mesh, drawn and depth-sorted in
# the streamed world) and camera follow. Nothing below is read unless the
# default streaming branch runs -- fixed-region, single-model, window-probe
# and record/replay modes are all unaffected.
var _player_view: PlayerView = null
var _show_player := true   ## --noplayer: suppress building the player view entirely (Task 3's Gate 1 needs the camera following the player with the player itself not drawn), in the style of --noobjects.
## --hideplayer: build the player view and keep the camera following it
## exactly like the ordinary case, but never make its mesh visible. A
## genuinely different mechanism from --noplayer (Task 2's own fix means
## --noplayer now also stops the camera following, per the commit on
## iso_camera.gd/main.gd) -- Gate 1's A/B/C captures need the camera actively
## chasing the player while nothing player-shaped reaches the frame, which
## only PlayerView.set_shown(false) on an otherwise-normal player gives.
var _hide_player_mesh := false


func _ready() -> void:
	var install := Sacred.find_install()
	if install == "":
		push_error("OpenSacred: no retail install found. Pass --install=/path/to/install, "
			+ "or write install_path into user://opensacred.cfg.")
		return

	var tiles_pak := Sacred.Pak.new(install.path_join("pak/tiles.pak"))
	var tex_pak := Sacred.Pak.new(install.path_join("pak/texture.pak"))
	var world := Sacred.World.new(install.path_join("world"))
	if not (tiles_pak.is_open() and tex_pak.is_open() and world.is_open()):
		return
	# Sacred's own pointer, straight from texture.pak. Cosmetic and non-fatal --
	# a failure warns and leaves the platform cursor. Skipped under --headless,
	# where there is no cursor to set and the scan would be pure waste.
	if DisplayServer.get_name() != "headless":
		RetailCursor.apply(tex_pak)

	var tiles := Sacred.Tiles.new(tiles_pak)
	var statics: Sacred.Statics
	var static_pak := Sacred.Pak.new(install.path_join("world/static.pak"))
	if static_pak.is_open():
		statics = Sacred.Statics.new(static_pak)
	var mixed: Sacred.Mixed
	var mixed_pak := Sacred.Pak.new(install.path_join("pak/mixed.pak"))
	if mixed_pak.is_open():
		mixed = Sacred.Mixed.new(mixed_pak)
	var items: Sacred.Items
	var items_pak := Sacred.Pak.new(install.path_join("pak/items.pak"))
	if items_pak.is_open():
		items = Sacred.Items.new(items_pak)
	_records = RecordStore.new(items, mixed)
	var argv := OS.get_cmdline_user_args() + OS.get_cmdline_args()
	var stats := "--stats" in argv
	var markers := "--markers" in argv
	var objects := not ("--noobjects" in argv)
	_show_player = not ("--noplayer" in argv)
	_hide_player_mesh = "--hideplayer" in argv
	var interiors := "--interiors" in argv
	var show_regions := "--regions" in argv
	var exterior := "--exterior" in argv
	var hide_levels := 0
	for a in argv:
		if a.begins_with("--hidelevel="):
			for d in a.trim_prefix("--hidelevel=").split(","):
				hide_levels |= 1 << int(d)
	var only_flag := -1
	for a in argv:
		if a.begins_with("--onlyflag="):
			only_flag = int(a.trim_prefix("--onlyflag="))
	var band_count := 1
	for a in argv:
		if a.begins_with("--bands="):
			band_count = clampi(int(a.trim_prefix("--bands=")), 1, SectorView.BAND_MAX)
	var sortcube := Vector2i(-1, -1)
	for a in argv:
		if a.begins_with("--sortcube="):
			var p := a.trim_prefix("--sortcube=").split(",")
			if p.size() == 2:
				sortcube = Vector2i(int(p[0]), int(p[1]))
	# Single-model mode. NAME is only ever looked up in the pak's own name
	# table by Models.index_of -- it is never joined into a path, and never
	# opened as a file.
	var grn_name := ""
	for a in argv:
		if a.begins_with("--grn="):
			grn_name = a.trim_prefix("--grn=")
	for a in argv:
		if a.begins_with("--tickhz="):
			_tick_hz = clampi(int(a.trim_prefix("--tickhz=")), 1, 240)
		elif a.begins_with("--actor-probe="):
			_probe_ticks = int(a.trim_prefix("--actor-probe="))
		elif a.begins_with("--probe-route="):
			_probe_route = a.trim_prefix("--probe-route=")
		elif a.begins_with("--record="):
			_record_path = a.trim_prefix("--record=")
		elif a.begins_with("--replay="):
			_replay_path = a.trim_prefix("--replay=")
		elif a.begins_with("--dump="):
			_dump_path = a.trim_prefix("--dump=")
		elif a.begins_with("--autoplay="):
			_autoplay_ticks = int(a.trim_prefix("--autoplay="))
		elif a.begins_with("--spawn="):
			var p := a.trim_prefix("--spawn=").split(",")
			if p.size() == 2:
				_spawn_override = Vector2(float(p[0]), float(p[1]))
				_has_spawn_override = true
		elif a.begins_with("--falsify-mode="):
			_falsify_mode = a.trim_prefix("--falsify-mode=")
		elif a.begins_with("--falsify="):
			_falsify_tick = int(a.trim_prefix("--falsify="))

	_registry = ActorRegistry.new()
	_sim = Sim.new(_tick_hz)

	# Streaming mode otherwise prints nothing at all, so a successful run and a
	# silently-failed one look identical from the terminal.
	print("OpenSacred\t%s" % install)
	print("  world\t%d of %d sectors present, %dx%d grid" % [
		world.count(), world.size.x * world.size.y, world.size.x, world.size.y])
	print("  tiles\t%d records -> %d textures" % [tiles.count(), tex_pak.count()])
	print("  statics\t%s\titems\t%s\trecords\t%s" % [
		"%d" % statics.count() if statics else "unavailable",
		"%d interior, %d levelled" % [items.count(), items.level_count()] if items else "unavailable",
		"%d" % _records.count() if _records.is_open() else "unavailable"])
	print("  sim\ttick %d Hz\tr_sim %.0f\tr_render %.0f\tr_load %.0f\tordered %s" % [
		_tick_hz, Sim.R_SIM, Sim.R_RENDER, Sim.R_LOAD,
		Sim.R_SIM < Sim.R_RENDER and Sim.R_RENDER < Sim.R_LOAD])

	if grn_name != "":
		await _show_model(install, grn_name)
		return

	if "--window-probe" in argv:
		_window_probe(world)
		return

	if "--follow-probe" in argv:
		_follow_probe()
		return

	if _record_path != "" or _replay_path != "":
		await _run_record_or_replay(world, install, tex_pak, tiles, statics, mixed, items)
		return

	_cam = IsoCamera.new()
	_cam.cell_limit = Vector2(world.size) * SECT
	add_child(_cam)

	_view = SectorView.new()
	_view.name = "SectorView"
	_view.setup(_cam, tex_pak, tiles, world, statics, mixed, items, {
		"stats": stats, "markers": markers, "objects": objects, "interiors": interiors,
		"regions": show_regions, "exterior": exterior, "hide_levels": hide_levels,
		"only_flag": only_flag, "band_count": band_count, "sortcube": sortcube,
	})
	add_child(_view)

	var region := _region_arg()

	# Plan 04-03: the player, spawned on real walkable ground exactly like
	# _run_record_or_replay's own Walkable/_resolve_spawn/_registry.spawn/
	# _sim.walk= sequence -- never a second implementation of spawn
	# derivation. Non-fatal on failure, matching RetailCursor.apply's degrade:
	# streaming mode drew nothing extra before this plan and keeps doing so
	# rather than aborting a run that has no walkable ground to stand on.
	#
	# Gated to the true default-streaming case only (no fixed region, no
	# --actor-probe=) -- both of those modes are pre-existing, self-contained
	# regression harnesses (28672-quad/63-texture region count; --actor-probe='s
	# id1..id19 fixed set and its PROBE_FOCUS-relative order/bands lines) that
	# assume nothing else occupies the registry or the frame. Spawning the
	# player there would not just shift ids, it would put an extra actor at
	# PROBE_FOCUS's own sector and change _actor_probe's band COUNTS, which
	# are geometric (in_radius().size()), not id-keyed. "The fixed region
	# mode, the single-model mode, the probe -- the camera keeps behaving
	# exactly as it does today" (04-03-PLAN.md Task 2) states this as the
	# intended shape for those modes.
	if region == Vector3i.ZERO and _probe_ticks <= 0:
		var walk := Walkable.new(world)
		var spawn := _resolve_spawn(walk)
		if spawn.is_empty():
			push_warning("player: no walkable spawn cell found -- drawing nothing")
		else:
			var player_cell: Vector2 = spawn["cell"]
			_player_id = _registry.spawn(_first_real_record_id(), player_cell, 100, 100)
			_sim.walk = walk
			_sim.focus_actor_id = _player_id
			print("spawn\tcell=%.6f,%.6f\tclass=%d\tcomponent=%d\tsectors=%d" % [
				player_cell.x, player_cell.y, spawn["class"], spawn["component"], spawn["sectors"]])
			if _show_player:
				var models_pak := Sacred.Pak.new(install.path_join("pak/models.pak"))
				if models_pak.is_open():
					_player_view = PlayerView.new(Sacred.Models.new(models_pak))
					if _player_view.node != null:
						add_child(_player_view.node)
						if _hide_player_mesh:
							_player_view.set_shown(false)
						print("player\tmodel=%s\tindex=%d\tverts=%d\ttris=%d" % [
							PlayerView.MODEL_NAME, _player_view.model_index,
							_player_view.vertex_count, _player_view.triangle_count])

	if region != Vector3i.ZERO:
		_view.load_region(region.x, region.y, region.z)
	else:
		_cam.set_zoom_index(1)   # middle of Sacred's three steps
		_cam.look_at_cell(start_cell)
	for arg in argv:
		if arg.begins_with("--zoom="):
			_cam.set_zoom_index(int(arg.trim_prefix("--zoom=")))
		elif arg.begins_with("--at="):
			var p := arg.trim_prefix("--at=").split(",")
			if p.size() == 2:
				_cam.look_at_cell(Vector2(float(p[0]), float(p[1])))
		elif arg.begins_with("--sector="):
			var p := arg.trim_prefix("--sector=").split(",")
			if p.size() == 2:
				_cam.look_at_cell((Vector2(float(p[0]), float(p[1])) + Vector2(0.5, 0.5)) * SECT)
	var at := _cam.world_to_cell(Vector2(_cam.position.x, _cam.position.y))
	print("  view\tcell %d,%d (sector %d,%d)\tzoom %d\t%s%s" % [
		at.x, at.y, at.x / SECT, at.y / SECT, _cam.size,
		"fixed region" if region != Vector3i.ZERO else "streaming",
		"\tmarkers on" if markers else ""])
	if _probe_ticks > 0:
		await _actor_probe(_probe_ticks, _probe_route)
	else:
		await _maybe_screenshot()


## Releases the retail cursor texture before RenderingServer teardown. Without
## this, Input holds the ImageTexture past shutdown and its RID leaks -- see
## RetailCursor.clear() for the measurement.
func _exit_tree() -> void:
	RetailCursor.clear()


func _process(delta: float) -> void:
	if _view != null:
		_view.stream(delta)
	if not _probe_active and not _replay_active:
		_advance_sim(delta, _focus_cell())
	# Plan 04-03 Task 2: --noplayer means no player at all, not just an
	# invisible one -- the camera must keep behaving exactly as it does today
	# (Task 2's own reference-capture regression: --sector=50,50 with the
	# player suppressed, unchanged md5) when --noplayer is passed, which it
	# only would if follow is gated on _show_player too, not on _player_id
	# alone. Fixed-region mode, the probe and --grn= never reach here with a
	# valid _player_id at all (Task 1's fix gates player-spawn to the true
	# default-streaming case only), so those modes are unaffected either way.
	if _show_player and _player_id != ActorRegistry.INVALID_ID:
		var p := _registry.get_actor(_player_id)
		if p != null:
			if _player_view != null:
				_player_view.update(p.cell)
			if _cam != null:
				_cam.follow_cell(p.cell)


## The ONLY Sim per-frame advance call site outside godot-port/world/ -- a
## hard constraint, not a style preference: it is what makes "one tick loop"
## a greppable fact rather than a claim. Every caller of the sim goes
## through this one function -- including the record run below, which never
## drives ticks any other way, so recording stays on the real input path
## rather than a parallel one.
##
## When recording, the player's intent for the WHOLE frame is set once,
## before the one real call below, from _scripted_intent(pre_tick) -- a
## pure function of the tick count at the start of this frame -- and every
## tick that call runs is written to the recorder afterwards carrying that
## same intent (D-01, D-06).
func _advance_sim(dt: float, focus: Vector2) -> int:
	if _sim == null:
		return 0
	var pre_tick := _sim.tick
	var pre_dropped := _sim.dropped
	var intent := Vector2.ZERO
	var recording := _recorder != null and _recorder.is_open()
	if recording and _player_id != ActorRegistry.INVALID_ID:
		intent = _scripted_intent(pre_tick)
		var p := _registry.get_actor(_player_id)
		if p != null:
			p.heading = intent
	# Plan 04-02: the one scripted goal request, threaded into the LIVE sim
	# exactly like a real caller would. The request names the TICK it is for and
	# Sim fires it when its own counter reaches that number.
	#
	# It used to be gated on `pre_tick + 1 == GOAL_REQUEST_TICK` -- "is the tick
	# about to run the goal tick?" -- with a comment claiming a catch-up burst
	# would merely delay it by one tick. That comment was wrong, and the gate
	# was a latent divergence (04-REVIEW CR-01): advance() runs up to
	# MAX_CATCHUP_TICKS ticks per call, so if GOAL_REQUEST_TICK landed second or
	# later in a burst the test failed, the goal was applied ZERO times (`tick`
	# only moves forward, so the edge could never fire again), and yet the
	# recorder's write loop below -- which range-tests every tick actually run --
	# still wrote the goal line. Replay then applied a goal the live run never
	# did. Setting the tick number instead makes the two agree by construction:
	# both now key off the same counter rather than off frame timing.
	if recording and _goal_cell != PathWindow.NO_GOAL and _sim.pending_goal_tick < 0 \
			and pre_tick < GOAL_REQUEST_TICK:
		_sim.pending_goal_actor_id = _player_id
		_sim.pending_goal = _goal_cell
		_sim.pending_goal_tick = GOAL_REQUEST_TICK
	var ran := _sim.advance(dt, _registry, focus)
	if recording:
		for t in range(pre_tick + 1, pre_tick + ran + 1):
			var goal := _goal_cell if t == GOAL_REQUEST_TICK else PathWindow.NO_GOAL
			_recorder.write_input(t, intent, goal)
		if _sim.dropped > pre_dropped:
			_recorder.write_gap(_sim.tick, _sim.dropped - pre_dropped)
	return ran


func _focus_cell() -> Vector2:
	if _player_id != ActorRegistry.INVALID_ID:
		var p := _registry.get_actor(_player_id)
		if p != null:
			return p.cell
	if _cam == null:
		return start_cell
	return _cam.world_to_cell(Vector2(_cam.position.x, _cam.position.y))


## A fixed, deterministic schedule of movement directions, a pure function
## of the tick count alone -- positive x, then positive y, then a diagonal,
## then back -- chosen so all four axis-separated collision outcomes (x
## blocked / y free, y blocked / x free, both free, both blocked) are
## exercised against real walls over one recording run. Routed through the
## same `heading` field a keyboard would eventually set (world/actor_state.gd),
## so --record= records the real input path rather than a parallel one.
func _scripted_intent(tick: int) -> Vector2:
	var phase := (tick / 150) % 4
	if phase == 0:
		return Vector2(1.0, 0.0)
	elif phase == 1:
		return Vector2(0.0, 1.0)
	elif phase == 2:
		return Vector2(1.0, 1.0).normalized()
	return Vector2(-1.0, -1.0).normalized()


func _region_arg() -> Vector3i:
	for arg in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if not arg.begins_with("--region="):
			continue
		var p := arg.trim_prefix("--region=").split(",")
		if p.size() == 3:
			return Vector3i(int(p[0]), int(p[1]), int(p[2]))
	return Vector3i.ZERO


## The chosen spawn cell as a fact line, its class, the component size and
## how many sectors were scanned -- MEASURED, never hardcoded from a guess.
## `--spawn=cx,cy` (a debugging override, not part of the falsifiable path)
## skips derivation entirely; component/sectors read 0 in that case, since
## no scan ran.
func _resolve_spawn(walk: Walkable) -> Dictionary:
	if _has_spawn_override:
		var cls := walk.class_at(floori(_spawn_override.x), floori(_spawn_override.y))
		return {"cell": _spawn_override, "class": cls, "component": 0, "sectors": 0, "bbox": Rect2i()}
	var centre := Vector2i(int(start_cell.x) / SECT, int(start_cell.y) / SECT)
	var best := walk.derive_spawn(centre)
	if best.is_empty():
		return {}
	var seed: Vector2i = best["seed"]
	var cell := Vector2(seed) + Vector2(0.5, 0.5)   # the cell's centre, not its lower corner
	var cls := walk.class_at(seed.x, seed.y)
	return {"cell": cell, "class": cls, "component": int(best["count"]), "sectors": int(best["sectors_scanned"]),
		"bbox": best.get("bbox", Rect2i())}


## BFS over open cells reachable from `spawn_cell`, bounded to `bbox` when
## non-empty, returning the farthest-by-cell-distance reachable cell found --
## i.e. a cell get_id_path() is GUARANTEED able to reach, since it is
## discovered by literally walking the same connectivity a path search
## would. Deliberately NOT a bbox-corner scan: a bbox corner can be open
## while belonging to a different, disconnected pocket of the same
## rectangular bbox (Walkable's own storey-ambiguity ponytail note,
## world/walkable.gd:70-74, is exactly this kind of surprise), which
## get_id_path() could never actually reach. Capped at MAX_VISITED so an
## unbounded bbox (the --spawn= override path, whose bbox is always empty)
## cannot turn one BFS into an unbounded scan.
func _goal_from_component(walk: Walkable, spawn_cell: Vector2, bbox: Rect2i) -> Vector2i:
	const MAX_VISITED := 20000
	const NEIGHBOURS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var start := Vector2i(floori(spawn_cell.x), floori(spawn_cell.y))
	if not walk.is_open(start.x, start.y):
		return PathWindow.NO_GOAL
	var bounded := bbox.size != Vector2i.ZERO
	var visited := {start: true}
	var queue: Array[Vector2i] = [start]
	var farthest := start
	var farthest_d2 := 0
	var qi := 0
	while qi < queue.size() and visited.size() < MAX_VISITED:
		var cur: Vector2i = queue[qi]
		qi += 1
		var d2 := (cur - start).length_squared()
		if d2 > farthest_d2:
			farthest_d2 = d2
			farthest = cur
		for d: Vector2i in NEIGHBOURS:
			var n := cur + d
			if bounded and not bbox.has_point(n):
				continue
			if visited.has(n) or not walk.is_open(n.x, n.y):
				continue
			visited[n] = true
			queue.append(n)
	return farthest


## --window-probe: a no-session self-check of PathWindow's pure geometry --
## no camera, no view, no registry, no Sim tick loop, only the static origin
## function and the two static geometry helpers. Task 2's acceptance gate
## parses this function's own stdout, so every printed line follows the
## house fact-line convention and every assertion prints a PASS/MISMATCH
## verdict token rather than merely trusting silence -- `grep -q MISMATCH`
## on the whole output is the gate's one failure check.
func _window_probe(world: Sacred.World) -> void:
	var stride := PathWindow.STRIDE
	# Cells spanning several stride buckets on both sides of zero -- negative
	# cells included, since origin_for() must floor-divide correctly there
	# too, matching Movement.sweep's own negative-coordinate precedent.
	var cells: Array[Vector2i] = [
		Vector2i(0, 0), Vector2i(stride - 1, 0), Vector2i(stride, 0),
		Vector2i(2 * stride, 0), Vector2i(2 * stride + 3, 3),
		Vector2i(-1, -1), Vector2i(-stride, -stride), Vector2i(-stride - 1, -stride - 1),
		Vector2i(-2 * stride, 5),
	]
	var mismatch := false
	var prev_origin := Vector2i.ZERO
	var prev_bucket := Vector2i.ZERO
	var has_prev := false
	for cell: Vector2i in cells:
		var origin := PathWindow.origin_for(cell)
		print("window\tcell=%d,%d\torigin=%d,%d" % [cell.x, cell.y, origin.x, origin.y])
		var bucket := Vector2i(floori(float(cell.x) / float(stride)), floori(float(cell.y) / float(stride)))
		if has_prev:
			if bucket == prev_bucket:
				var verdict := "PASS" if origin == prev_origin else "MISMATCH"
				if verdict == "MISMATCH":
					mismatch = true
				print("window\tcheck=same_bucket_same_origin\t%s" % verdict)
			else:
				var expect := prev_origin + (bucket - prev_bucket) * stride
				var verdict := "PASS" if origin == expect else "MISMATCH"
				if verdict == "MISMATCH":
					mismatch = true
				print("window\tcheck=adjacent_bucket_one_stride\t%s" % verdict)
		prev_origin = origin
		prev_bucket = bucket
		has_prev = true

	# Same cell twice, unrelated work between -- origin_for() is `static` and
	# reads nothing but its argument, so repeating it must reproduce exactly.
	var repeat_cell := Vector2i(37, -91)
	var first := PathWindow.origin_for(repeat_cell)
	var _unrelated := PathWindow.point_count() + int(PathWindow.max_corner_distance())
	var second := PathWindow.origin_for(repeat_cell)
	var det_verdict := "PASS" if first == second else "MISMATCH"
	if det_verdict == "MISMATCH":
		mismatch = true
	print("window\tcheck=repeat_call_determinism\t%s" % det_verdict)

	var point_count := PathWindow.point_count()
	var world_cells := int(world.size.x) * int(world.size.y) * SECT * SECT
	var ratio := float(point_count) / float(world_cells)
	print("window\tpoint_count=%d\tworld_cells=%d\tratio=%.6f" % [point_count, world_cells, ratio])

	var max_dist := PathWindow.max_corner_distance()
	print("window\tmax_corner_dist=%.6f\tr_load=%.6f\tbelow_r_load=%s" % [
		max_dist, Sim.R_LOAD, max_dist < Sim.R_LOAD])

	print("window\tresult=%s" % ("MISMATCH" if mismatch else "PASS"))
	get_tree().quit(1 if mismatch else 0)


## --follow-probe: IsoCamera.follow_cell() fed a fixed cell carrying a
## deliberate sub-cell fraction, at each of the three measured ZOOM_SCALES
## steps in turn. No session, no player, no streaming -- pure geometry,
## mirroring --window-probe's shape (R3.4: the three measured steps, proven
## by a printed check rather than asserted). A real IsoCamera is built and
## added to the tree (never a hand-rolled stand-in) because follow_cell's
## own odd-viewport-height guard reads get_viewport(), which needs a node
## actually in the scene tree to answer.
func _follow_probe() -> void:
	# 3232.37,3232.61: fractional in both cell axes, so cell_to_world's
	# (x-y)/(x+y) combination keeps a non-trivial fraction on both projected
	# world axes too -- verified by hand to differ from its snapped target
	# at all three zoom steps, not just a coincidental one.
	var probe_cell := Vector2(3232.37, 3232.61)
	var cam := IsoCamera.new()
	add_child(cam)
	var mismatch := false
	for i in IsoCamera.ZOOM_SCALES.size():
		cam.set_zoom_index(i)
		var scale: float = IsoCamera.ZOOM_SCALES[i]
		var unsnapped := IsoCamera.cell_to_world(probe_cell)
		cam.follow_cell(probe_cell)
		var snapped := Vector2(cam.position.x, cam.position.y)
		# Independent of follow_cell's own arithmetic: "on the pixel grid at
		# scale s" means snapped*s is a whole number, checked here rather
		# than trusted from how the value was produced.
		var on_grid := is_equal_approx(snapped.x * scale, roundf(snapped.x * scale)) \
			and is_equal_approx(snapped.y * scale, roundf(snapped.y * scale))
		if not on_grid:
			mismatch = true
		print("follow\tstep=%d\tscale=%.6f\tunsnapped=%.6f,%.6f\tsnapped=%.6f,%.6f\tverdict=%s" % [
			i, scale, unsnapped.x, unsnapped.y, snapped.x, snapped.y,
			"MISMATCH" if not on_grid else "PASS"])
	cam.queue_free()
	get_tree().quit(1 if mismatch else 0)


## Builds the Walkable navmesh, derives (or takes the override for) the
## spawn cell, spawns the player, and dispatches into a record run or a
## replay run. Normally builds no camera or SectorView at all --
## _focus_cell() resolves through the player once one exists (above), so
## neither mode depends on anything drawn, matching _show_model's no-view
## shape.
##
## --liveview (Task 3 Gate 2 only) is the one exception: paired with
## --record=, it builds the camera, the streamer and the player mesh exactly
## like the default streaming branch does, so the recording run has the
## whole view layer switched on -- camera following, sectors streaming,
## player drawn -- while --replay= (no --liveview passed) stays exactly the
## no-view path it always was. D-14 says camera/streaming state must never
## reach the dump; the only way to prove that is to make the two runs differ
## in nearly everything BUT the simulation, which is what this gives Gate 2.
func _run_record_or_replay(world: Sacred.World, install: String, tex_pak: Sacred.Pak,
		tiles: Sacred.Tiles, statics: Sacred.Statics, mixed: Sacred.Mixed, items: Sacred.Items) -> void:
	var argv := OS.get_cmdline_user_args() + OS.get_cmdline_args()
	var live_view := "--liveview" in argv
	var walk := Walkable.new(world)
	var spawn := _resolve_spawn(walk)
	if spawn.is_empty():
		printerr("record/replay\tno walkable spawn cell found")
		get_tree().quit(1)
		return
	var cell: Vector2 = spawn["cell"]
	print("spawn\tcell=%.6f,%.6f\tclass=%d\tcomponent=%d\tsectors=%d" % [
		cell.x, cell.y, spawn["class"], spawn["component"], spawn["sectors"]])

	var rec_id := _first_real_record_id()
	_player_id = _registry.spawn(rec_id, cell, 100, 100)
	_sim.walk = walk
	_sim.focus_actor_id = _player_id

	if live_view and _record_path != "":
		_cam = IsoCamera.new()
		_cam.cell_limit = Vector2(world.size) * SECT
		add_child(_cam)
		_view = SectorView.new()
		_view.name = "SectorView"
		_view.setup(_cam, tex_pak, tiles, world, statics, mixed, items, {})
		add_child(_view)
		_cam.set_zoom_index(1)
		_cam.look_at_cell(cell)
		var models_pak := Sacred.Pak.new(install.path_join("pak/models.pak"))
		if models_pak.is_open():
			_player_view = PlayerView.new(Sacred.Models.new(models_pak))
			if _player_view.node != null:
				add_child(_player_view.node)
				print("player\tmodel=%s\tindex=%d\tverts=%d\ttris=%d" % [
					PlayerView.MODEL_NAME, _player_view.model_index,
					_player_view.vertex_count, _player_view.triangle_count])

	# Plan 04-02: the sliding path window and its one scripted goal request,
	# derived from the ACTUAL spawn component -- never a hardcoded cell, so
	# it stays a real goal against whatever install is loaded.
	_path_window = PathWindow.new(walk)
	_sim.path_window = _path_window
	var bbox: Rect2i = spawn.get("bbox", Rect2i())
	_goal_cell = _goal_from_component(walk, cell, bbox)
	print("goal\tcell=%d,%d" % [_goal_cell.x, _goal_cell.y])

	if _dump_path != "":
		_dumper = Replay.Dumper.new(_dump_path)
		if _dumper.is_open():
			# ponytail-adjacent bugfix, not a placeholder: the closure takes
			# tick/dropped/astar_event as call() arguments rather than
			# capturing `sim` (which IS _sim, the object this closure is
			# stored ON as output_hook) -- capturing it would make Sim hold
			# a Callable that holds a strong ref back to Sim itself, a
			# self-cycle RefCounted's plain refcounting can never collect,
			# which is exactly what leaked ~120 objects (Sim + its reg +
			# walk + walk's whole _region_cache) at process exit until this
			# fix. `path_window` is safe to capture -- it holds no reference
			# back to Sim.
			var dumper := _dumper
			var reg := _registry
			_sim.output_hook = func(tick: int, dropped: int, astar_event: Dictionary) -> void:
				dumper.write_tick(tick, dropped, reg)
				dumper.write_astar(tick, astar_event)

	if _record_path != "":
		await _run_record()
	else:
		await _run_replay()


## Drives the normal per-frame loop (via _process -> _advance_sim, the one
## real advance call site) until _autoplay_ticks ticks have run, writing
## input/gap lines the whole way, then closes the recording and the dump
## and quits.
func _run_record() -> void:
	_recorder = Replay.Recorder.new(_record_path, _sim.tick_hz, _registry.get_actor(_player_id).cell, _player_id)
	if not _recorder.is_open():
		get_tree().quit(1)
		return
	for _i in RECORD_FRAME_BUDGET:
		await get_tree().process_frame
		if not is_instance_valid(self):
			return
		if _sim.tick >= _autoplay_ticks:
			break
	_recorder.close()
	if _dumper != null:
		_dumper.close()
	get_tree().quit(0)


## Suppresses _process()'s normal advance call (_replay_active, mirroring
## _probe_active) and hands the whole drive loop to Replay.replay(), which
## drives one tick per recorded line straight through Sim's per-tick entry
## point and never touches the accumulator (D-04).
func _run_replay() -> void:
	_replay_active = true
	# Task 3: the third perturbation mode. Off unless --falsify-mode=origin
	# is passed alongside --falsify=TICK -- the offset itself is a plain
	# number sourced here at the composition root (ORIGIN_PERTURB_OFFSET),
	# never anything camera-derived and never anything inside world/.
	var origin_perturb := ORIGIN_PERTURB_OFFSET if _falsify_mode == "origin" else Vector2i.ZERO
	var err := Replay.replay(_replay_path, _sim, _registry, _player_id,
		_falsify_tick, _falsify_mode, origin_perturb)
	if _dumper != null:
		_dumper.close()
	get_tree().quit(0 if err == OK else 1)


## Pumps frames until the view reports settled, or `budget` frames pass.
## Mirrors _maybe_screenshot's await + is_instance_valid idiom -- this node
## can be freed mid-coroutine.
func _pump_until_settled(budget: int) -> void:
	for _i in budget:
		# process_frame, not RenderingServer.frame_post_draw: under plain
		# --headless there is no draw pass, so frame_post_draw never fires and
		# this coroutine would park forever (observed directly -- see the
		# deviation note in 01-01-SUMMARY.md). process_frame fires once per
		# main-loop iteration regardless of whether anything is drawn.
		await get_tree().process_frame
		if not is_instance_valid(self):
			return
		if _view.is_settled():
			return


## Scans mixed.pak source indices upward from 1 for the first record that
## resolves to REAL art (def() non-empty and tiles > 0) -- 15840 of 32096
## mixed.pak entries have zero tiles, so picking blindly would land on one
## roughly half the time. Falls back to record_id 0 (an out-of-range kind,
## always resolving to the shared empty def) if none is found, which should
## not happen against any real install.
func _first_real_record_id() -> int:
	var source := 1
	while source < _records.count():
		var id := RecordStore.make_id(RecordStore.KIND_STATIC_ART, source)
		var d := _records.def(id)
		if not d.is_empty() and int(d.get("tiles", 0)) > 0:
			return id
		source += 1
	push_error("_first_real_record_id: no mixed.pak entry with tiles > 0 found")
	return 0


## --actor-probe=N end-to-end demonstration: spawns a fixed, deterministic
## actor set, ticks it by exact count through the real Sim.advance, then
## walks a real streaming route that queue_free's and rebuilds sector 50,50
## -- printing facts that let the survival and route-independence checks in
## 01-01-PLAN.md's acceptance criteria be asserted with plain grep/diff.
## "Exactly n ticks" holds at ANY --tickhz=: the loop below drives advance()
## with _sim.tick_dt() (the instance's own configured delta), not the class
## constant, so tick=n regardless of the tick rate in effect.
func _actor_probe(n: int, route: String) -> void:
	# Set before anything else, so no frame pumped below can inject a
	# wall-clock tick via _process's normal _advance_sim call.
	_probe_active = true

	# 1. Settle on the probe's home sector before spawning or ticking.
	_cam.set_zoom_index(1)
	_cam.look_at_cell(PROBE_FOCUS)
	await _pump_until_settled(PROBE_FRAME_BUDGET)
	if not is_instance_valid(self):
		return

	# 2. A fixed, deterministic actor set. Actor 1 is stationary and wounded
	# -- its hp is the survival witness, untouched by Sim._step_actor by
	# construction. Every probe actor carries a REAL record_id, resolved
	# through RecordStore (plan 02) -- never a bare placeholder index.
	#
	# Offsets (task 3, R10.3) are chosen so id1/id3/id4/id2 land at strictly
	# increasing d^2 (0, 4, 36, 64) while ids 5..16 form a twelve-actor ring
	# whose d^2 is EXACTLY 25 for every member -- small-integer offsets whose
	# squares sum to 25 exactly, so the primary sort key is exactly, not
	# approximately, tied. An approximate tie would not exercise
	# Array.sort_custom's heapsort instability (R10.3, order_by_distance).
	var rec_id := _first_real_record_id()
	var id1 := _registry.spawn(rec_id, PROBE_FOCUS, 7, 149)
	_registry.get_actor(id1).heading = Vector2.ZERO
	var id2 := _registry.spawn(rec_id, PROBE_FOCUS + Vector2(0.0, 8.0), 149, 149)
	_registry.get_actor(id2).heading = Vector2(1.0, 0.0)
	var id3 := _registry.spawn(rec_id, PROBE_FOCUS + Vector2(2.0, 0.0), 149, 149)
	_registry.get_actor(id3).heading = Vector2(0.0, 1.0)
	var id4 := _registry.spawn(rec_id, PROBE_FOCUS + Vector2(0.0, 6.0), 149, 149)
	_registry.get_actor(id4).heading = Vector2(1.0, 1.0).normalized()

	# ids 5..16: the tie ring, stationary (heading=ZERO) so it cannot drift
	# and the order printed below stays exact for the whole run, not just
	# before the first tick. Spawned in exactly this order -- the order line
	# asserts the ids came out in SPAWN order among themselves, which is what
	# distinguishes "comparator broke the tie by id" from "comparator left
	# heapsort's internal order showing through".
	var tie_ring: Array[Vector2] = [
		Vector2(5.0, 0.0), Vector2(-5.0, 0.0), Vector2(0.0, 5.0), Vector2(0.0, -5.0),
		Vector2(3.0, 4.0), Vector2(4.0, 3.0), Vector2(-3.0, 4.0), Vector2(-4.0, 3.0),
		Vector2(3.0, -4.0), Vector2(4.0, -3.0), Vector2(-3.0, -4.0), Vector2(-4.0, -3.0),
	]
	for offset: Vector2 in tie_ring:
		var tid := _registry.spawn(rec_id, PROBE_FOCUS + offset, 149, 149)
		_registry.get_actor(tid).heading = Vector2.ZERO

	# ids 17..19: the three-radius boundary set (task 4, R10.2/R10.4), all
	# stationary. 17 sits at EXACTLY R_SIM -- in_radius's <= means it must
	# still tick. 18 is one cell further out -- outside R_SIM, inside
	# R_RENDER, must NOT tick. 19 sits inside R_LOAD, outside R_RENDER.
	var id17 := _registry.spawn(rec_id, PROBE_FOCUS + Vector2(Sim.R_SIM, 0.0), 149, 149)
	_registry.get_actor(id17).heading = Vector2.ZERO
	var id18 := _registry.spawn(rec_id, PROBE_FOCUS + Vector2(Sim.R_SIM + 1.0, 0.0), 149, 149)
	_registry.get_actor(id18).heading = Vector2.ZERO
	var id19 := _registry.spawn(rec_id, PROBE_FOCUS + Vector2(150.0, 0.0), 149, 149)
	_registry.get_actor(id19).heading = Vector2.ZERO

	# record\t... -- before any tick runs. Placed immediately before the
	# order (task 3) and bands (task 4) lines that land in this same slot.
	var rd := _records.def(rec_id)
	print("record\tid=%d\tkind=%d\tsprite=%d\tname=%s\ttiles=%d\treadonly=%s\tshared=%s" % [
		rec_id, RecordStore.kind_of(rec_id), RecordStore.source_of(rec_id),
		rd.get("name", ""), rd.get("tiles", 0), rd.is_read_only(),
		is_same(_records.def(rec_id), _records.def(rec_id))])

	# order\t... -- order_by_distance's composite key (dist_sq, then id) over
	# the whole registry, printed BEFORE any tick has moved actors 2/3/4 off
	# their spawn offsets -- printing after even one tick would make the
	# assertion approximate rather than exact (R10.3).
	var order := _sim.order_by_distance(_registry, PROBE_FOCUS)
	var order_strs: Array[String] = []
	for id: int in order:
		order_strs.append(str(id))
	print("order\t%s" % ",".join(order_strs))

	# bands\t... -- in_radius(PROBE_FOCUS, r) counts at each of the three
	# radii, before any tick (task 4, R10.2/R10.4). With the layout above,
	# 17 is exactly the sim boundary (inclusive), 18 the render boundary,
	# 19 the load boundary, so each band's count equals the id of the actor
	# that boundary is named after.
	print("bands\tsim=%d\trender=%d\tload=%d" % [
		_registry.in_radius(PROBE_FOCUS, Sim.R_SIM).size(),
		_registry.in_radius(PROBE_FOCUS, Sim.R_RENDER).size(),
		_registry.in_radius(PROBE_FOCUS, Sim.R_LOAD).size()])

	# 3. Exactly n ticks, driven by count, through the one real accumulator --
	# never by frame-delta, which would make the tick count route-dependent.
	# Uses _sim.tick_dt(), the INSTANCE's own configured delta (honors
	# --tickhz=), not the class constant Sim.TICK_DT -- the latter is sized
	# for the 30 Hz default only, so feeding it in here would silently drift
	# the tick count away from n whenever --tickhz differs from 30.
	for _i in n:
		_advance_sim(_sim.tick_dt(), PROBE_FOCUS)

	# 4. Walk the streaming route far enough that sector 50,50 leaves the
	# wanted set and is queue_free'd, then re-enters it. No ticks run during
	# the walk -- _probe_active is still true.
	_view.probe_unloaded = 0
	_view.probe_reloaded = 0
	var route_a: Array[Vector2] = [
		Vector2(3232.0, 3232.0), Vector2(3232.0, 3600.0), Vector2(3232.0, 3232.0)]
	var route_b: Array[Vector2] = [
		Vector2(3232.0, 3232.0), Vector2(3600.0, 3232.0),
		Vector2(3600.0, 3600.0), Vector2(3232.0, 3232.0)]
	var waypoints: Array[Vector2] = route_a if route == "a" else route_b
	for wp: Vector2 in waypoints:
		_cam.look_at_cell(wp)
		await _pump_until_settled(PROBE_FRAME_BUDGET)
		if not is_instance_valid(self):
			return

	# 5. Print, in this exact order: every registry dump line, the sim
	# summary, then one probe-diag line carrying every route-varying fact.
	# Nothing route-varying appears on any other line, so the non-diag
	# stdout is byte-identical between routes.
	var lines: Array[String] = []
	_registry.dump(lines)
	for line: String in lines:
		print(line)
	print("sim\ttick=%d\tdropped=%d" % [_sim.tick, _sim.dropped])
	print("probe-diag\troute=%s\tunloaded=%d\treloaded=%d\twaypoints=%d" % [
		route, _view.probe_unloaded, _view.probe_reloaded, waypoints.size()])

	# 6. The probe writes no files -- stdout only, then exit.
	get_tree().quit()


## --grn=NAME renders one Granny model from pak/models.pak instead of the
## sector streamer, so a single command turns retail bytes into a picture.
## Builds no SectorView at all, which is what _await_settled's no-view guard
## below exists to accommodate.
##
## NAME is resolved through Models.index_of against the pak's own 64-byte
## name fields. It never reaches the filesystem: no path_join, no
## FileAccess.open, no use of the trimmed argument as a path. An unresolvable
## name is fatal and loud -- rendering nothing while exiting 0 is the failure
## mode that makes a broken capture look like a working one.
func _show_model(install: String, name: String) -> void:
	var pak := Sacred.Pak.new(install.path_join("pak/models.pak"))
	if not pak.is_open():
		printerr("grn\tcannot open pak/models.pak under %s" % install)
		get_tree().quit(1)
		return
	var models := Sacred.Models.new(pak)
	var idx := models.index_of(name)
	if idx < 0:
		printerr("grn\tno model named %s in pak/models.pak (%d entries)" % [name, models.count()])
		get_tree().quit(1)
		return
	var view := ModelView.new()
	view.name = "ModelView"
	if not view.setup(models, idx):
		printerr("grn\t%s (index %d) has no decodable mesh" % [models.entry_name(idx), idx])
		# Never add_child'd, so nothing else frees it. quit() masks this on the
		# CLI path, but this function is the one a corpus sweep would call in a
		# loop, and there the orphans would accumulate.
		view.free()
		get_tree().quit(1)
		return
	add_child(view)
	print("grn\tindex %d\tname %s\tverts %d\ttris %d\tbasis %s" % [
		idx, models.entry_name(idx), view.vertex_count, view.triangle_count,
		"located" if view.basis_located else "unlocated"])
	# binds < count is normal, not a defect: a bone nothing is weighted to gets
	# no bind-array slot. sanitised counts bones whose stored name could not be
	# used verbatim -- currently all of them, because this format's bone record
	# stores no name.
	print("bones\tcount=%d\troots=%d\tbinds=%d\tsanitised=%d" % [
		view.bone_count, view.bone_roots, view.bind_count, view.bone_sanitised])
	# No rest-equals-bind verdict is printed any more. The assertion behind it
	# was circular -- both operands composed the same stored local rests -- so
	# it reported true unconditionally, including on a render a human rejected.
	# It is removed rather than replaced: the skeleton and skin layer is
	# unvalidated until an oracle independent of our own decode exists.
	await _maybe_screenshot()


## Waits for the streamer to settle, so a measurement/screenshot reflects a
## finished view rather than whatever one frame of loading happened to
## produce. Shared by every --shot=/--drawcalls consumer below -- a second,
## differently-timed wait is the mistake this factoring exists to prevent.
## Returns false if this node was freed while the coroutine was parked on an
## await (the caller must not touch `self`/`_view` after that), true
## otherwise.
func _await_settled() -> bool:
	# --grn= builds no SectorView, so there is nothing to poll; two presented
	# frames are enough for the capture. The streaming path below is reached
	# unchanged whenever a view exists, so its behaviour and timing are
	# untouched by this guard.
	if _view == null:
		await RenderingServer.frame_post_draw
		if not is_instance_valid(self):
			return false
		await RenderingServer.frame_post_draw
		return is_instance_valid(self)
	for _i in 600:
		await RenderingServer.frame_post_draw
		# The node can be freed while a coroutine is parked on an await.
		if not is_instance_valid(self):
			return false
		if _view.is_settled():
			await RenderingServer.frame_post_draw
			break
	return true


## --shot=FILE renders one frame, writes it, and exits. --drawcalls prints the
## per-frame RenderingServer draw-call count, read only after the same
## settle-await --shot= uses, so the value is guaranteed populated (plain
## --headless never submits a draw call and always reads 0 here). Either or
## both flags may be present in one invocation -- both share _await_settled()
## and the process quits once, after whichever branches ran. Neither flag
## present -> return immediately, preserving streaming mode's existing
## behaviour (never quits).
func _maybe_screenshot() -> void:
	var argv := OS.get_cmdline_user_args() + OS.get_cmdline_args()
	var want_drawcalls := "--drawcalls" in argv
	var shot_path := ""
	for arg in argv:
		if arg.begins_with("--shot="):
			shot_path = arg.trim_prefix("--shot=")
			break
	if not want_drawcalls and shot_path == "":
		return
	if not await _await_settled():
		return
	if want_drawcalls:
		var draw_calls := RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
		print("drawcalls\t%d" % draw_calls)
	if shot_path != "":
		var err := get_viewport().get_texture().get_image().save_png(shot_path)
		print("shot\t%s\t%s" % [shot_path, error_string(err)])
	get_tree().quit()
