class_name SectorView
extends Node3D
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

## --bands= upper clamp. 4096 is one band per sector cell (SECT*SECT / SECT =
## SECT bands would already over-separate; this is a hard ceiling regardless
## of SECT), the point past which more bands cannot separate more objects.
## Also removes the divide-by-zero a --bands=0 would otherwise cause in
## _band_of before main.gd's own clamp turns 0 into 1 (T-02-01).
const BAND_MAX := 4096

## ground_depth is only NON-decreasing across bands (proven empirically at
## --bands=100000: two adjacent bands whose first object shares an exact
## pos.y tie -- common in a grid-aligned world -- get an identical
## sorting_offset, and unlike triangles inside one mesh, whose submission
## order alone decided this before banding, Godot's transparent sort has no
## other tiebreaker between distinct MeshInstance3D nodes; the visible result
## was thin sliver mis-ordering along a handful of overlapping sprite edges).
## sorting_offset is a rendering-server real_t (32-bit float internally, even
## though GDScript's own float is 64-bit); at this scale's worst-case
## magnitude (640, per DEPTH_STEP's own comment above) float32's ULP is
## ~7.6e-5, so a naively "far below any real depth step" epsilon like 1e-6
## rounds away to nothing when added -- measured directly: it left the
## --bands=100000 mis-order artifact almost unchanged. 0.001 clears that ULP
## floor by >10x while staying under DEPTH_STEP / HH (~0.0021 per world unit
## of pos.y), the smallest step a genuinely distinct object can produce.
const BAND_TIE_EPS := 0.001

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

const TERRAIN_SHADER: Shader = preload("res://shaders/terrain.gdshader")
const TERRAIN_MASK_SHADER: Shader = preload("res://shaders/terrain_mask.gdshader")
const OBJECT_SHADER: Shader = preload("res://shaders/object.gdshader")

## MUST EQUAL the array length in `shaders/object.gdshader`'s
## `uniform int hidden_buckets[...]`. GLSL cannot read a GDScript const, so the
## two agree by convention and this is the only place the number is explained.
## Changing one without the other makes the shader read past its own array.
const HIDDEN_BUCKET_SLOTS := 64

@export var load_margin := 64.0                    ## cells loaded beyond the viewport
@export var loads_per_frame := 1
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
## Typed collections (Godot 4.4+): the key/value contracts here are the whole
## reason the streamer is readable, so they are worth stating.
var _loaded: Dictionary[int, MeshInstance3D] = {}  ## sector key -> mesh, null if it draws nothing
var _images: Dictionary[int, Image] = {}           ## texture.pak id -> decoded tile
var _statics: Sacred.Statics
var _mixed: Sacred.Mixed
var _items: Sacred.Items                  ## names, for the interior/exterior swap
var _footprints: Sacred.Footprints
## Per-sector cache of footprints.resolve() results, keyed gy*100+gx.
## _footprint_membership calls resolve() per object; without this cache it
## re-inflates and re-parses the owning sector's decompressed stream for every
## static -- measured 2026-08-13 as ~1 s per sector build (the startup
## regression: hundreds of statics x a 3x3-neighbour scan = thousands of
## zlib inflations per sector).
var _footprint_cache: Dictionary = {}
var _bucket_ids: Dictionary[int, int] = {}  ## region_key -> dense shader bucket id (row 663)
var _force_interior := false              ## --force-interior: capture-only all interior families
var _show_regions := false                ## --regions: overlay building footprints
var _show_flags1e := false                ## --flags1e: overlay WldxEntry +0x1e bits (row 708)
var _spawns: Dictionary = {}              ## --spawns: sector -> tier, see main.gd
var _show_classhi := false                ## --classhi: overlay the +0x1f HIGH nibble
var _hide_levels := 0                     ## --hidelevel=N: bitmask of levels to drop
var _exterior := false                    ## --exterior: drop each building's top level
var _pending: Array[int] = []             ## sectors queued for a later frame
var _last_view := Vector3(NAN, NAN, NAN)  ## camera x/y/zoom the wanted-set was derived from
var _in_sync := false                     ## true once _loaded provably covers the wanted set (stream() sets/clears)
var _streaming := true
var _stats := false
var _objects := true                      ## draw static object sprites
var _markers := false                     ## ...as flat coloured squares instead
var _only_flag := -1                      ## debug: draw only objects with this +0x08 flag
## OBJ_TRACE=gx,gy: log every submitted object of that sector (id, class,
## bucket, quads emitted, anchor pos = the painter sort key, sprite size).
## Diagnostic only, off unless set.
var _obj_trace := Vector2i(-1, -1)
## OBJ_ONLY_SIDS=a,b,c: draw only these static types. Diagnostic only.
var _only_sids: Dictionary[int, bool] = {}
var _band_count := 1                      ## --bands=N: object depth bands per sector
var _sortcube := Vector2i(-1, -1)         ## --sortcube=CX,CY: character-proxy marker cube cell, (-1,-1) = off
var sector_build_calls: int = 0
var object_mesh_creations: int = 0
var object_material_creations: int = 0
var object_texture_decodes: int = 0
var _run_nodes: Dictionary = {}
var _run_probe: Dictionary = {}
var _last_swap_states: Dictionary = {}
var _has_applied_swap := false

