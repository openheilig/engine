class_name SectorView
extends Node3D

## Consumers attach sector-owned views before the completed sector is added.
signal sector_built(key: int, node: Node3D)

## Resumed only by stream(), never by a SceneTree signal after teardown.
signal _build_continue

## Streams Sacred's 100x100 sector grid straight out of the retail install,
## one MeshInstance3D + Texture2DArray per 64x64 sector, and builds the fixed
## block for --region= mode.
##
## Owns: the sector wanted-set, the load queue, mesh assembly, the image
## cache, and the debug overlays (object markers, region footprints).
##
## Defines no _process -- main.gd._process is the single per-frame entry
## point. It drives this node's stream() explicitly, alongside the sim
## accumulator, so streaming and simulation stay two statements in one
## function rather than two independently-ordered node callbacks (R10.2).
##
## Sits at Transform3D.IDENTITY (never moved, never scaled) so every sector
## mesh keeps the exact global transform it had as a direct child of the
## root -- the property phase 1 plan 03's byte-identical PNG gate tests.

const SECT: int = Sacred.SECT
const HW: float = IsoCamera.HW
const HH: float = IsoCamera.HH

## Per-quad Z = iso depth * DEPTH_STEP, so the depth buffer orders tiles across
## sector meshes. 12800 max depth * 0.05 = 640 world units, well inside `far`.
const DEPTH_STEP := 0.05

## Z bump per floor.pak overlay tile stacked on a cell, so each one lands in
## front of the ground and of the overlay below it. Must stay well under
## DEPTH_STEP, which is the gap to the NEXT cell's ground -- an overlay that
## reached that far would sort in front of its own neighbour's terrain.
const OVERLAY_Z := DEPTH_STEP * 0.1

## Overlay tiles a single cell may stack. The chain is a linked list with no
## stated bound, so this caps both the geometry and a corrupt-link runaway.
## ponytail: 8 is a guess with no measurement behind it; if a cell is ever
## observed truncated, count the real maximum before raising it.
const OVERLAY_MAX := 8


## Static painter order comes from the owning cell and its linked records,
## not sprite width or height. The old STRUCTURE_W=256 heuristic hid shelf
## candles behind their cabinet; the recovered cell-chain order exposes them
## at the authored coordinates (research finding 1222).

## --sortcube=CX,CY marker-cube side length in screen pixels -- one retail cell
## width (IsoCamera.HW * 2), so the proxy reads at the same scale a character
## sprite would.
const SORTCUBE_PX := 96.0

## Decoded 256x256 RGBA8 tiles are 256 KB each and the whole world uses 4328 of
## them (1.1 GB). Adjacent sectors share ~54% of their textures, so a cache pays
## for itself, but it has to be bounded.
## It showed up. At the old free zoom (up to 12000) a wide view wanted more than
## the cap, so clear-when-full evicted *everything* every few sectors and
## re-decoded continuously -- a --zoom=6000 render never settled and had to be
## killed. Two changes fix it: Sacred's three discrete zoom steps bound how many
## sectors can be in view at all (IsoCamera.ZOOM_SCALES), and eviction is now
## partial FIFO rather than a full clear, so a momentary overshoot costs a
## quarter of the cache instead of all of it.
const IMAGE_CACHE_MAX := 768
const IMAGE_CACHE_EVICT := 192   ## a quarter, dropped oldest-first

## preload, not load: _build_sector runs per streamed sector, which is a hot
## path, and load() would hit ResourceLoader every time.
## Preloaded by PATH and with no class_name, the same way player_view.gd takes
## rig_placement.gd: a newly added global class is not in the script-class cache
## for a `--path` run until the project is reimported.
const LiquidScript := preload("res://view/liquid.gd")

## Z bump for the animated liquid surface, in the same per-cell budget the
## floor.pak overlays spend OVERLAY_Z out of. Above every overlay (8 * 0.1 =
## 0.8 of the step) so the water covers its own bed, and still under the full
## DEPTH_STEP that reaches the NEXT cell's ground.
const LIQUID_Z := DEPTH_STEP * 0.9

const FloorViewScript := preload("res://view/floor_view.gd")
const ModelCanvasScript := preload("res://view/model_canvas.gd")


@export var load_margin := 64.0                    ## cells loaded beyond the viewport
const BUILD_SLICE_USEC := 3000
## Screen pixels per unit of WldxEntry height. Unknown; 1.0 is a starting guess.
@export var height_scale := 1.0

var _cam: IsoCamera
var _tex_pak: Sacred.Pak
## Owns the animated liquid materials and their frame decoding, cached across
## sectors -- a 50-frame set is 50 decodes and the sea spans hundreds of them.
var _liquid: RefCounted
var _tiles: Sacred.Tiles
var _world: Sacred.World
var _floor: Sacred.Pak                    ## world/floor.pak, the overlay-tile layer; null = don't draw it
var _floor_view := FloorViewScript.new()
## Typed collections (Godot 4.4+): the key/value contracts here are the whole
## reason the streamer is readable, so they are worth stating.
var _loaded: Dictionary[int, MeshInstance3D] = {}  ## sector key -> mesh, null if it draws nothing
var _images: Dictionary[int, Image] = {}           ## texture.pak id -> decoded tile
var _statics: Sacred.Statics
var _mixed: Sacred.Mixed
var _items: Sacred.Items
var _interior: Interior
var _show_regions := false                ## --regions: overlay building footprints
var _show_flags1e := false                ## --flags1e: overlay WldxEntry +0x1e bits (row 708)
var _spawns: Dictionary = {}              ## --spawns: sector -> tier, see main.gd
var _show_classhi := false                ## --classhi: overlay the +0x1f HIGH nibble
var _hide_levels := 0                     ## --hidelevel=N: bitmask of levels to drop
var _exterior := false                    ## --exterior: drop each building's top level
var _pending: Array[int] = []             ## sectors queued for a later frame
var _wanted: Dictionary[int, bool] = {}
var _build_job: Dictionary = {}
var _slice_deadline := 0
var _slice_frame := -1
var _admission_revision := 0
var _region_loading := false
var _region_revision := 0
var _last_view := Vector3(NAN, NAN, NAN)  ## camera x/y/zoom the wanted-set was derived from
var _in_sync := false                     ## wanted-set/queue reconciled with the current camera
var _streaming := true
var _stats := false
var _objects := true                      ## draw static object sprites
var _markers := false                     ## ...as flat coloured squares instead
var _only_flag := -1                      ## debug: draw only objects with this +0x08 flag
## OBJ_TRACE=gx,gy: log every submitted object of that sector (id, class,
## trigger/mask, quads emitted, anchor pos = painter sort key, sprite size).
## Diagnostic only, off unless set.
var _obj_trace := Vector2i(-1, -1)
## OBJ_ONLY_SIDS=a,b,c: draw only these static types. Diagnostic only.
var _only_sids: Dictionary[int, bool] = {}
var _sortcube := Vector2i(-1, -1)         ## --sortcube=CX,CY: character-proxy marker cube cell, (-1,-1) = off
var sector_build_calls: int = 0
var _object_data: Dictionary[int, Dictionary] = {}
## Authored vertices and per-object spans survive raw trigger-state changes.

## Sector unload/(re)load counters. Not gated on anything view-side (a view has
## no notion of "probe") -- counted unconditionally, cheaply, on every event.
## main.gd's _actor_probe resets both to 0 immediately before its route walk
## and reads them back for the probe-diag line, so only that window's events
## are ever observed; this is exactly equivalent to the pre-extraction code's
## `if _probe_active:` guard, which also only mattered across that same
## reset-to-read window.
var probe_unloaded := 0
var probe_reloaded := 0
var _scene_actors: Dictionary[int, Dictionary] = {}
## Main's authored model queue participates in complete-scene readiness.
var pending_scripted_objects := 0
var _placement_serial := 0

func _init() -> void:
	add_child(_floor_view)



