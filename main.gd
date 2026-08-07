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
	for a in argv:
		if a.begins_with("--tickhz="):
			_tick_hz = clampi(int(a.trim_prefix("--tickhz=")), 1, 240)
		elif a.begins_with("--actor-probe="):
			_probe_ticks = int(a.trim_prefix("--actor-probe="))
		elif a.begins_with("--probe-route="):
			_probe_route = a.trim_prefix("--probe-route=")

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

	_cam = IsoCamera.new()
	_cam.cell_limit = Vector2(world.size) * SECT
	add_child(_cam)

	_view = SectorView.new()
	_view.name = "SectorView"
	_view.setup(_cam, tex_pak, tiles, world, statics, mixed, items, {
		"stats": stats, "markers": markers, "objects": objects, "interiors": interiors,
		"regions": show_regions, "exterior": exterior, "hide_levels": hide_levels,
		"only_flag": only_flag,
	})
	add_child(_view)

	var region := _region_arg()
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


func _process(delta: float) -> void:
	if _view != null:
		_view.stream(delta)
	if not _probe_active:
		_advance_sim(delta, _focus_cell())


## The ONLY Sim.advance call site outside godot-port/world/ -- a hard
## constraint, not a style preference: it is what makes "one tick loop" a
## greppable fact rather than a claim. Every caller of the sim goes through
## this one function.
func _advance_sim(dt: float, focus: Vector2) -> int:
	if _sim == null:
		return 0
	return _sim.advance(dt, _registry, focus)


func _focus_cell() -> Vector2:
	if _cam == null:
		return start_cell
	return _cam.world_to_cell(Vector2(_cam.position.x, _cam.position.y))


func _region_arg() -> Vector3i:
	for arg in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if not arg.begins_with("--region="):
			continue
		var p := arg.trim_prefix("--region=").split(",")
		if p.size() == 3:
			return Vector3i(int(p[0]), int(p[1]), int(p[2]))
	return Vector3i.ZERO


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


## --shot=FILE renders one frame, writes it, and exits. The counts are the unit
## check; this is the only thing that catches "right numbers, wrong pixels".
func _maybe_screenshot() -> void:
	for arg in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if not arg.begins_with("--shot="):
			continue
		# Wait for the streamer to settle, so the shot shows a finished view
		# rather than whatever one frame of loading happened to produce.
		for _i in 600:
			await RenderingServer.frame_post_draw
			# The node can be freed while a coroutine is parked on an await.
			if not is_instance_valid(self):
				return
			if _view.is_settled():
				await RenderingServer.frame_post_draw
				break
		var path := arg.trim_prefix("--shot=")
		var err := get_viewport().get_texture().get_image().save_png(path)
		print("shot\t%s\t%s" % [path, error_string(err)])
		get_tree().quit()
		return