## Sector unload/(re)load counters. Not gated on anything view-side (a view has
## no notion of "probe") -- counted unconditionally, cheaply, on every event.
## main.gd's _actor_probe resets both to 0 immediately before its route walk
## and reads them back for the probe-diag line, so only that window's events
## are ever observed; this is exactly equivalent to the pre-extraction code's
## `if _probe_active:` guard, which also only mattered across that same
## reset-to-read window.
var probe_unloaded := 0
var probe_reloaded := 0


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
##   band_count: int    -- --bands=N object depth bands per sector (default 1)
##   sortcube: Vector2i -- --sortcube=CX,CY character-proxy marker cube cell,
##                         or Vector2i(-1,-1) for "off" (default Vector2i(-1,-1))
func setup(cam: IsoCamera, tex_pak: Sacred.Pak, tiles: Sacred.Tiles, world: Sacred.World,
		statics: Sacred.Statics, mixed: Sacred.Mixed, items: Sacred.Items, opts: Dictionary,
		footprints: Sacred.Footprints = null) -> void:
	_cam = cam
	_tex_pak = tex_pak
	_liquid = LiquidScript.new(tex_pak)
	_tiles = tiles
	_world = world
	_statics = statics
	_mixed = mixed
	_items = items
	_footprints = footprints
	_stats = opts.get("stats", false)
	_markers = opts.get("markers", false)
	_objects = opts.get("objects", true)
	_force_interior = opts.get("force_interior", false)
	_show_regions = opts.get("regions", false)
	_show_flags1e = opts.get("flags1e", false)
	_show_classhi = opts.get("classhi", false)
	_spawns = opts.get("spawns", {})
	_exterior = opts.get("exterior", false)
	_hide_levels = opts.get("hide_levels", 0)
	_only_flag = opts.get("only_flag", -1)
	# maxi(1, ...) so a caller that reaches setup() from outside main.gd's own
	# clamp (e.g. a future test harness) can never hand _band_of a divisor of 0.
	_band_count = maxi(1, opts.get("band_count", 1))
	_sortcube = opts.get("sortcube", Vector2i(-1, -1))
	_floor = opts.get("floor_pak", null)
	# Added once, here, as a direct child of self -- never a child of a sector
	# node, which stream()/_add_sector() frees on unload (T-02-05). A direct
	# child persists across every sector load/unload the streamer performs.
	if _sortcube.x >= 0:
		var _sortcube_mesh := _build_sortcube()
		add_child(_sortcube_mesh)


## The streaming body, moved out of main.gd's _process verbatim (its early
## returns are now local to it) so main.gd._process can also drive the sim
## accumulator on frames the streamer itself has nothing to do on.
func stream(_delta: float) -> void:
	if not _streaming or _cam == null:
		return
	# The visible set only changes when the camera does. Re-deriving it every
	# frame allocated a Dictionary and walked the sector grid for nothing, so
	# a settled view is skipped -- but "settled" must mean the wanted set is
	# actually loaded, not merely that the camera stopped moving: after a
	# camera jump the OLD cell's backlog drains one sector per frame below,
	# and the frame that empties it would otherwise early-return forever with
	# the new cell's sectors never queued (TSV rows 614/617: want=25,
	# loaded=14, pending=0 at shot time -- a permanent void frame).
	var view := Vector3(_cam.position.x, _cam.position.y, _cam.size)
	if view != _last_view:
		_last_view = view
		_in_sync = false

	if not _pending.is_empty():
		_add_sector(_pending.pop_front())
		return
	if _in_sync:
		return

	var want := _wanted_sectors()
	for key: int in _loaded.keys():
		if not want.has(key):
			var node: Node = _loaded[key]
			if node != null:
				node.queue_free()
			_run_nodes.erase(key)
			_run_probe.erase(key)
			_loaded.erase(key)
			probe_unloaded += 1

	var missing: Array[int] = []
	for key: int in want:
		if not _loaded.has(key):
			missing.append(key)
	if missing.is_empty():
		_in_sync = true
		return

	# Nearest first, then drained one per frame from _pending so a big camera
	# jump costs many short frames instead of one very long one.
	var here := _cam.world_to_cell(Vector2(_cam.position.x, _cam.position.y)) / SECT
	missing.sort_custom(func(a: int, b: int) -> bool:
		return _sector_dist(a, here) < _sector_dist(b, here))
	for i in mini(loads_per_frame, missing.size()):
		_add_sector(missing[i])
	for i in range(loads_per_frame, missing.size()):
		_pending.push_back(missing[i])


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
	var t0 := Time.get_ticks_usec()
	var node := _build_sector(key % 100, key / 100)
	if _stats:
		print("sector\t%d,%d\t%d quads\t%d tex\t%.1f ms\tcache=%d" % [
			key % 100, key / 100,
			0 if node == null else int(node.get_meta("quads")),
			0 if node == null else int(node.get_meta("layers")),
			(Time.get_ticks_usec() - t0) / 1000.0, _images.size()])
	# A sector that builds to nothing is still recorded, as a null, so the
	# streamer stops retrying it every frame. Storing null rather than an empty
	# placeholder Node3D keeps the scene tree free of nodes that draw nothing.
	_loaded[key] = node
	if node != null:
		add_child(node)
		# A newly streamed sector has fresh run nodes even when the simulation
		# state is unchanged. Re-apply the existing visibility state once so
		# capture-only modes classify late-built sectors without rebuilding them.
		_has_applied_swap = false
	probe_reloaded += 1