## Assigns the shared readers and camera reference, and the CLI-derived
## options main.gd already parsed. Called by main.gd before add_child().
##
## opts keys (all optional; default matches what an absent CLI flag meant):
##   stats: bool        -- --stats
##   markers: bool      -- --markers
##   objects: bool      -- not --noobjects (default true)
##   regions: bool      -- --regions
##   exterior: bool     -- --exterior
##   hide_levels: int   -- --hidelevel= bitmask (default 0)
##   only_flag: int     -- --onlyflag=, or -1 for "off" (default -1)
##   sortcube: Vector2i -- --sortcube=CX,CY character-proxy marker cube cell,
##                         or Vector2i(-1,-1) for "off" (default Vector2i(-1,-1))
func setup(cam: IsoCamera, tex_pak: Sacred.Pak, tiles: Sacred.Tiles, world: Sacred.World,
		statics: Sacred.Statics, mixed: Sacred.Mixed, items: Sacred.Items, opts: Dictionary) -> void:
	_cam = cam
	var shadow_texture: Texture2D
	if opts.get("objects", true) and not opts.get("markers", false):
		var shadow_id := Sacred.TextureFormat.find_model_texture(tex_pak, "SHADOW_TREE00.TGA")
		if shadow_id >= 0:
			var image := Sacred.TextureFormat.decode_texture(tex_pak, shadow_id, false)
			if image != null:
				shadow_texture = ImageTexture.create_from_image(image)
		if shadow_texture == null:
			push_error("SectorView: native SHADOW_TREE00 texture is unavailable")
	_floor_view.configure(cam, shadow_texture)
	_tex_pak = tex_pak
	_liquid = LiquidScript.new(tex_pak)
	_tiles = tiles
	_world = world
	_statics = statics
	_mixed = mixed
	_items = items
	_interior = opts.get("interior", null)
	if opts.get("objects", true) and _statics != null and _interior == null:
		push_error("SectorView: exact static admission requires shared Interior/Triggers")
	if _interior != null:
		_interior.state_changed.connect(_on_trigger_state_changed)
	_stats = opts.get("stats", false)
	_markers = opts.get("markers", false)
	_objects = opts.get("objects", true)
	_show_regions = opts.get("regions", false)
	_show_flags1e = opts.get("flags1e", false)
	_show_classhi = opts.get("classhi", false)
	_spawns = opts.get("spawns", {})
	_exterior = opts.get("exterior", false)
	_hide_levels = opts.get("hide_levels", 0)
	_only_flag = opts.get("only_flag", -1)
	_sortcube = opts.get("sortcube", Vector2i(-1, -1))
	_floor = opts.get("floor_pak", null)
	# Added once, here, as a direct child of self -- never a child of a sector
	# node, which stream()/_add_sector() frees on unload (T-02-05). A direct
	# child persists across every sector load/unload the streamer performs.
	if _sortcube.x >= 0:
		var _sortcube_mesh := _build_sortcube()
		add_child(_sortcube_mesh)


## Main owns the per-frame entry point; no private _process races the sim.
func stream(_delta: float) -> void:
	if not is_inside_tree() or is_queued_for_deletion():
		return
	for id: int in _scene_actors.keys():
		if not is_instance_valid(_scene_actors[id]["model"]):
			_retire_actor(id)
	_stream_sectors()
	# Composition runs at frame_pre_draw, after actor placement and skin updates.
	if DisplayServer.get_name() == "headless":
		_floor_view.sync()

## Keep one crop target per live model, but preserve every native grid-phase
## occurrence. Ownership stays with the original parent (including sectors).
func place_actor(model: Node3D, type_id: int, cell: Vector2, support_ref: int,
		layer: int = 0) -> void:
	if not is_instance_valid(model) or model.is_queued_for_deletion() or _interior == null or _items == null:
		return
	var id := model.get_instance_id()
	var actor: Dictionary = _scene_actors.get(id, {})
	if actor.is_empty():
		var parent := model.get_parent()
		if parent == null:
			push_error("SectorView.place_actor: model must be parented first")
			return
		var capture := ModelCanvasScript.new()
		capture.name = "SceneCapture_%s" % model.name
		parent.add_child(capture)
		capture.capture(model)
		actor = {"model": model, "capture": capture, "type": type_id,
			"cell": Vector2(NAN, NAN), "support": -1, "layer": layer, "sequence": 0}
		_scene_actors[id] = actor
		model.tree_exiting.connect(_retire_actor.bind(id), CONNECT_DEFERRED)
	if actor["cell"] == cell and actor["support"] == support_ref \
			and actor["type"] == type_id and actor["layer"] == layer:
		return
	_placement_serial += 1
	actor["sequence"] = _placement_serial
	actor["cell"] = cell
	actor["support"] = support_ref
	actor["layer"] = layer
	actor["type"] = type_id
	_apply_actor_admission(actor)


func _retire_actor(id: int) -> void:
	if not _scene_actors.has(id):
		return
	var actor: Dictionary = _scene_actors[id]
	# Exiting the tree also happens during temporary removal/reparenting.
	# Retirement follows destruction, not visibility or tree membership.
	if is_instance_valid(actor["model"]) and not actor["model"].is_queued_for_deletion():
		return
	_scene_actors.erase(id)
	_floor_view.remove_actor(id)
	if is_instance_valid(actor["capture"]) and not actor["capture"].is_queued_for_deletion():
		actor["capture"].queue_free()


func _apply_actor_admission(actor: Dictionary) -> void:
	if not is_instance_valid(actor["model"]):
		return
	var phases: Array[Vector3i] = []
	var position: Vector2 = actor["cell"]
	var cell := Vector2i(floori(position.x), floori(position.y))
	var type_id: int = actor["type"]
	var flags := _items.draw_flags(type_id)
	var admitted := _items.has_definition(type_id) and (flags & 2) != 0
	# Ordinary consumer's independent parent mask gate (LGP 0x080E7416).
	if admitted and (flags & 0x1000) != 0:
		var parent := _interior.parent_for_cell(cell)
		if not parent.is_empty():
			var trigger_id: int = parent["trigger"]
			if _interior.triggers.has_trigger(trigger_id):
				var record := _statics.blob(parent["id"])
				admitted = (_interior.state(trigger_id) & ((2 * int(record[53])) | 1)) != 0
	if admitted:
		var category := _items.category_of(type_id)
		for support_order: int in _interior.dynamic_support_orders(cell, actor["support"]):
			var pass_id := 3
			if category == 12:
				if (flags & 0x800000) != 0:
					pass_id = 4
				elif (flags & 4) != 0 and (support_order < 0 or actor["layer"] == 0):
					pass_id = 0
			phases.append(Vector3i(pass_id, support_order, 1 if category == 12 else 0))
	_floor_view.set_actor(actor["model"], actor["capture"],
		(cell.x + cell.y) * 6400 + cell.x, actor["sequence"], phases)



func _stream_sectors() -> void:
	if _streaming:
		if _cam == null:
			return
		var view := Vector3(_cam.position.x, _cam.position.y, _cam.size)
		if view != _last_view or not _in_sync:
			_last_view = view
			_wanted = _wanted_sectors()
			# Reconcile before advancing any work: camera jumps must never
			# finish a stale backlog before looking at the new wanted set.
			if not _build_job.is_empty() and not _wanted.has(_build_job["key"]):
				_cancel_build()
			for key: int in _loaded.keys():
				if not _wanted.has(key):
					var node: Node = _loaded[key]
					if node != null:
						node.queue_free()
					_object_data.erase(key)
					_loaded.erase(key)
					_floor_view.remove_sector(key)
					probe_unloaded += 1
			_pending.clear()
			for key: int in _wanted:
				if not _loaded.has(key) and (_build_job.is_empty() or _build_job["key"] != key):
					_pending.append(key)
			var here := _cam.world_to_cell(Vector2(_cam.position.x, _cam.position.y)) / SECT
			_pending.sort_custom(func(a: int, b: int) -> bool:
				return _sector_dist(a, here) < _sector_dist(b, here))
			_in_sync = true
	elif not _in_sync:
		# Re-entered fixed-region owners retain the desired block but never
		# resume the detached job cancelled by _exit_tree.
		_pending.clear()
		for key: int in _wanted:
			if not _loaded.has(key):
				_pending.append(key)
		_in_sync = true
	# A fixed-region coroutine and main may both call stream in one frame.
	# They share one allowance, not one allowance per invocation/sector.
	var frame := Engine.get_process_frames()
	if _slice_frame == frame:
		return
	_slice_frame = frame
	_slice_deadline = Time.get_ticks_usec() + BUILD_SLICE_USEC
	if not _build_job.is_empty():
		_build_continue.emit()
	while _build_job.is_empty() and not _pending.is_empty() \
			and Time.get_ticks_usec() < _slice_deadline:
		_add_sector(_pending.pop_front())


func _build_checkpoint(job: Dictionary) -> bool:
	if job["cancelled"]:
		return false
	if Time.get_ticks_usec() >= _slice_deadline:
		job["cpu_usec"] += Time.get_ticks_usec() - job["slice_start"]
		await _build_continue
		job["slice_start"] = Time.get_ticks_usec()
	return not job["cancelled"]


func _cancel_build() -> void:
	if _build_job.is_empty():
		return
	_build_job["cancelled"] = true
	# All suspended construction unwinds now while this owner is alive.
	# The job owns its detached node and drops it in _add_sector.
	_build_continue.emit()


func _exit_tree() -> void:
	_region_revision += 1
	_region_loading = false
	_cancel_build()
	_pending.clear()
	_slice_frame = -1
	_last_view = Vector3(NAN, NAN, NAN)
	_in_sync = false


func _sector_dist(key: int, here: Vector2) -> float:
	return Vector2(key % 100, key / 100).distance_squared_to(here)