## One sector -> one MeshInstance3D with its own Texture2DArray. Returns null if
## the sector holds no drawable tile.
func _build_sector(gx: int, gy: int) -> MeshInstance3D:
	sector_build_calls += 1
	var cells := _world.entries(gx, gy)
	if cells.is_empty():
		return null
	# Built unconditionally: the cutaway needs them, not just the debug overlay.
	var regions := Sacred.Regions.new(_world.sector(gx, gy), gx, gy)

	var layer_of: Dictionary[int, int] = {}   ## texture.pak id -> layer in this sector's array
	var images: Array[Image] = []
	var pos := PackedVector3Array()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var col := PackedColorArray()
	var idx := PackedInt32Array()
	# Second surface: the floor.pak quads that carry a MASK tile (row 703).
	# Retail draws these in a separate pass with the second texture unit on,
	# so they get their own surface and their own material here rather than
	# turning the whole terrain transparent. bcus carries the mask's UV and
	# array layer, which is what CUSTOM0 exists for -- UV2 is already spent on
	# the art tile's layer.
	var bpos := PackedVector3Array()
	var buv := PackedVector2Array()
	var buv2 := PackedVector2Array()
	var bcol := PackedColorArray()
	var bcus := PackedFloat32Array()
	var bidx := PackedInt32Array()
	# Third surface: the animated liquid pass (row 1008). Retail draws liquid
	# over the ordinary ground rather than instead of it, so the bed tile stays
	# in the first surface and this rides just above it -- which is also why the
	# open sea looked like flat grey-tan ground before this existed, its bed
	# being one repeated ISO00 tile across all 4096 cells.
	var lpos := PackedVector3Array()
	var luv := PackedVector2Array()
	var lcol := PackedColorArray()
	var lidx := PackedInt32Array()
	var lid := -1

	for i in Sacred.SECT * Sacred.SECT:
		var cell := i * Sacred.CELL
		var x := float(gx * SECT + i % SECT)
		var y := float(gy * SECT + i / SECT)
		var px := (x - y) * HW
		var py := -(x + y) * HH
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
			var mid: int = _liquid.material_id(gx, gy, nib)
			# One material per sector mesh. The two nibbles select two DIFFERENT
			# per-sector ids in retail, so a sector could in principle need two
			# surfaces; every id resolves the same today, and splitting on a
			# distinction that carries no data yet would be geometry written for
			# a case that cannot occur. Take the first and note a real conflict.
			if lid < 0:
				lid = mid
			if mid == lid:
				var lz := pz + LIQUID_Z
				var lv := lpos.size()
				lpos.append_array(PackedVector3Array([
					Vector3(px, py + HH + _h(cells, cell, 1), lz),    # N
					Vector3(px + HW, py + _h(cells, cell, 2), lz),    # E
					Vector3(px, py - HH + _h(cells, cell, 3), lz),    # S
					Vector3(px - HW, py + _h(cells, cell, 0), lz)]))  # W
				# Screen-space UV, so one image spans a fixed 128 px however big
				# the cell is and neighbouring cells continue the same wave
				# instead of restarting it. The corners are lattice points shared
				# with the neighbours, so the seam is exact.
				for q: Vector3 in [
						Vector3(px, py + HH, 0.0), Vector3(px + HW, py, 0.0),
						Vector3(px, py - HH, 0.0), Vector3(px - HW, py, 0.0)]:
					luv.append(Vector2(q.x, -q.y) / LiquidScript.TEX_PX)
				for c in [1, 2, 3, 0]:
					var ls := cells.decode_u8(cell + 0x14 + c) / 255.0
					lcol.append(Color(ls, ls, ls))
				lidx.append_array(PackedInt32Array([lv, lv + 1, lv + 2, lv, lv + 2, lv + 3]))
		var stack := _tile_stack(cells, cell)
		for si in stack.size() / 2:
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
			var mask_uv := Rect2()
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
			# A tile is a DIAMOND, not a rectangle. Its four corners are lattice
			# points shared with the neighbouring cells -- four cells meet at each
			# one -- and that sharing is what lets the per-corner height field join
			# up instead of tearing the terrain apart.
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
				Vector3(px, py + HH + _h(cells, cell, 1), qz),    # N
				Vector3(px + HW, py + _h(cells, cell, 2), qz),    # E
				Vector3(px, py - HH + _h(cells, cell, 3), qz),    # S
				Vector3(px - HW, py + _h(cells, cell, 0), qz)])   # W
			# The texture is an 18-slot diamond atlas; the tile's orientation field
			# picks the slot. Sampling the whole image (as the pre-2.4 viewer did)
			# squeezes all 18 diamonds into every cell, which is what produced the
			# regular dotted pattern.
			# The texture is an 18-slot diamond atlas; the tile's orientation field
			# picks the slot. The diamond's corners sit at the slot rect's EDGE
			# MIDPOINTS, so the transparent rect corners are never sampled at all.
			var r := Sacred.slot_uv(_tiles.orientation(tile_id))
			var mid := r.position + r.size * 0.5
			var quad_uv := PackedVector2Array([
				Vector2(mid.x, r.position.y), Vector2(r.end.x, mid.y),
				Vector2(mid.x, r.end.y), Vector2(r.position.x, mid.y)])
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
			else:
				bpos.append_array(quad)
				buv.append_array(quad_uv)
				bcol.append_array(quad_col)
				buv2.append_array(quad_l)
				bidx.append_array(quad_idx)
				# The mask is the SAME diamond in its own atlas slot, so its
				# corners are that slot's edge midpoints, exactly like the art.
				var mmid := mask_uv.position + mask_uv.size * 0.5
				for muv: Vector2 in [
						Vector2(mmid.x, mask_uv.position.y), Vector2(mask_uv.end.x, mmid.y),
						Vector2(mmid.x, mask_uv.end.y), Vector2(mask_uv.position.x, mmid.y)]:
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
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)

	var tex := Texture2DArray.new()
	tex.create_from_images(images)
	var mat := ShaderMaterial.new()
	mat.shader = TERRAIN_SHADER
	mat.set_shader_parameter(&"tex", tex)

	var mi := MeshInstance3D.new()
	mi.name = "Sector%d_%d" % [gx, gy]
	mi.mesh = mesh
	# Per-surface, NOT material_override: the masked surface needs a different
	# material and an override would apply this one to both. Nothing else reads
	# the terrain mesh's material -- the swap code at _apply_swap walks the
	# object band meshes, which are children with their own overrides.
	mi.set_surface_override_material(0, mat)
	if not bidx.is_empty():
		var barr := []
		barr.resize(Mesh.ARRAY_MAX)
		barr[Mesh.ARRAY_VERTEX] = bpos
		barr[Mesh.ARRAY_TEX_UV] = buv
		barr[Mesh.ARRAY_TEX_UV2] = buv2
		barr[Mesh.ARRAY_COLOR] = bcol
		barr[Mesh.ARRAY_CUSTOM0] = bcus
		barr[Mesh.ARRAY_INDEX] = bidx
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, barr, [], {},
			Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
		var bmat := ShaderMaterial.new()
		bmat.shader = TERRAIN_MASK_SHADER
		bmat.set_shader_parameter(&"tex", tex)
		# These are blended, so they join the same transparent queue the object
		# sprites sort in (they carry sorting_offset; see _build_objects). The
		# floor must precede every sprite, exactly as retail's floor pass does,
		# and render_priority is sorted before depth -- without this the
		# overlays paint OVER the props standing on them and wash them out.
		bmat.render_priority = -1
		mi.set_surface_override_material(1, bmat)
	if not lidx.is_empty():
		var lmat: ShaderMaterial = _liquid.material_for(lid)
		# Only when the frames actually decoded. A liquid surface with no
		# material would draw untextured white over the sea, which is a worse
		# picture than the bed tile this is here to cover.
		if lmat != null:
			var larr := []
			larr.resize(Mesh.ARRAY_MAX)
			larr[Mesh.ARRAY_VERTEX] = lpos
			larr[Mesh.ARRAY_TEX_UV] = luv
			larr[Mesh.ARRAY_COLOR] = lcol
			larr[Mesh.ARRAY_INDEX] = lidx
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, larr)
			mi.set_surface_override_material(mesh.get_surface_count() - 1, lmat)
			mi.set_meta("liquid_quads", lidx.size() / 6)
			mi.set_meta("liquid_material", lid)
	mi.set_meta("quads", (idx.size() + bidx.size()) / 6)
	mi.set_meta("layers", images.size())
	if _objects:
		var m := _build_objects(cells, regions, gx, gy, _footprints)
		if m != null:
			mi.add_child(m)
	if _show_regions and not regions.list.is_empty():
		var r := _build_regions(regions)
		if r != null:
			mi.add_child(r)
	if _show_flags1e:
		var f := _build_flags1e(cells, gx, gy)
		if f != null:
			mi.add_child(f)
	if _show_classhi:
		var ch := _build_classhi(cells, gx, gy)
		if ch != null:
			mi.add_child(ch)
	if not _spawns.is_empty():
		var sp := _build_spawns(gx, gy)
		if sp != null:
			mi.add_child(sp)
	return mi


## Draws every placed static object as its real sprite.
##
## Each object's art is a set of TILES (mixed.pak), so this emits one quad per
## tile, batched by texture -- median 10 distinct object textures per sector, so
## ~10 extra draw calls. Sprites are unrotated screen-space billboards: this is
## a 2D game drawn in a 3D engine, and the only 3D thing about an object is the
## Z it sorts on.
##
## --markers falls back to flat coloured squares, which is still the cheapest
## way to see placement when a sprite fails to load.
func _build_objects(cells: PackedByteArray, regions: Sacred.Regions, gx: int, gy: int,
		footprints: Sacred.Footprints = null) -> Node3D:
	if _statics == null or _mixed == null:
		return null
	var layer_of: Dictionary[int, int] = {}   ## texture.pak id -> layer in this sector's array
	var images: Array[Image] = []
	var marks := PackedVector3Array()
	var mark_col := PackedColorArray()
	var mark_idx := PackedInt32Array()

	# Painter order matters and the depth buffer cannot supply it: these are
	# blended sprites, so object.gdshader does not write depth (a sprite's
	# transparent halo would otherwise punch a hole in everything behind it).
	# Order therefore comes entirely from SUBMISSION order, and within a single
	# surface that is index order.
	#
	# Which is why everything here goes into ONE mesh with ONE Texture2DArray.
	# The old code batched by texture into ~10 sibling MeshInstance3Ds, and
	# Godot sorts transparent instances by AABB centroid distance -- one key per
	# mesh, for a mesh spanning the whole sector. So the carefully computed
	# per-vertex Z was never consulted between batches, and a building whose
	# roof and floor came from different texture pages drew in whichever order
	# the two centroids happened to fall. That is the "dark voids" artifact:
	# not voids at all, but a building's own floor and terrace painted over the
	# roof they belong behind. Every mixed.pak texture is 256x256 (verified:
	# 209956/209956 tile references), so they array with no padding.
	var trace_env := OS.get_environment("OBJ_TRACE").split(",")
	if trace_env.size() == 2:
		_obj_trace = Vector2i(int(trace_env[0]), int(trace_env[1]))
	var only_env := OS.get_environment("OBJ_ONLY_SIDS")
	if only_env != "" and _only_sids.is_empty():
		for s in only_env.split(","):
			_only_sids[int(s)] = true
	var objs: Array[Dictionary] = []
	# A cell names the HEAD of a chain of statics, not a single one -- walk it,
	# or every stacked placement stays invisible (2026-08-13: 158 of them in
	# sector 50,39 alone, including seven KLOSTER_KAPELLE01 level-2 wall pieces,
	# the candle cabinet, ten candles and the library shelves).
	for i in Sacred.SECT * Sacred.SECT:
		for o: Dictionary in _statics.chain(cells.decode_u32(i * Sacred.CELL + 4)):
			if _only_flag >= 0 and o["flags"] != _only_flag:
				continue
			if not _only_sids.is_empty() and not _only_sids.has(o["type"]):
				continue
			# The cutaway, OPT-IN via --cutaway because it is not verified.
			#
			# Retail never shows a building's inside and its roof at once (captured
			# 2026-08-07 by driving the game through a door), and the obvious rule
			# from the region decode is that an object standing on a FLOOR cell is
			# interior furnishing while one on a WALL cell is structure. Measured
			# world-wide across the 361 sectors that have regions: of 45188 art
			# objects, 13137 fall inside a footprint but only 1509 stand on a floor
			# cell and 4307 on a wall cell. 1509 is far too few to be "all interior
			# furnishing", and enabling it changes nothing on the sector 64,39 test
			# building, whose roofs are the actual open artifact. So this stays off
			# by default rather than silently hiding 1509 objects on a rule that has
			# never been shown correct.
			# LEVEL TEST. Building art is named <BUILDING>_<level>_<part>; if the
			# engine shows one level at a time, hiding a level should reproduce the
			# retail cutaway. Prediction logged before measuring (results row 321):
			# hiding level 2 does it, and _0U1_ pieces survive because they are
			# marked as belonging to two levels.
			if _hide_levels != 0 and _items != null \
					and (_items.levels(o["type"]) & _hide_levels) != 0:
				continue
			# --exterior: drop each building family's TOP level, which is its
			# interior. Generalises --hidelevel, which needs the index known per
			# building -- 110 of 192 families top out at level 1 and 54 at level 2,
			# so no single index works everywhere.
			if _exterior and _items != null and _items.is_top_level(o["type"]):
				continue
			objs.append(o)
	objs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var pa: Vector2 = a["pos"]
		var pb: Vector2 = b["pos"]
		# pos.y is Godot-up, so DESCENDING y is north-to-south = back-to-front.
		return pa.y > pb.y if not is_equal_approx(pa.y, pb.y) else pa.x < pb.x)

	var n: int = objs.size()
	var band_repr: Array[float] = []
	var band_has_repr: Array[bool] = []
	for _b in _band_count:
		band_repr.append(0.0)
		band_has_repr.append(false)
	for i in n:
		var band := _band_of(i, n, _band_count)
		if not band_has_repr[band]:
			band_repr[band] = ground_depth(objs[i]["pos"])
			band_has_repr[band] = true
	for b in range(1, _band_count):
		if band_repr[b] <= band_repr[b - 1]:
			band_repr[b] = band_repr[b - 1] + BAND_TIE_EPS

	var runs: Array[Dictionary] = []
	var run: Dictionary = {}
	var source_objects: int = 0
	# ONE run per band, holding every object in that band's CONTIGUOUS sorted
	# range -- the painter-correct structure the Phase-2 research mandates
	# ("banding must split by contiguous index ranges of the already-sorted
	# objs array"). The swap is NOT a mesh split: each vertex carries a bucket
	# id (UV2.y) and object.gdshader discards hidden buckets. This restores the
	# pre-split painter order (one mesh per band, submission order = index
	# order) while keeping the swap instant -- no per-run sorting_offset
	# ambiguity between adjacent tents (2026-08-13: the region-key run split
	# gave interleaved runs near-identical sorting_offsets, so Godot's
	# transparent sort mixed the arena camp's OZELT1/2/3 tents -- "building on
	# building", "pieces from other locations").
	for i in n:
		var obj: Dictionary = objs[i]
		var raw_pos: Vector2 = obj["pos"]
		var p: Vector2 = raw_pos
		var band := _band_of(i, n, _band_count)
		var classification := _classify_object(obj, raw_pos, gx, gy, regions, footprints)
		var family: String = classification["family"]
		var visibility_class: String = classification["class"]
		var region_key: int = classification.get("region_key", -1)
		if run.is_empty() or band != run["band"]:
			if not run.is_empty():
				runs.append(run)
			run = {
				"source_start": i, "source_end": i, "class": visibility_class,
				"family": family, "region_key": region_key, "band": band, "material_key": "object-array",
				"depth_key": band_repr[band], "pos": PackedVector3Array(),
				"uv": PackedVector2Array(), "uv2": PackedVector2Array(),
				"idx": PackedInt32Array(), "source_ordinals": PackedInt32Array(),
			}
		else:
			run["source_end"] = i
		run["source_ordinals"].append(i)
		source_objects += 1
		# static.pak +0x04 is an items.pak RECORD index; the mixed.pak sprite id
		# is that record's +0x10 field (Sacred.Items.sprite_of). Passing the
		# type straight to Mixed.sprite() only worked for the records whose two
		# numbers coincide, and drew nothing for the shared furniture library.
		var spr := _mixed.sprite(_items.sprite_of(obj["type"])) \
			if not _markers and _items != null else {}
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
			continue
		var quads_before: int = run["pos"].size()
		var size: Vector2i = spr["size"]
		var anchor: Vector2i = spr["anchor"]
		var origin := Vector2(p.x + anchor.x, p.y - anchor.y)
		var pz := ((-p.y + size.y) / HH) * DEPTH_STEP + 2.0
		# The swap bucket id: (region_key, class). region_key >= 0 identifies
		# the building; the class bit (0 = exterior/roof, 1 = interior) picks
		# which set of that building the swap hides. SHARED buckets (no region,
		# id -1) are never hidden. The shader compares this against the hidden
		# list set by apply_swap.
		var bucket := -1
		if region_key >= 0:
			bucket = _dense_bucket_id(region_key) * 2 + (1 if visibility_class == "INTERIOR" else 0)
		for tile: Dictionary in spr["tiles"]:
			var tid: int = tile["tex"]
			if not layer_of.has(tid):
				# BEFORE the call, not after: _image() INSERTS into _images and
				# then returns, so `not _images.has(tid)` asked afterwards is
				# always false and the counter could never leave 0. It read as
				# a perfect cache in every swap-apply line, which is exactly
				# what a dead instrument looks like from the outside.
				var was_cached := _images.has(tid)
				var img := _image(tid)
				if img == null:
					continue
				if not was_cached:
					object_texture_decodes += 1
				layer_of[tid] = images.size()
				images.append(img)
			var l := float(layer_of[tid])
			var d: Rect2i = tile["dst"]
			var s: Rect2 = tile["src"]
			var x0 := origin.x + d.position.x
			var y0 := origin.y - d.position.y
			var x1 := x0 + d.size.x
			var y1 := y0 - d.size.y
			var bp: PackedVector3Array = run["pos"]
			var v: int = bp.size()
			bp.append_array([Vector3(x0, y0, pz), Vector3(x1, y0, pz), Vector3(x1, y1, pz), Vector3(x0, y1, pz)])
			run["pos"] = bp
			var bu: PackedVector2Array = run["uv"]
			bu.append_array([s.position, Vector2(s.end.x, s.position.y), s.end, Vector2(s.position.x, s.end.y)])
			run["uv"] = bu
			var bu2: PackedVector2Array = run["uv2"]
			bu2.append_array([Vector2(l, float(bucket)), Vector2(l, float(bucket)),
				Vector2(l, float(bucket)), Vector2(l, float(bucket))])
			run["uv2"] = bu2
			var bidx: PackedInt32Array = run["idx"]
			bidx.append_array([v, v + 1, v + 2, v, v + 2, v + 3])
			run["idx"] = bidx
		if _obj_trace == Vector2i(gx, gy):
			print("objtrace\ti=%d\tsid=%d\tname=%s\tcell=%s\tclass=%s\trk=%d\tbucket=%d\ttiles=%d\tquads=%d\tpos=%.1f,%.1f\tsize=%s" % [
				i, obj["type"], _items.name_of(obj["type"]) if _items != null else "",
				Sacred.Footprints._object_cell(raw_pos), visibility_class, region_key,
				bucket, spr["tiles"].size(),
				(run["pos"].size() - quads_before) / 4, raw_pos.x, raw_pos.y, size])
	if not run.is_empty():
		runs.append(run)

	var root := Node3D.new()
	root.name = "Objects"
	var sector_key := gy * 100 + gx
	var sector_nodes: Array[Dictionary] = []
	if not images.is_empty():
		var tex := Texture2DArray.new()
		tex.create_from_images(images)
		var mat := ShaderMaterial.new()
		mat.shader = OBJECT_SHADER
		mat.set_shader_parameter(&"tex", tex)
		object_material_creations += 1
		for run_meta: Dictionary in runs:
			var run_idx: PackedInt32Array = run_meta["idx"]
			if run_idx.is_empty():
				continue
			var run_mesh := _mesh_of(run_meta["pos"], run_meta["uv"], run_idx,
				PackedColorArray(), mat, run_meta["uv2"])
			object_mesh_creations += 1
			run_mesh.sorting_use_aabb_center = false
			run_mesh.sorting_offset = run_meta["depth_key"]
			run_mesh.name = "Run_%d_%d_%s" % [run_meta["source_start"], run_meta["source_end"], run_meta["class"]]
			run_mesh.set_meta("source_start", run_meta["source_start"])
			run_mesh.set_meta("source_end", run_meta["source_end"])
			root.add_child(run_mesh)
			run_meta["node"] = run_mesh
			sector_nodes.append(run_meta)
		_run_nodes[sector_key] = sector_nodes
		_run_probe[sector_key] = sector_nodes.duplicate(true)
	else:
		_run_nodes.erase(sector_key)
		_run_probe.erase(sector_key)
	if not mark_idx.is_empty():
		var mm := StandardMaterial3D.new()
		mm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mm.vertex_color_use_as_albedo = true
		root.add_child(_mesh_of(marks, PackedVector2Array(), mark_idx, mark_col, mm))
	if _stats:
		print("object-runs\\tsector=%d,%d\\tsource=%d\\truns=%d\\tclass=%s\\tshared_material=%s" % [gx, gy, source_objects, sector_nodes.size(), _run_class_counts(sector_nodes), sector_nodes.size() > 0])
	if root.get_child_count() == 0:
		root.free()
		return null
	return root