## Sector keys whose 64x64 block intersects the padded viewport.
func _wanted_sectors() -> Dictionary[int, bool]:
	var box := _cam.visible_cells(load_margin)
	var lo := (box.position / SECT).floor()
	var hi := (box.end / SECT).ceil()
	var out: Dictionary[int, bool] = {}
	for gy in range(maxi(int(lo.y), 0), mini(int(hi.y) + 1, _world.size.y)):
		for gx in range(maxi(int(lo.x), 0), mini(int(hi.x) + 1, _world.size.x)):
			if _world.has_sector(gx, gy):
				out[gy * 100 + gx] = true
	return out


func _add_sector(key: int) -> void:
	var job := {"key": key, "cancelled": false, "node": null,
		"terrain": {}, "objects": {}, "cpu_usec": 0, "slice_start": Time.get_ticks_usec()}
	_build_job = job
	var node := await _build_sector(key % 100, key / 100, job)
	# Admission may change during geometry construction. Stage it using the
	# latest trigger revision, then publish without another yield.
	var run: Dictionary = job["objects"]
	if not job["cancelled"] and not run.is_empty():
		var revision := -1
		while revision != _admission_revision and not job["cancelled"]:
			revision = _admission_revision
			for span: Dictionary in run["spans"]:
				if not await _build_checkpoint(job):
					break
				var trigger_id: int = span["trigger"]
				span["admitted"] = trigger_id < 0 or span["mask"] == _interior.state(trigger_id)
	if job["cancelled"]:
		if is_instance_valid(job["node"]):
			job["node"].free()
		_build_job = {}
		return
	job["cpu_usec"] += Time.get_ticks_usec() - job["slice_start"]
	if _stats:
		print("sector\t%d,%d\t%d quads\t%d tex\t%.1f ms\tcache=%d" % [
			key % 100, key / 100,
			0 if node == null else int(node.get_meta("quads")),
			0 if node == null else int(node.get_meta("layers")),
			job["cpu_usec"] / 1000.0, _images.size()])
	# Commit is synchronous. No reader, signal consumer, or FloorView sees
	# a half-built sector or admissions sampled across different revisions.
	var terrain: Dictionary = job["terrain"]
	if not terrain.is_empty():
		_floor_view.set_sector(key, terrain["texture"], terrain["arrays"],
			terrain["masked"], terrain["metadata"], terrain["masked_metadata"])
	if not run.is_empty():
		_object_data[key] = run
		_floor_view.set_objects(key, run)
	_loaded[key] = node
	if node != null:
		sector_built.emit(key, node)
		add_child(node)
	probe_reloaded += 1
	_build_job = {}


## One sector -> one MeshInstance3D with its own Texture2DArray. Returns null if
## the sector holds no drawable tile.
func _build_sector(gx: int, gy: int, job: Dictionary) -> MeshInstance3D:
	sector_build_calls += 1
	var cells := _world.entries(gx, gy)
	if cells.is_empty():
		return null
	if not await _build_checkpoint(job):
		return null
	var regions: Sacred.Regions
	if _show_regions:
		regions = Sacred.Regions.new(_world.sector(gx, gy), gx, gy)
		if not await _build_checkpoint(job):
			return null

	var layer_of: Dictionary[int, int] = {}   ## texture.pak id -> layer in this sector's array
	var images: Array[Image] = []
	var pos := PackedVector3Array()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var col := PackedColorArray()
	var idx := PackedInt32Array()
	var floor_metadata := PackedInt32Array()
	# Masked and unmasked payloads retain their cell/stack identity. FloorView
	# merges their chains into retail's global, encoded-space painter passes.
	var bpos := PackedVector3Array()
	var buv := PackedVector2Array()
	var buv2 := PackedVector2Array()
	var bcol := PackedColorArray()
	var bcus := PackedFloat32Array()
	var bidx := PackedInt32Array()
	var masked_metadata := PackedInt32Array()
	# Liquid surfaces: the animated liquid pass (rows 1008/1010). Retail draws
	# liquid over the ordinary ground rather than instead of it, so the bed
	# tile stays in the first surface and this rides just above it -- which is
	# also why the open sea looked like flat grey-tan ground before this
	# existed, its bed being one repeated ISO00 tile across all 4096 cells.
	# TWO accumulators, not one and not a map: the two liquid nibbles select
	# two per-sector ids (keyx record bytes 736/737, resolved once here --
	# they cannot vary within a sector) and 22 retail sectors really carry two
	# different liquids at once. Packed arrays are value types, so a map of
	# them cannot be appended to in place; two named sets can.
	var lid9: int = _liquid.material_id(_world, gx, gy, 9) if _liquid != null else -1
	var lid10: int = _liquid.material_id(_world, gx, gy, 10) if _liquid != null else -1
	var lpos := PackedVector3Array()
	var luv := PackedVector2Array()
	var lcol := PackedColorArray()
	var lidx := PackedInt32Array()
	var lpos2 := PackedVector3Array()
	var luv2 := PackedVector2Array()
	var lcol2 := PackedColorArray()
	var lidx2 := PackedInt32Array()
	# Reflection pass (row 1012): retail draws a grey mirrored ambient quad
	# FIRST, then the bed over it. For the port's flat water surface the mirror
	# is geometrically a no-op (the iso diamond is symmetric under a vertical
	# flip), so the reflection reuses the bed geometry with a grey tint and a
	# fixed factor-8 depth fade, emitted into its own surface drawn behind.
	var rpos := PackedVector3Array()
	var ruv := PackedVector2Array()
	var rcol := PackedColorArray()
	var ridx := PackedInt32Array()
	var rpos2 := PackedVector3Array()
	var ruv2 := PackedVector2Array()
	var rcol2 := PackedColorArray()
	var ridx2 := PackedInt32Array()

	for i in Sacred.SECT * Sacred.SECT:
		if not await _build_checkpoint(job):
			return null
		var cell := i * Sacred.CELL
		var x := float(gx * SECT + i % SECT)
		var y := float(gy * SECT + i / SECT)
		var px := (x - y) * HW
		var py := -(x + y) * HH
		# Cell coordinates name the north corner. Retail's tile centre is
		# half a cell farther south; do not move objects or the camera.
		py -= HH
		var pz := (x + y) * DEPTH_STEP
		# The cell's own terrain tile, then the OVERLAY tiles world/floor.pak
		# hangs off WldxEntry +0x0c (row 695): the handle heads a chain whose
		# records carry a tiles.pak index in the low 17 bits of +0x04 and link
		# on at +0x0c (0 or self+1). ~17% of world cells carry one. They are
		# ordinary tiles -- same diamond, same 18-slot atlas, same corner
		# heights and lights -- drawn a hair nearer the camera so the depth
		# buffer puts them over the ground.
		#
		# Each entry is a PAIR (art, mask). A mask of 0 draws like any other
		# tile, on the alpha-tested surface. A non-zero mask goes to the second
		# surface, where the art supplies the colour and the mask supplies the
		# alpha -- retail's exact combine (row 703).
		# LIQUID, before the tile stack: it is per CELL, not per tile, and it does
		# not replace the ground. WldxEntry +0x1f's high nibble marks it -- 9 and
		# 10, the same two values Walkable.is_liquid blocks movement on, read
		# from the same byte on purpose so the two never drift apart.
		var nib := cells[cell + 0x1f] >> 4
		if (nib == 9 or nib == 10) and _liquid != null:
			# The second set only exists when the sector's two ids actually
			# differ; a nibble-10 cell in a one-liquid sector joins the first.
			var second: bool = nib == 10 and lid10 != lid9
			var lz := pz + LIQUID_Z
			var lv := lpos2.size() if second else lpos.size()
			# FLAT, no _h: on liquid cells the corner bytes hold DEPTH (open
			# sea -20, shallows rising to 0), which shapes the BED below --
			# the water surface itself sits at the water table. Feeding the
			# depth into the vertex heights sank the surface into its own bed.
			var quad_liquid := PackedVector3Array([
				Vector3(px, py + HH, lz),    # N
				Vector3(px + HW, py, lz),    # E
				Vector3(px, py - HH, lz),    # S
				Vector3(px - HW, py, lz)])   # W
			# Screen-space UV, so one image spans a fixed 128 px however big
			# the cell is and neighbouring cells continue the same wave
			# instead of restarting it. The corners are lattice points shared
			# with the neighbours, so the seam is exact.
			var uv_liquid := PackedVector2Array()
			for q: Vector3 in [
					Vector3(px, py + HH, 0.0), Vector3(px + HW, py, 0.0),
					Vector3(px, py - HH, 0.0), Vector3(px - HW, py, 0.0)]:
				uv_liquid.append(Vector2(q.x, -q.y) / LiquidScript.TEX_PX)
			# RGB is the cell's per-corner light, as everywhere. ALPHA is
			# retail's depth fade (row 1011): the material's +0xD0 multiplier
			# times the SIGNED corner depth byte, clamped to 0..255 -- a
			# negative multiplier over negative depth reads opaque on the open
			# sea and thins to nothing at the shoreline.
			var id := lid10 if second else lid9
			# RGB is the cell's per-corner light, as everywhere. ALPHA is
			# retail's depth fade (row 1011): the material's +0xD0 multiplier
			# times the SIGNED corner depth byte, clamped to 0..255 -- a
			# negative multiplier over negative depth reads opaque on the open
			# sea and thins to nothing at the shoreline.
			var lmult: int = LiquidScript.ALPHA_MULT[id]
			var refl: bool = LiquidScript.REFLECTIVE[id]   # retail's pass-1 mirrored ambient quad (row 1012)
			var col_liquid := PackedColorArray()
			var col_refl := PackedColorArray()
			for c in [1, 2, 3, 0]:
				var ls := cells.decode_u8(cell + 0x14 + c) / 255.0
				var d8 := cells.decode_u8(cell + 0x10 + c)
				var depth := d8 - 256 if d8 > 127 else d8
				var la := clampi(lmult * depth, 0, 255) / 255.0
				col_liquid.append(Color(ls, ls, ls, la))
				# Reflection: grey tint, fixed factor-8 depth fade (row 1012),
				# independent of the record's alpha multiplier.
				if refl:
					var ra := clampi(-8 * depth, 0, 255) / 255.0
					col_refl.append(Color(ls, ls, ls, ra))
			var idx_liquid := PackedInt32Array([lv, lv + 1, lv + 2, lv, lv + 2, lv + 3])
			if refl:
				var rlv := rpos2.size() if second else rpos.size()
				var idx_refl := PackedInt32Array([rlv, rlv + 1, rlv + 2, rlv, rlv + 2, rlv + 3])
				if second:
					rpos2.append_array(quad_liquid)
					ruv2.append_array(uv_liquid)
					rcol2.append_array(col_refl)
					ridx2.append_array(idx_refl)
				else:
					rpos.append_array(quad_liquid)
					ruv.append_array(uv_liquid)
					rcol.append_array(col_refl)
					ridx.append_array(idx_refl)
			if second:
				lpos2.append_array(quad_liquid)
				luv2.append_array(uv_liquid)
				lcol2.append_array(col_liquid)
				lidx2.append_array(idx_liquid)
			else:
				lpos.append_array(quad_liquid)
				luv.append_array(uv_liquid)
				lcol.append_array(col_liquid)
				lidx.append_array(idx_liquid)
		var stack := _tile_stack(cells, cell)
		for si in stack.size() / 2:
			if not await _build_checkpoint(job):
				return null
			var tile_id := stack[si * 2]
			var mask_id := stack[si * 2 + 1]
			var qz := pz + si * OVERLAY_Z
			var texid := _tiles.texture_id(tile_id)
			if not layer_of.has(texid):
				var img := _image(texid)
				if img == null:
					continue
				layer_of[texid] = images.size()
				images.append(img)
			# The mask is an ordinary tile too, so it wants a layer in the same
			# array. If its texture will not decode, fall back to drawing the
			# art alone rather than dropping the quad entirely.
			var mask_layer := -1.0
			var mask_uv := PackedVector2Array()
			if mask_id != 0:
				var mtex := _tiles.texture_id(mask_id)
				if not layer_of.has(mtex):
					var mimg := _image(mtex)
					if mimg != null:
						layer_of[mtex] = images.size()
						images.append(mimg)
				if layer_of.has(mtex):
					mask_layer = float(layer_of[mtex])
					mask_uv = Sacred.slot_uv(_tiles.orientation(mask_id))
			var l := float(layer_of[texid])
			var v := pos.size() if mask_layer < 0.0 else bpos.size()
			# The logical corners share height/light samples with neighbours.
			# Retail expands the rendered tips by 0.2 pixels to cover seams
			# (48.2 x 24.2 half-extents in both LGP and Win 2.28).
			#
			# Corner order in the file is W, N, E, S. Solved, not guessed: require
			# the three cells around every shared vertex to agree, and exactly one
			# of the 24 permutations scores 1.000. Across 550 sectors and 6.5 M
			# shared-vertex tests, +0x10 and +0x18 mismatch 0 times and +0x14
			# mismatches 117 (0.0018%).
			#
			# +0x10..0x13 are SIGNED heights (82% zero, always multiples of 5). In a
			# 2.5D iso engine height raises the tile on SCREEN, so it goes into
			# vertex Y -- putting it in Z would fight the depth ordering that lets
			# separate sector meshes coexist.
			var quad := PackedVector3Array([
				Vector3(px, py + HH + 0.2 + _h(cells, cell, 1), qz),    # N
				Vector3(px + HW + 0.2, py + _h(cells, cell, 2), qz),    # E
				Vector3(px, py - HH - 0.2 + _h(cells, cell, 3), qz),    # S
				Vector3(px - HW - 0.2, py + _h(cells, cell, 0), qz)])   # W
			# Four asymmetric retail UV tips, shared by the art and mask.
			var quad_uv := Sacred.slot_uv(_tiles.orientation(tile_id))
			# +0x14..0x17 are four per-corner light bytes (never zero; 255/235/215/195,
			# a clean step of -20), in the same W,N,E,S order.
			var quad_col := PackedColorArray()
			for c in [1, 2, 3, 0]:
				var s := cells.decode_u8(cell + 0x14 + c) / 255.0
				quad_col.append(Color(s, s, s))
			var quad_l := PackedVector2Array([
				Vector2(l, 0), Vector2(l, 0), Vector2(l, 0), Vector2(l, 0)])
			var quad_idx := PackedInt32Array([v, v + 1, v + 2, v, v + 2, v + 3])
			if mask_layer < 0.0:
				pos.append_array(quad)
				uv.append_array(quad_uv)
				col.append_array(quad_col)
				uv2.append_array(quad_l)
				idx.append_array(quad_idx)
				floor_metadata.append(int(x))
				floor_metadata.append(int(y))
				floor_metadata.append(si)
			else:
				bpos.append_array(quad)
				buv.append_array(quad_uv)
				bcol.append_array(quad_col)
				buv2.append_array(quad_l)
				bidx.append_array(quad_idx)
				masked_metadata.append(int(x))
				masked_metadata.append(int(y))
				masked_metadata.append(si)
				for muv: Vector2 in mask_uv:
					bcus.append_array([muv.x, muv.y, mask_layer, 0.0])

	if images.is_empty():
		return null

	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = pos
	arr[Mesh.ARRAY_TEX_UV] = uv
	arr[Mesh.ARRAY_TEX_UV2] = uv2
	arr[Mesh.ARRAY_COLOR] = col
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()

	if not await _build_checkpoint(job):
		return null
	var tex := Texture2DArray.new()
	tex.create_from_images(images)
	if not await _build_checkpoint(job):
		return null

	var mi := MeshInstance3D.new()
	job["node"] = mi
	mi.name = "Sector%d_%d" % [gx, gy]
	mi.mesh = mesh
	var barr: Array = []
	if not bidx.is_empty():
		barr.resize(Mesh.ARRAY_MAX)
		barr[Mesh.ARRAY_VERTEX] = bpos
		barr[Mesh.ARRAY_TEX_UV] = buv
		barr[Mesh.ARRAY_TEX_UV2] = buv2
		barr[Mesh.ARRAY_COLOR] = bcol
		barr[Mesh.ARRAY_CUSTOM0] = bcus
		barr[Mesh.ARRAY_INDEX] = bidx
	job["terrain"] = {"texture": tex, "arrays": arr, "masked": barr,
		"metadata": floor_metadata, "masked_metadata": masked_metadata}
	if not ridx.is_empty() or not ridx2.is_empty():
		var rquads := 0
		var rlids := PackedInt32Array()
		for set in ([[lid9, rpos, ruv, rcol, ridx], [lid10, rpos2, ruv2, rcol2, ridx2]]):
			if not await _build_checkpoint(job):
				return null
			if (set[4] as PackedInt32Array).is_empty():
				continue
			var rmat: ShaderMaterial = await _liquid.material_for_reflection(
				set[0], _build_checkpoint.bind(job))
			if not await _build_checkpoint(job):
				return null
			# Same decode-failure guard as the bed: a reflection with no
			# material must not paint untextured white over the sea.
			if rmat == null:
				continue
			var rarr := []
			rarr.resize(Mesh.ARRAY_MAX)
			rarr[Mesh.ARRAY_VERTEX] = set[1]
			rarr[Mesh.ARRAY_TEX_UV] = set[2]
			rarr[Mesh.ARRAY_COLOR] = set[3]
			rarr[Mesh.ARRAY_INDEX] = set[4]
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, rarr)
			# render_priority -1 (set on the material) draws this BEFORE the
			# bed surface, matching retail's pass-1-then-bed choreography.
			mi.set_surface_override_material(mesh.get_surface_count() - 1, rmat)
			rquads += (set[4] as PackedInt32Array).size() / 6
			rlids.append(set[0])
		if rquads > 0:
			mi.set_meta("liquid_reflection_quads", rquads)
			mi.set_meta("liquid_reflection_materials", rlids)
	
	if not lidx.is_empty() or not lidx2.is_empty():
		var lquads := 0
		var lids := PackedInt32Array()
		for set in ([[lid9, lpos, luv, lcol, lidx], [lid10, lpos2, luv2, lcol2, lidx2]]):
			if not await _build_checkpoint(job):
				return null
			if (set[4] as PackedInt32Array).is_empty():
				continue
			var lmat: ShaderMaterial = await _liquid.material_for(
				set[0], _build_checkpoint.bind(job))
			if not await _build_checkpoint(job):
				return null
			# Only when the frames actually decoded. A liquid surface with no
			# material would draw untextured white over the sea, which is a
			# worse picture than the bed tile this is here to cover.
			if lmat == null:
				continue
			var larr := []
			larr.resize(Mesh.ARRAY_MAX)
			larr[Mesh.ARRAY_VERTEX] = set[1]
			larr[Mesh.ARRAY_TEX_UV] = set[2]
			larr[Mesh.ARRAY_COLOR] = set[3]
			larr[Mesh.ARRAY_INDEX] = set[4]
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, larr)
			mi.set_surface_override_material(mesh.get_surface_count() - 1, lmat)
			lquads += (set[4] as PackedInt32Array).size() / 6
			lids.append(set[0])
		if lquads > 0:
			mi.set_meta("liquid_quads", lquads)
			mi.set_meta("liquid_materials", lids)
	mi.set_meta("quads", (idx.size() + bidx.size()) / 6)
	mi.set_meta("layers", images.size())
	if _objects:
		var m := await _build_objects(cells, gx, gy, job)
		if m != null:
			mi.add_child(m)
		if job["cancelled"]:
			return null
	if _show_regions and not regions.list.is_empty():
		var r := await _build_regions(regions, job)
		if r != null:
			mi.add_child(r)
	if _show_flags1e:
		var f := await _build_flags1e(cells, gx, gy, job)
		if f != null:
			mi.add_child(f)
	if _show_classhi:
		var ch := await _build_classhi(cells, gx, gy, job)
		if ch != null:
			mi.add_child(ch)
	if not _spawns.is_empty():
		var sp := await _build_spawns(gx, gy, job)
		if sp != null:
			mi.add_child(sp)
	if not await _build_checkpoint(job):
		return null
	return mi