## Debug overlay: one flat diamond per classified region cell, colour-coded.
## This exists to VERIFY the decode against the retail captures -- the class
## grid reads as a walkable-area map with doors and thresholds, which is what
## it turned out to be (results log 308), not the interior floor plan it was
## first taken for.
func _classify_object(obj: Dictionary, p: Vector2, gx: int, gy: int, regions: Sacred.Regions,
		footprints: Sacred.Footprints = null) -> Dictionary:
	var family := _items.family_of(obj["type"]) if _items != null else ""
	var region_key := -1
	# Bind the object to its region (building) BEFORE the level branches so
	# levelled pieces (roof/interior) toggle only their own building, never a
	# same-family building elsewhere in the world (2026-08-13: OZELT1 has 7
	# regions; the old family-only match cropped all 7 when one tent was
	# entered). _footprint_membership handles both containment and the
	# near-footprint overhang case (tent corners 1-2 cells outside the rect).
	if footprints != null:
		var fp_res := _footprint_membership(p, gx, gy, footprints, family)
		if family == "":
			family = fp_res["family"]
		if region_key < 0:
			region_key = fp_res["region_key"]
	var levels: int = _items.levels(obj["type"]) if _items != null else 0
	var top_level: bool = _items.is_top_level(obj["type"]) if _items != null else false
	if top_level:
		return {"class": "INTERIOR", "family": family, "region_key": region_key}
	if levels != 0 and (levels & (levels - 1)) != 0:
		return {"class": "SHARED", "family": family, "region_key": region_key}
	# A levelled piece that is neither the top level nor a shared (0U1) wall is
	# ROOF/STRUCTURE: it must vanish when the player enters the building.
	# Before this, such pieces fell through to the cell-based rule below, so a
	# roof piece sitting on a FLOOR cell was classed INTERIOR (visible inside:
	# "roof doesn't crop cleanly") and a wall over a FLOOR cell was invisible
	# from outside ("walls wrong"). The level token is authoritative; the cell
	# is not (2026-08-13).
	if levels != 0:
		return {"class": "EXTERIOR", "family": family, "region_key": region_key}
	# Unlevelled piece (prop, ground): classify by the region cell class.
	# A prop whose cell is inside ANY region footprint -- even on an EMPTY
	# (class 0) cell -- is building interior content (beds, barrels, weapon
	# racks, forge) and must hide when the building shows its exterior.
	# Measured 2026-08-13: 58 interior props sit on EMPTY cells in the arena
	# camp and contaminated the exterior view because the old rule only caught
	# FLOOR-cell props (15). _footprint_membership already resolved which
	# region the cell belongs to; bind the prop to it.
	if region_key >= 0:
		return {"class": "INTERIOR", "family": family, "region_key": region_key}
	var object_cell := Sacred.Footprints._object_cell(p)
	for region_index_candidate: int in regions.list.size():
		var region: Dictionary = regions.list[region_index_candidate]
		var anchor: Vector2i = region["cell"]
		var local := object_cell - anchor
		if local.x < 0 or local.y < 0 or local.x >= int(region["size"].x) or local.y >= int(region["size"].y):
			continue
		var cls := Sacred.Regions.cell_class(region, local.x, local.y)
		if cls == Sacred.Regions.FLOOR or (_items != null and _items.is_interior(obj["type"])):
			return {"class": "INTERIOR", "family": family,
				"region_key": gx * 1000000 + gy * 1000 + region_index_candidate}
		if cls == Sacred.Regions.WALL or cls == Sacred.Regions.DOOR or cls == Sacred.Regions.STEP:
			return {"class": "EXTERIOR", "family": family,
				"region_key": gx * 1000000 + gy * 1000 + region_index_candidate}
	return {"class": "SHARED", "family": family, "region_key": region_key}


## The footprint containing the object's cell, as {family, region_key}, or
## {family: "", region_key: -1} if none. region_key is the packed Interior key
## (gx*1e6 + gy*1e3 + index) of the footprint's OWNING sector -- the same
## packing Interior.derive uses, so the view's run binding and the sim's state
## dictionary agree on the key.
##
## Pass 1: exact rect containment in the owning sector (the common case).
##
## Pass 2 (nearest same-family region): for a piece whose CELL falls outside
## every rect -- a tent corner overhanging its footprint, or a piece sitting in
## the 1-cell GAP between two adjacent tents' rects (measured at the arena
## camp: OZELT1/2/3 tents at sector 53,28 with overlapping footprints) -- bind
## to the nearest region of the SAME family. The game places a tent's pieces
## around its footprint; overhang and inter-tent gaps are normal, and the swap
## must crop THAT tent, not a same-named tent elsewhere in the world (OZELT1
## has 7 world regions) and not its neighbour of a different family.
func _footprint_membership(p: Vector2, gx: int, gy: int, footprints: Sacred.Footprints,
		piece_family: String = "") -> Dictionary:
	if footprints == null or _world == null or not _world.has_sector(gx, gy):
		return {"family": "", "region_key": -1}
	var cell := Sacred.Footprints._object_cell(p)
	# Pass 1: exact rect containment in the owning sector. For a LEVELLED piece
	# with a known family, containment alone is not binding: the arena camp's
	# three tents (OZELT1/2/3) have overlapping 16x19 footprint rects, and an
	# OZELT1 piece can physically sit inside the OZELT2 region's rect (measured
	# at sector 53,28: OZELT1_0_03 at cell (3408,1830) is inside region 1 =
	# OZELT2). A levelled piece belongs to its FAMILY's region, so pass 1 is
	# used only when the piece's family matches the containing region's.
	var resolved := _resolved_footprints(gx, gy)
	var keys: Array = resolved.keys()
	keys.sort()
	for key: int in keys:
		var fp: Dictionary = resolved[key]
		if Rect2i(fp["anchor"], fp["size"]).has_point(cell):
			var fam: String = str(fp.get("family", ""))
			if piece_family == "" or fam == piece_family:
				return {"family": fam,
					"region_key": gx * 1000000 + gy * 1000 + key}
	# Pass 2: nearest region of the SAME family as the piece, in the 3x3 block
	# around the cell's sector. It requires a known family, because "same
	# family" is the only thing bounding it: the search has no distance limit,
	# so an UNLEVELLED piece -- a tree, a bush, a flower, which has no family --
	# used to fall through the family filter and bind to whatever region was
	# nearest anywhere in that 3x3 block. Measured 2026-08-13 at the chapel:
	# "CW_Tree 34(B)" at cell (3191,2505), 22 cells west of the 3213..3246 x
	# 2502..2531 rect, was classified INTERIOR on region 50,39,0, so a stand of
	# trees outside the building appeared in front of its walls the moment the
	# roof came off. A prop that is inside a rect still binds -- that is pass 1,
	# and it is what makes a building's barrels and beds interior content.
	if piece_family == "":
		return {"family": "", "region_key": -1}
	var sx := int(floor(float(cell.x) / float(Sacred.SECT)))
	var sy := int(floor(float(cell.y) / float(Sacred.SECT)))
	var best_family := ""
	var best_key := -1
	var best_dist := 1 << 30
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var nsx := sx + dx
			var nsy := sy + dy
			if nsx < 0 or nsy < 0 or nsx >= 100 or nsy >= 100:
				continue
			if not _world.has_sector(nsx, nsy):
				continue
			var near := _resolved_footprints(nsx, nsy)
			var nkeys: Array = near.keys()
			nkeys.sort()
			for nkey: int in nkeys:
				var fp: Dictionary = near[nkey]
				var fam: String = str(fp.get("family", ""))
				if fam == "":
					continue
				if piece_family != "" and fam != piece_family:
					continue
				var rect := Rect2i(fp["anchor"], fp["size"])
				var dxd := maxi(rect.position.x - cell.x, cell.x - (rect.end.x - 1))
				dxd = maxi(dxd, 0)
				var dyd := maxi(rect.position.y - cell.y, cell.y - (rect.end.y - 1))
				dyd = maxi(dyd, 0)
				var d := dxd * dxd + dyd * dyd
				if d < best_dist:
					best_dist = d
					best_family = fam
					best_key = nsx * 1000000 + nsy * 1000 + nkey
	return {"family": best_family, "region_key": best_key}