## Draws every placed static object as its real sprite.
##
## Regular art is tiled MIX geometry; static flags 0x20 instead select a direct
## texture atlas miniature (including animated, origin-rotated quads). Both
## paths share texture-array layers and the global encoded-space painter.
##
## --markers falls back to flat coloured squares, which is still the cheapest
## way to see placement when a sprite fails to load.

## One static chain walked into the draw lists. Extracted from
## _build_objects so a base cell can contribute BOTH its own chain and the
## state-selected storey child's grid chain (F1, findings row 1328).
func _build_chain(head: int, cell_x: int, cell_y: int, parent: Dictionary,
		job: Dictionary, objs: Array[Dictionary], shadows: Array[Dictionary]) -> void:
	for o: Dictionary in _statics.chain(head):
		if not await _build_checkpoint(job):
			return
		if _items == null or not _items.has_definition(o["type"]):
			continue
		# Main-art exclusions, LGP 0x080E0E96 / Win 0x0062AE90.
		if (o["flags"] & 0x290) != 0:
			continue
		if _only_flag >= 0 and o["flags"] != _only_flag:
			continue
		if not _only_sids.is_empty() and not _only_sids.has(o["type"]):
			continue
		if _hide_levels != 0 and _items != null \
				and (_items.levels(o["type"]) & _hide_levels) != 0:
			continue
		# --exterior: drop each building family's TOP level, which is its
		# interior. Generalises --hidelevel, which needs the index known per
		# building -- 110 of 192 families top out at level 1 and 54 at level 2,
		# so no single index works everywhere.
		if _exterior and _items != null and _items.is_top_level(o["type"]):
			continue
		# Retail visits diagonals (x+y ascending, x ascending), appending
		# each cell's static chain unchanged to its selected draw list.
		# Sprite bounds are not a depth key: a candle on a cabinet shares
		# the cabinet's owning cell but has a different screen-space foot.
		# LGP sub_80E0E96 routes definitions with bit 4 to lists 0/2,
		# bit 0x800000 to list 4, and ordinary sprites to list 3.
		var flags: int = _items.draw_flags(o["type"]) if _items != null else 0
		var gated: bool = (flags & 0x800004) != 0 or (o["flags"] & 8) != 0
		o["trigger"] = parent["trigger"] if gated and not parent.is_empty() else -1
		var draw_pass := 3
		if (flags & 4) != 0:
			draw_pass = 0 if o["mask"] == 1 or (o["flags"] & 0x20) != 0 else 2
		elif (flags & 0x800000) != 0:
			draw_pass = 4
		o["draw_pass"] = draw_pass
		o["cell_order"] = (cell_x + cell_y) * 6400 + cell_x
		o["chain_order"] = objs.size()
		o["base_pos"] = IsoCamera.cell_to_world(Vector2(cell_x, cell_y))
		o["shadow"] = {}
		if not _markers and (o["flags"] & 0x800) == 0:
			var definition := _items.static_shadow_of(o["type"])
			if not definition.is_empty():
				if o["mask"] == 1:
					var shadow := _static_shadow_geometry(o["pos"], definition)
					shadow["order"] = Vector3i(1, o["cell_order"], o["chain_order"])
					shadows.append(shadow)
				elif o["mask"] > 1 and (flags & 0x800004) == 0 \
						and (o["flags"] & 0x28) == 8:
					o["shadow"] = _static_shadow_geometry(o["pos"], definition)

		objs.append(o)