## Cached footprints.resolve() for one sector: inflate and parse once, reuse
## for every object classified in that sector's build (the startup regression
## fix -- before this, each object re-inflated the sector stream).
func _resolved_footprints(gx: int, gy: int) -> Dictionary:
	var key := gy * 100 + gx
	if _footprint_cache.has(key):
		return _footprint_cache[key]
	var resolved := _footprints.resolve(_world.sector(gx, gy), gx, gy)
	_footprint_cache[key] = resolved
	return resolved


func _run_class_counts(runs: Array[Dictionary]) -> String:
	var counts: Dictionary[String, int] = {"EXTERIOR": 0, "INTERIOR": 0, "SHARED": 0}
	for run_meta: Dictionary in runs:
		var name: String = run_meta["class"]
		counts[name] = int(counts.get(name, 0)) + 1
	return "E%d/I%d/S%d" % [counts["EXTERIOR"], counts["INTERIOR"], counts["SHARED"]]


## Dense, per-view renumbering of region keys for the shader bucket channel.
##
## The bucket id travels to the GPU in UV2.y, a FLOAT32 vertex attribute. The
## packed region key (gx*1000000 + gy*1000 + idx) reaches ~5e7, so the bucket
## rk*2+bit reaches ~1e8 where the float32 ULP is 8 -- EXTERIOR and INTERIOR
## collapsed onto ONE id and every interior object was discarded (row 663,
## measured: intact only for gx <= 8, i.e. essentially the whole world broken).
## Renumbering densely from 0 keeps ids in the low hundreds, exactly
## representable. Nothing else needs the packed value: it stays the key of the
## simulation-side state dictionary and is translated here, at the boundary.
##
## ponytail: ids are never recycled on sector unload, so a very long session
## walking thousands of distinct buildings would eventually climb. The ceiling
## is 2^23 ids (float32 exact-integer range) -- ~8M buildings, unreachable.
func _dense_bucket_id(region_key: int) -> int:
	if not _bucket_ids.has(region_key):
		_bucket_ids[region_key] = _bucket_ids.size()
	return _bucket_ids[region_key]