func _build_objects(cells: PackedByteArray, gx: int, gy: int, job: Dictionary) -> Node3D:
	if _statics == null or _mixed == null or _interior == null:
		return null
	var layer_of: Dictionary[int, int] = {}   ## texture.pak id -> layer in this sector's array
	var images: Array[Image] = []
	var marks := PackedVector3Array()
	var mark_col := PackedColorArray()
	var mark_idx := PackedInt32Array()

	# Geometry stays in authored order. FloorView merges object spans across
	# sectors by native pass, owning-cell diagonal, and static-chain order.
	var trace_env := OS.get_environment("OBJ_TRACE").split(",")
	if trace_env.size() == 2:
		_obj_trace = Vector2i(int(trace_env[0]), int(trace_env[1]))
	var only_env := OS.get_environment("OBJ_ONLY_SIDS")
	if only_env != "" and _only_sids.is_empty():
		for s in only_env.split(","):
			_only_sids[int(s)] = true
	var objs: Array[Dictionary] = []
	var shadows: Array[Dictionary] = []
	# A cell names the HEAD of a chain of statics, not a single one -- walk it,
	# or every stacked placement stays invisible (2026-08-13: 158 of them in
	# sector 50,39 alone, including seven KLOSTER_KAPELLE01 level-2 wall pieces,
	# the candle cabinet, ten candles and the library shelves).
	for i in Sacred.SECT * Sacred.SECT:
		if not await _build_checkpoint(job):
			return null
		var head := cells.decode_u32(i * Sacred.CELL + 4)
		var cell_x := gx * SECT + i % SECT
		var cell_y := gy * SECT + i / SECT
		var parent: Dictionary = {}
		if (cells[i * Sacred.CELL + 30] & 1) != 0:
			parent = _interior.parent_for_cell(Vector2i(cell_x, cell_y))
		if head == 0:
			continue
		await _build_chain(head, cell_x, cell_y, parent, job, objs, shadows)

	objs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["draw_pass"] != b["draw_pass"]:
			return a["draw_pass"] < b["draw_pass"]
		if a["cell_order"] != b["cell_order"]:
			return a["cell_order"] < b["cell_order"]
		return a["chain_order"] < b["chain_order"])

	var n: int = objs.size()
	# Keep these buffers uniquely owned until finished. Fetch/append/store
	# through run per tile would copy every accumulated packed array.
	var bp := PackedVector3Array()
	var bu := PackedVector2Array()
	var bu2 := PackedVector2Array()
	var ba := PackedColorArray()
	var bidx := PackedInt32Array()
	var run: Dictionary = {
		"spans": [], "trigger_ids": {}, "shadows": shadows, "materials": {},
	}
	var source_objects := 0
	for i in n:
		if not await _build_checkpoint(job):
			return null
		var obj: Dictionary = objs[i]
		var raw_pos: Vector2 = obj["pos"]
		var p: Vector2 = raw_pos
		var visibility_class := "GATED" if obj["trigger"] >= 0 else "SHARED"
		var trigger_id: int = obj["trigger"]
		source_objects += 1
		var index_start := bidx.size()
		# static.pak +0x04 is an items.pak RECORD index; the mixed.pak sprite id
		# is that record's +0x10 field (Sacred.Items.sprite_of). Passing the
		# type straight to Mixed.sprite() only worked for the records whose two
		# numbers coincide, and drew nothing for the shared furniture library.
		var spr: Dictionary = {}
		if not _markers and _items != null:
			spr = _miniature_sprite(obj) if (obj["flags"] & 0x20) != 0 \
				else _mixed.sprite(_items.sprite_of(obj["type"]))
		if spr.is_empty():
			if _markers:
				var c := Color.from_hsv(fmod(obj["type"] * 0.137, 1.0), 0.9, 1.0)
				var mv := marks.size()
				var mz := (-p.y / HH) * DEPTH_STEP + 2.0
				marks.append_array([Vector3(p.x - 10, p.y + 10, mz), Vector3(p.x + 10, p.y + 10, mz),
					Vector3(p.x + 10, p.y - 10, mz), Vector3(p.x - 10, p.y - 10, mz)])
				mark_col.append_array([c, c, c, c])
				mark_idx.append_array([mv, mv + 1, mv + 2, mv, mv + 2, mv + 3])
			continue
		var quads_before := bp.size()
		var size := Vector2(spr["size"])
		# THE PLACEMENT IS THE TILE ORIGIN. The tiles' dst rects are already
		# in the sprite's own pixel frame, so they go down at p and nowhere
		# else; retail adds nothing to them.
		#
		# This read `p + (anchor.x, -anchor.y)` and that was the single
		# largest error left in the frame -- 23.97% -> 14.24% whole-frame
		# delta against retail's spawn capture when it came out (row 1017).
		# mixed.pak's header dx/dy is not a hotspot to apply: measured across
		# the corpus it is exactly the NEGATION of the tiles' own minimum dst
		# corner -- Bench 2 anchor (0,-7) with dst starting at y 7, Bench 1
		# (0,-36) starting at 36, MINI_BLUE_4 (-4,0) starting at x 4, and
		# (0,0) on every sprite whose tiles already start at the corner. So
		# applying it CANCELS the offset the dst rects carry, re-seating each
		# sprite on its bounding box instead of on its authored frame. Every
		# chapel structure has a zero anchor, which is why the walls and the
		# floor lined up perfectly while the benches sat 7 pixels high and the
		# small props drifted a few pixels each -- the error was invisible
		# exactly where it was zero.
		#
		# What dx/dy IS for is unrecovered; it is not needed to place a sprite.
		var origin := p
		var pz := ((-p.y + size.y) / HH) * DEPTH_STEP + 2.0
		var animation: Color = spr.get("animation", Color(0, 0, 0, 0))
		# Visibility is an exact trigger/mask index admission, not a binary
		# shader bucket. UV2.y is unused; UV2.x remains the atlas layer.
		for tile: Dictionary in spr["tiles"]:
			if not await _build_checkpoint(job):
				return null
			var tid: int = tile["tex"]
			if not layer_of.has(tid):
				var img := _image(tid)
				if img == null:
					continue
				layer_of[tid] = images.size()
				images.append(img)
			var l := float(layer_of[tid])
			var d := Rect2(tile["dst"])
			var s: Rect2 = tile["src"]
			var x0 := origin.x + d.position.x
			var y0 := origin.y - d.position.y
			var x1 := x0 + d.size.x
			var y1 := y0 - d.size.y
			var v: int = bp.size()
			if tile.has("corners"):
				# Miniature rotation is about the placement origin, not its centre.
				for corner: Vector2 in tile["corners"]:
					bp.append(Vector3(origin.x + corner.x, origin.y - corner.y, pz))
			else:
				bp.append_array([Vector3(x0, y0, pz), Vector3(x1, y0, pz), Vector3(x1, y1, pz), Vector3(x0, y1, pz)])
			bu.append_array([s.position, Vector2(s.end.x, s.position.y), s.end, Vector2(s.position.x, s.end.y)])
			bu2.append_array([Vector2(l, -1), Vector2(l, -1),
				Vector2(l, -1), Vector2(l, -1)])
			ba.append_array([animation, animation, animation, animation])
			bidx.append_array([v, v + 1, v + 2, v, v + 2, v + 3])
		var index_end := bidx.size()
		if index_end > index_start:
			run["spans"].append({"start": index_start, "end": index_end,
				"trigger": trigger_id, "mask": obj["mask"], "static": obj["id"],
				"order": Vector3i(obj["draw_pass"], obj["cell_order"], obj["chain_order"]),
				"shadow": obj["shadow"]})
			if trigger_id >= 0:
				run["trigger_ids"][trigger_id] = true
		if _obj_trace == Vector2i(gx, gy):
			print("objtrace\ti=%d\tsid=%d\tname=%s\tcell=%s\tclass=%s\ttrigger=%d\tmask=%d\ttiles=%d\tquads=%d\tpos=%.1f,%.1f\tsize=%s" % [
				i, obj["type"], _items.name_of(obj["type"]) if _items != null else "",
				Sacred.Footprints._object_cell(raw_pos), visibility_class, trigger_id,
				obj["mask"], spr["tiles"].size(),
				(bp.size() - quads_before) / 4, raw_pos.x, raw_pos.y, size])

	var root: Node3D
	if not await _build_checkpoint(job):
		return null
	var tex: Texture2DArray
	if not images.is_empty():
		tex = Texture2DArray.new()
		tex.create_from_images(images)
		if not await _build_checkpoint(job):
			return null
	run["texture"] = tex
	run["pos"] = bp
	run["uv"] = bu
	run["uv2"] = bu2
	run["animation"] = ba
	run["idx"] = bidx
	job["objects"] = run
	if not mark_idx.is_empty():
		root = Node3D.new()
		root.name = "Objects"
		var mm := StandardMaterial3D.new()
		mm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mm.vertex_color_use_as_albedo = true
		root.add_child(_mesh_of(marks, PackedVector2Array(), mark_idx, mark_col, mm))
	if _stats:
		print("object-canvas\tsector=%d,%d\tsource=%d\tspans=%d\tshadows=%d" % [gx, gy, source_objects, run["spans"].size(), shadows.size()])
	return root


## Native item +91/+93/+95/+99/+100: one skewed or rectangular atlas quad.
## Coordinates are retail screen units; camera projection supplies zoom/panning.
func _static_shadow_geometry(position: Vector2, definition: Dictionary) -> Dictionary:
	var offset: Vector2 = definition["offset"]
	var radius: float = definition["radius"]
	var left := offset.x if definition["skew"] else offset.x - radius
	var right := offset.x + 2.0 * radius if definition["skew"] else offset.x + radius
	var points := PackedVector3Array([
		Vector3(position.x + left, position.y - offset.y + radius, 0),
		Vector3(position.x + right, position.y - offset.y + radius, 0),
		Vector3(position.x + offset.x - radius, position.y - offset.y, 0),
		Vector3(position.x + offset.x + radius, position.y - offset.y, 0)])
	var tile: int = definition["tile"]
	var uv := Vector2(tile % 16, tile / 16) * 0.0625
	return {"points": points, "uv": PackedVector2Array([
		uv, uv + Vector2(0.0625, 0), uv + Vector2(0, 0.0625), uv + Vector2(0.0625, 0.0625)])}


## Native miniature path: LGP 00012:2442-2514; Win 2.28 00017:8503-8590.
## Atlas dimensions are explicitly 256 in both binaries, not inferred from MIX.
## COLOR carries four normalized animation bytes. Dynamic lighting is not
## implemented for either object path:
## retail uses sub_83ACF42 only when its night/interior lighting gate is enabled,
## and item flag 0x20000 also registers a light and draws a separate glow then.
func _miniature_sprite(obj: Dictionary) -> Dictionary:
	var texture_id: int = _items.miniature_texture_of(obj["type"])
	if texture_id <= 0:
		return {}
	var params: PackedByteArray = obj["miniature"]
	var animated: bool = (obj["flags"] & 0x40) != 0
	var size: Vector2
	var source: Rect2
	var animation := Color(0, 0, 0, 0)
	var angle := 0.0
	if animated:
		if params[0] == 0 or params[1] == 0 or params[3] == 0:
			push_error("Invalid miniature atlas/timing divisor for item %d" % obj["type"])
			return {}
		size = Vector2(256.0 / params[0], 256.0 / params[1])
		source = Rect2(Vector2.ZERO, size / 256.0)
		angle = float(params[2]) * TAU / 256.0
		animation = Color(params[0] / 255.0, params[1] / 255.0,
			params[3] / 255.0, params[4] / 255.0)
	else:
		size = Vector2(params[2], params[2])
		source = Rect2(Vector2(params[0], params[1]) / 256.0, size / 256.0)
	var tile := {"tex": texture_id, "src": source, "dst": Rect2(Vector2.ZERO, size)}
	if angle != 0.0:
		var corners := PackedVector2Array([
			Vector2.ZERO, Vector2(size.x, 0), size, Vector2(0, size.y)])
		# Native screen Y points down: (x*cos+y*sin, y*cos-x*sin).
		for i in corners.size():
			corners[i] = corners[i].rotated(-angle)
		tile["corners"] = corners
	return {"size": size, "tiles": [tile], "animation": animation}