func apply_swap(states: Dictionary) -> void:
	if _has_applied_swap and states == _last_swap_states:
		return
	_last_swap_states = states.duplicate(true)
	_has_applied_swap = true
	# The swap is a shader-side bucket discard: one mesh per band keeps the
	# painter-correct contiguous submission order (Phase-2 research), and the
	# shader drops fragments whose bucket (region_key*2 + class bit) is hidden.
	# Bucket id: region_key*2 + (1 if INTERIOR else 0). For each region in
	# INTERIOR state, its EXTERIOR bucket is hidden; for each region in
	# EXTERIOR state, its INTERIOR bucket is hidden (when not force-interior).
	# _force_interior hides every EXTERIOR bucket and shows all INTERIOR.
	var hidden: Array[int] = []
	if _force_interior:
		# Hide every EXTERIOR bucket (region_key*2) of every region present in
		# the resident sectors. Each band mesh holds mixed classes, so the
		# bucket set comes from the region keys of all runs, not any one run's
		# "class" field.
		# Every region key that ever entered a mesh, not the band-first object of
		# each run: run_meta["region_key"] is the FIRST object's key only, so
		# collecting from it missed most keys (row 663, second bug).
		for rk: int in _bucket_ids:
			var b := _bucket_ids[rk] * 2
			if not hidden.has(b):
				hidden.append(b)
	else:
		for region_key: int in states:
			var state_value: Variant = states[region_key]
			var state: int = int(state_value["state"]) if state_value is Dictionary else int(state_value)
			# Each region contributes exactly one hidden bucket: when INTERIOR,
			# hide its exterior (roof); when EXTERIOR, hide its interior.
			var hide_interior: bool = state != Interior.State.INTERIOR
			if not _bucket_ids.has(region_key):
				continue   # region not present in any loaded mesh
			var bucket := _bucket_ids[region_key] * 2 + (1 if hide_interior else 0)
			if not hidden.has(bucket):
				hidden.append(bucket)
	# Set the uniform on every band mesh's material. All band meshes in a
	# sector share ONE material, so one pass covers them; the uniform is set
	# per-material to be safe across sectors (each sector builds its own).
	hidden.sort()
	# THE COUNT AND THE ARRAY MUST BE CLAMPED TOGETHER. `hidden_buckets` is
	# declared `uniform int[HIDDEN_BUCKET_SLOTS]` in object.gdshader and the
	# fragment loop runs to `hidden_bucket_count`, so passing an unclamped count
	# alongside a clamped array makes the shader index past the end -- garbage
	# ints compared against real bucket ids, discarding fragments of unrelated
	# buildings. That is a WRONG PICTURE with no error raised, which is why the
	# overflow is reported here rather than quietly truncated.
	#
	# Truncation itself is not safe either: `hidden.sort()` orders by dense
	# bucket id, so the survivors are the earliest-registered regions and the
	# building the player just walked into is exactly the one whose roof stops
	# being hidden. Interior.derive() registers every footprint it sees and
	# never retires one, so a town reaches this ceiling.
	var n := mini(hidden.size(), HIDDEN_BUCKET_SLOTS)
	if hidden.size() > HIDDEN_BUCKET_SLOTS:
		push_error("SectorView: %d hidden buckets exceeds the shader's %d slots; %d regions will draw their roofs"
			% [hidden.size(), HIDDEN_BUCKET_SLOTS, hidden.size() - HIDDEN_BUCKET_SLOTS])
	# Built once, not per material: every material gets the same contents.
	var arr := PackedInt32Array()
	arr.resize(HIDDEN_BUCKET_SLOTS)
	for i in n:
		arr[i] = hidden[i]
	var set_count := 0
	for sector_key: int in _run_nodes:
		for run_meta: Dictionary in _run_nodes[sector_key]:
			var node: MeshInstance3D = run_meta["node"]
			var mat := node.material_override as ShaderMaterial
			if mat == null:
				continue
			mat.set_shader_parameter(&"hidden_bucket_count", n)
			mat.set_shader_parameter(&"hidden_buckets", arr)
			set_count += 1
			break   # one material per sector; move to the next sector
	print("swap-apply\\tvisible=%d\\thidden_buckets=%d\\tbuilds=%d\\tmeshes=%d\\tmaterials=%d\\tdecodes=%d" % [
		_run_nodes.size(), hidden.size(), sector_build_calls, object_mesh_creations, object_material_creations, object_texture_decodes])


## Does this state entry toggle runs bound to (region_key, family)?
## A run carrying a concrete region key (region_key >= 0) is toggled ONLY by
## that exact region's state -- two buildings of the same family must not
## crop each other (2026-08-13: OZELT1 has 7 world regions; the old family-only
## match cropped all 7 when one tent was entered). A run with no region key
## (region_key < 0 -- a prop or ground piece with no footprint) matches by
## family, which is safe because such runs are SHARED and never toggled.
func _region_state_matches(region_key: int, states: Dictionary,
		run_region_key: int, run_family: String) -> bool:
	var state_value: Variant = states[region_key]
	var state: int = int(state_value["state"]) if state_value is Dictionary else int(state_value)
	if state != Interior.State.INTERIOR:
		return false
	if run_region_key >= 0:
		return run_region_key == region_key
	return run_family != "" and str(state_value.get("family", "")) == run_family



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
func _build_spawns(gx: int, gy: int) -> Node3D:
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
func _build_classhi(cells: PackedByteArray, gx: int, gy: int) -> Node3D:
	var pos := PackedVector3Array()
	var col := PackedColorArray()
	var idx := PackedInt32Array()
	for i in Sacred.SECT * Sacred.SECT:
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
func _build_flags1e(cells: PackedByteArray, gx: int, gy: int) -> Node3D:
	const COLOURS := {
		0x01: Color(1.0, 0.15, 0.15, 0.60),
		0x02: Color(0.15, 1.0, 0.15, 0.60),
		0x04: Color(0.3, 0.4, 1.0, 0.75),
	}
	var pos := PackedVector3Array()
	var col := PackedColorArray()
	var idx := PackedInt32Array()
	for i in Sacred.SECT * Sacred.SECT:
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


func _build_regions(regions: Sacred.Regions) -> Node3D:
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


## Which of `bands` contiguous slices index `i` of `n` (already back-to-front
## sorted) objects falls into. Binned by INDEX, never by tile, so one object's
## whole floor-then-walls-then-roof run always lands in exactly one band.
## Never called when n == 0 (the loop over objs simply doesn't iterate then).
func _band_of(i: int, n: int, bands: int) -> int:
	return mini(int(floor(float(i) * bands / n)), bands - 1)


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


## Fixed-block mode: the regression check. Loads every sector in the block,
## fits the camera to it, and prints the same "<quads> quads, <textures>
## textures" line the pre-streaming viewer printed.
func load_region(cx: int, cy: int, r: int) -> void:
	_streaming = false
	var quads := 0
	var texids: Dictionary[int, bool] = {}
	for gy in range(cy - r, cy + r + 1):
		for gx in range(cx - r, cx + r + 1):
			var node := _build_sector(gx, gy)
			if node == null:
				continue
			add_child(node)
			_loaded[gy * 100 + gx] = node
			quads += int(node.get_meta("quads"))
			for tid in _world.tile_ids(gx, gy):
				texids[_tiles.texture_id(tid)] = true
	var span := float(r * 2 + 1) * SECT
	_cam.size = span * 2.0 * HH * 1.1
	_cam.look_at_cell(Vector2(cx * SECT + SECT * 0.5, cy * SECT + SECT * 0.5))
	print("%d quads, %d textures" % [quads, texids.size()])


## True once the streamer has nothing left to load -- either it is not
## streaming at all (--region= mode already finished its one-shot build), or
## the wanted set and the loaded set agree. The settle test main.gd's
## _maybe_screenshot and _actor_probe both pump frames against.
##
## Set membership, not counts: after a camera jump the backlog of the OLD
## cell's sectors drains one per frame (stream() above), and a count-only
## test passes spuriously the moment _loaded.size() happens to equal the new
## wanted size while every loaded sector is still the old cell's -- a --shot
## then fires on an unstreamed void (TSV row 614). _pending must be empty
## AND every wanted key actually loaded.
func is_settled() -> bool:
	if not _streaming:
		return true
	if not _pending.is_empty():
		return false
	var want := _wanted_sectors()
	if want.size() != _loaded.size():
		return false
	for key in want:
		if not _loaded.has(key):
			return false
	return true