## Update only runs containing the changed trigger, across every resident sector.
## Vertices/UVs/animation and original index order survive every state change.
func _on_trigger_state_changed(trigger_id: int, _previous: int, _state: int) -> void:
	_admission_revision += 1
	for run: Dictionary in _object_data.values():
		if run["trigger_ids"].has(trigger_id):
			_apply_run_admission(run)
	for actor: Dictionary in _scene_actors.values():
		_apply_actor_admission(actor)


func _apply_run_admission(run: Dictionary) -> void:
	var changed := false
	for span: Dictionary in run["spans"]:
		var trigger_id: int = span["trigger"]
		var admitted: bool = trigger_id < 0 or span["mask"] == _interior.state(trigger_id)
		if not span.has("admitted") or span["admitted"] != admitted:
			span["admitted"] = admitted
			changed = true
	if changed:
		_floor_view.invalidate_objects()



## --spawns: tints the whole sector by what its script spawn rolls would put
## here -- green wildlife only, amber a hostile roll with nothing in it the hero
## fights, red a hostile roll the hero fights. Untinted means the sector rolls
## nothing at all, which is what a town sector like the Silver Creek chapel
## (50,39) looks like.
##
## The tiers arrive precomputed from main.gd; this only paints them, so the
## view still opens no files of its own. Cell-by-cell rather than one big
## diamond because the sector's iso outline is staggered and the existing
## overlays already lay quads out this way -- one copied loop beats a second
## piece of projection maths.
func _build_spawns(gx: int, gy: int, job: Dictionary) -> Node3D:
	const TIER_COLOUR := {
		1: Color(0.2, 0.9, 0.2, 0.30),
		2: Color(1.0, 0.7, 0.1, 0.34),
		3: Color(1.0, 0.15, 0.1, 0.38),
	}
	var tier: int = _spawns.get(Vector2i(gx, gy), 0)
	if tier == 0:
		return null
	var c: Color = TIER_COLOUR[tier]
	var pos := PackedVector3Array()
	var col := PackedColorArray()
	var idx := PackedInt32Array()
	for i in Sacred.SECT * Sacred.SECT:
		if not await _build_checkpoint(job):
			return null
		var x := float(gx * SECT + i % SECT)
		var y := float(gy * SECT + i / SECT)
		var px := (x - y) * HW
		var py := -(x + y) * HH
		var pz := (x + y) * DEPTH_STEP + 8.0
		var v := pos.size()
		pos.append_array([Vector3(px, py + HH, pz), Vector3(px + HW, py, pz),
			Vector3(px, py - HH, pz), Vector3(px - HW, py, pz)])
		col.append_array([c, c, c, c])
		idx.append_array([v, v + 1, v + 2, v, v + 2, v + 3])
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var root := Node3D.new()
	root.name = "Spawns"
	root.add_child(_mesh_of(pos, PackedVector2Array(), idx, col, mat))
	return root


## --classhi: paints the +0x1f HIGH nibble, one hue per value. sacred.gd calls
## it "an undecoded family split (0xd/0xe)", but all 16 values occur, the low
## nibble is essentially only {0,1,2} = OPEN/WALL/FLOOR, and the ground
## texture predicts the high nibble only 0.647 of the time -- correlated, not
## determined. Drawing it is the same move that settled +0x1e.
func _build_classhi(cells: PackedByteArray, gx: int, gy: int, job: Dictionary) -> Node3D:
	var pos := PackedVector3Array()
	var col := PackedColorArray()
	var idx := PackedInt32Array()
	for i in Sacred.SECT * Sacred.SECT:
		if not await _build_checkpoint(job):
			return null
		var h := cells.decode_u8(i * Sacred.CELL + 0x1f) >> 4
		var c := Color.from_hsv(float(h) / 16.0, 0.9, 1.0, 0.65)
		var x := float(gx * SECT + i % SECT)
		var y := float(gy * SECT + i / SECT)
		var px := (x - y) * HW
		var py := -(x + y) * HH
		var pz := (x + y) * DEPTH_STEP + 8.0
		var v := pos.size()
		pos.append_array([Vector3(px, py + HH, pz), Vector3(px + HW, py, pz),
			Vector3(px, py - HH, pz), Vector3(px - HW, py, pz)])
		col.append_array([c, c, c, c])
		idx.append_array([v, v + 1, v + 2, v, v + 2, v + 3])
	if idx.is_empty():
		return null
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var root := Node3D.new()
	root.name = "ClassHi"
	root.add_child(_mesh_of(pos, PackedVector2Array(), idx, col, mat))
	return root


## --flags1e: paints WldxEntry +0x1e, the sparse per-cell flag byte, one colour
## per bit so overlaps stay readable. Debug only, and the whole reason it exists
## is bit 1: it is set on 219,744 cells in only 161 of the 6050 sectors, in
## near-solid blobs, and no reader for it has been found in the binary (row
## 708). Height and light were each settled by drawing them and looking, so
## this is that same move.
##
##   bit 0 (0x01) RED    -- cell belongs to a parent object (traced, row 707)
##   bit 1 (0x02) GREEN  -- UNKNOWN, the one to look at
##   bit 2 (0x04) BLUE   -- cell's static handle is special (solved, row 708)
##
## Bits 3..7 are never set anywhere in the world, so they are not drawn.
func _build_flags1e(cells: PackedByteArray, gx: int, gy: int, job: Dictionary) -> Node3D:
	const COLOURS := {
		0x01: Color(1.0, 0.15, 0.15, 0.60),
		0x02: Color(0.15, 1.0, 0.15, 0.60),
		0x04: Color(0.3, 0.4, 1.0, 0.75),
	}
	var pos := PackedVector3Array()
	var col := PackedColorArray()
	var idx := PackedInt32Array()
	for i in Sacred.SECT * Sacred.SECT:
		if not await _build_checkpoint(job):
			return null
		var v := cells.decode_u8(i * Sacred.CELL + 0x1e)
		if v == 0:
			continue
		for bit: int in COLOURS:
			if v & bit == 0:
				continue
			var c: Color = COLOURS[bit]
			var x := float(gx * SECT + i % SECT)
			var y := float(gy * SECT + i / SECT)
			var px := (x - y) * HW
			var py := -(x + y) * HH
			# Above the objects, like _build_regions, and one step per bit so
			# two bits on one cell do not z-fight into a single flat colour.
			var pz := (x + y) * DEPTH_STEP + 8.0 + float(bit) * 0.01
			var vtx := pos.size()
			pos.append_array([Vector3(px, py + HH, pz), Vector3(px + HW, py, pz),
				Vector3(px, py - HH, pz), Vector3(px - HW, py, pz)])
			col.append_array([c, c, c, c])
			idx.append_array([vtx, vtx + 1, vtx + 2, vtx, vtx + 2, vtx + 3])
	if idx.is_empty():
		return null
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var root := Node3D.new()
	root.name = "Flags1e"
	root.add_child(_mesh_of(pos, PackedVector2Array(), idx, col, mat))
	return root


func _build_regions(regions: Sacred.Regions, job: Dictionary) -> Node3D:
	const COLOURS := {
		Sacred.Regions.WALL: Color(1.0, 0.2, 0.2, 0.55),
		Sacred.Regions.FLOOR: Color(0.2, 0.6, 1.0, 0.35),
		Sacred.Regions.DOOR: Color(1.0, 1.0, 0.0, 0.95),
		Sacred.Regions.STEP: Color(0.1, 1.0, 0.3, 0.75),
	}
	var pos := PackedVector3Array()
	var col := PackedColorArray()
	var idx := PackedInt32Array()
	for r: Dictionary in regions.list:
		var origin: Vector2i = r["cell"]
		var size: Vector2i = r["size"]
		for cy in size.y:
			for cx in size.x:
				if not await _build_checkpoint(job):
					return null
				var k := Sacred.Regions.cell_class(r, cx, cy)
				if not COLOURS.has(k):
					continue
				var c: Color = COLOURS[k]
				var x := float(origin.x + cx)
				var y := float(origin.y + cy)
				var px := (x - y) * HW
				var py := -(x + y) * HH
				# Above the objects (which sit at +2.0) so the overlay is visible.
				var pz := (x + y) * DEPTH_STEP + 8.0
				var v := pos.size()
				pos.append_array([Vector3(px, py + HH, pz), Vector3(px + HW, py, pz),
					Vector3(px, py - HH, pz), Vector3(px - HW, py, pz)])
				col.append_array([c, c, c, c])
				idx.append_array([v, v + 1, v + 2, v, v + 2, v + 3])
	if idx.is_empty():
		return null
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var root := Node3D.new()
	root.name = "Regions"
	root.add_child(_mesh_of(pos, PackedVector2Array(), idx, col, mat))
	return root




## Same absolute iso-depth scale as the marker formula at _build_objects'
## sprite-less path (`mz`) -- deliberately NOT the taller sprite `pz` formula,
## so a band's representative depth depends only on the object's own ground
## position, not on which object happened to be first in the band.
##
## Public and static (Plan 04-03 Task 1): the shared depth formula anything
## sorted against the painted object quads must reuse verbatim -- a rename,
## not a reformulation, the arithmetic is unchanged from `_band_depth`.
static func ground_depth(p: Vector2) -> float:
	return (-p.y / HH) * DEPTH_STEP + 2.0


## Character-proxy marker cube for --sortcube=CX,CY (Phase 2 Plan 03): one
## transparent-pass instance standing in for a skinned character (Phase 3+
## builds the real thing), which is likewise one instance carrying one sort
## key. Two constraints are load-bearing, both from the class doc invariant at
## 15-17 ("Sits at Transform3D.IDENTITY... every sector mesh keeps the exact
## global transform"):
##   1. Every coordinate lives in the geometry below, never in the returned
##      node's position/transform/global_position -- the caller must leave it
##      at IDENTITY, matching every band mesh, or its base sort key would come
##      from a different origin than theirs.
##   2. It renders in the transparent pass, like the object sprites it is
##      being sorted against -- an opaque instance would be ordered by the
##      depth buffer instead, answering a different question than this phase
##      asks.
func _build_sortcube() -> MeshInstance3D:
	var px := (float(_sortcube.x) - float(_sortcube.y)) * HW
	var py := -(float(_sortcube.x) + float(_sortcube.y)) * HH
	# Same absolute iso-depth scale and sign the object bands use (ground_depth
	# is the identical formula _build_objects' sprite-less marker path and
	# every band's representative depth already share).
	var pz := ground_depth(Vector2(px, py))
	var half := SORTCUBE_PX * 0.5
	# A small Z extent (not a zero-thickness plane) so this is a real six-face
	# box, ground point at (px, py), top edge SORTCUBE_PX above it (screen Y is
	# up).
	var z0 := pz - DEPTH_STEP
	var z1 := pz + DEPTH_STEP
	var pos := PackedVector3Array([
		Vector3(px - half, py, z0), Vector3(px + half, py, z0),
		Vector3(px + half, py + SORTCUBE_PX, z0), Vector3(px - half, py + SORTCUBE_PX, z0),
		Vector3(px - half, py, z1), Vector3(px + half, py, z1),
		Vector3(px + half, py + SORTCUBE_PX, z1), Vector3(px - half, py + SORTCUBE_PX, z1),
	])
	var idx := PackedInt32Array([
		0, 1, 2, 0, 2, 3,   # near (z0)
		4, 5, 6, 4, 6, 7,   # far (z1)
		0, 4, 7, 0, 7, 3,   # left
		1, 5, 6, 1, 6, 2,   # right
		0, 1, 5, 0, 5, 4,   # bottom
		3, 2, 6, 3, 6, 7,   # top
	])
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
	mat.albedo_color = Color(1.0, 0.0, 1.0, 0.9)
	# cull_disabled: the box's exact winding is not load-bearing (unlike the
	# object/terrain shaders' own cull_disabled choice, this mirrors that
	# convention) -- every face must stay visible regardless of which side the
	# orthogonal camera ends up on.
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var mi := _mesh_of(pos, PackedVector2Array(), idx, PackedColorArray(), mat)
	mi.sorting_use_aabb_center = false
	mi.sorting_offset = pz
	return mi


func _mesh_of(pos: PackedVector3Array, uv: PackedVector2Array, idx: PackedInt32Array,
		col: PackedColorArray, mat: Material,
		uv2: PackedVector2Array = PackedVector2Array()) -> MeshInstance3D:
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = pos
	if not uv.is_empty():
		arr[Mesh.ARRAY_TEX_UV] = uv
	if not uv2.is_empty():
		arr[Mesh.ARRAY_TEX_UV2] = uv2
	if not col.is_empty():
		arr[Mesh.ARRAY_COLOR] = col
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	return mi


## Object sprites come in every size, so unlike terrain they cannot share a
## Texture2DArray -- one ImageTexture each, cached alongside the terrain images.

## The tiles drawn on one cell, ground first: its terrain tile id (+0x00),
## then the world/floor.pak overlay chain hanging off +0x0c (row 695). The
## chain record is 16 bytes -- own index, payload, zero, next -- and the tile
## id is the payload's LOW 17 BITS, and the top 15 are a SECOND tile id (row
## 701) -- so each entry is a PAIR, returned interleaved as (art, mask, art,
## mask, ...). A zero mask means the tile draws alone. The ground tile always
## comes first and never carries a mask.
func _tile_stack(cells: PackedByteArray, cell: int) -> PackedInt32Array:
	var out := PackedInt32Array([cells.decode_u32(cell), 0])
	if _floor == null:
		return out
	var h := cells.decode_u32(cell + 0x0c)
	while h != 0 and out.size() <= OVERLAY_MAX * 2:
		var r := _floor.blob(h)
		if r.size() < 16:
			break
		var payload := r.decode_u32(4)
		out.append(payload & 0x1ffff)
		out.append(payload >> 17)
		var nxt := r.decode_u32(0x0c)
		# 0 or self+1 is the whole observed shape; anything else is a bad read,
		# and following it would walk the 6.7 M-record table forever.
		h = nxt if nxt == h + 1 else 0
	return out


## Signed per-corner height byte, scaled to screen units.
func _h(cells: PackedByteArray, cell: int, corner: int) -> float:
	var b := cells.decode_u8(cell + 0x10 + corner)
	return float(b - 256 if b > 127 else b) * height_scale


func _image(texid: int) -> Image:
	if _images.has(texid):
		return _images[texid]
	if texid >= _tex_pak.count():
		return null
	var img := Sacred.decode_texture(_tex_pak, texid, true)
	if img == null or img.get_width() != Sacred.TILE or img.get_height() != Sacred.TILE:
		return null
	_evict(_images)
	_images[texid] = img
	return img


## Drop the oldest IMAGE_CACHE_EVICT entries once over the cap. Dictionary
## preserves insertion order in Godot, so the first keys are the oldest.
func _evict(cache: Dictionary) -> void:
	if cache.size() < IMAGE_CACHE_MAX:
		return
	var keys := cache.keys()
	for i in mini(IMAGE_CACHE_EVICT, keys.size()):
		cache.erase(keys[i])


## Fixed-block callers await this method. It pumps the same scheduler as
## streaming and never substitutes a synchronous construction path.
func load_region(cx: int, cy: int, r: int) -> void:
	if not is_inside_tree():
		push_error("SectorView.load_region requires an owner attached to SceneTree")
		return
	_region_revision += 1
	var revision := _region_revision
	_region_loading = true
	_streaming = false
	_cancel_build()
	_pending.clear()
	_wanted.clear()
	for gy in range(cy - r, cy + r + 1):
		for gx in range(cx - r, cx + r + 1):
			var key := gy * 100 + gx
			_wanted[key] = true
			if not _loaded.has(key):
				_pending.append(key)
	for key: int in _loaded.keys():
		if not _wanted.has(key):
			var node: Node = _loaded[key]
			if node != null:
				node.queue_free()
			_loaded.erase(key)
			_object_data.erase(key)
			_floor_view.remove_sector(key)
	if _cam != null:
		var span := float(r * 2 + 1) * SECT
		_cam.size = span * 2.0 * HH * 1.1
		_cam.look_at_cell(Vector2(cx * SECT + SECT * 0.5, cy * SECT + SECT * 0.5))
	while not _pending.is_empty() or not _build_job.is_empty():
		if revision != _region_revision or not is_inside_tree():
			return
		stream(0.0)
		await get_tree().process_frame
	if revision != _region_revision or not is_inside_tree():
		return
	var quads := 0
	var texids: Dictionary[int, bool] = {}
	for key: int in _wanted:
		var node: MeshInstance3D = _loaded[key]
		if node == null:
			continue
		quads += int(node.get_meta("quads"))
		for tid in _world.tile_ids(key % 100, key / 100):
			while Time.get_ticks_usec() >= _slice_deadline:
				await get_tree().process_frame
				if revision != _region_revision or not is_inside_tree():
					return
				stream(0.0)
			texids[_tiles.texture_id(tid)] = true
	if _cam != null:
		_floor_view.sync()
		while pending_scripted_objects > 0 or not _floor_view.is_settled():
			await get_tree().process_frame
			if revision != _region_revision or not is_inside_tree():
				return
			_floor_view.sync()
	_region_loading = false
	print("%d quads, %d textures" % [quads, texids.size()])


## Both sector payloads and the displayed canvas must cover the current view.
func is_settled() -> bool:
	if _region_loading or pending_scripted_objects > 0 \
			or not _pending.is_empty() or not _build_job.is_empty():
		return false
	if _cam != null and not _floor_view.is_settled():
		return false
	if not _streaming:
		return true
	var want := _wanted_sectors()
	if want.size() != _loaded.size():
		return false
	for key in want:
		if not _loaded.has(key):
			return false
	return true
