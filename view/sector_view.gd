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

## --bands= upper clamp. 4096 is one band per sector cell (SECT*SECT / SECT =
## SECT bands would already over-separate; this is a hard ceiling regardless
## of SECT), the point past which more bands cannot separate more objects.
## Also removes the divide-by-zero a --bands=0 would otherwise cause in
## _band_of before main.gd's own clamp turns 0 into 1 (T-02-01).
const BAND_MAX := 4096

## _band_depth is only NON-decreasing across bands (proven empirically at
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
const TERRAIN_SHADER: Shader = preload("res://terrain.gdshader")
const OBJECT_SHADER: Shader = preload("res://object.gdshader")

@export var load_margin := 64.0                    ## cells loaded beyond the viewport
@export var loads_per_frame := 1
## Screen pixels per unit of WldxEntry height. Unknown; 1.0 is a starting guess.
@export var height_scale := 1.0

var _cam: IsoCamera
var _tex_pak: Sacred.Pak
var _tiles: Sacred.Tiles
var _world: Sacred.World
## Typed collections (Godot 4.4+): the key/value contracts here are the whole
## reason the streamer is readable, so they are worth stating.
var _loaded: Dictionary[int, MeshInstance3D] = {}  ## sector key -> mesh, null if it draws nothing
var _images: Dictionary[int, Image] = {}           ## texture.pak id -> decoded tile
var _statics: Sacred.Statics
var _mixed: Sacred.Mixed
var _items: Sacred.Items                  ## names, for the interior/exterior swap
var _interiors := false                   ## --interiors: draw the INSIDE set instead
var _show_regions := false                ## --regions: overlay building footprints
var _hide_levels := 0                     ## --hidelevel=N: bitmask of levels to drop
var _exterior := false                    ## --exterior: drop each building's top level
var _pending: Array[int] = []             ## sectors queued for a later frame
var _last_view := Vector3(NAN, NAN, NAN)  ## camera x/y/zoom the wanted-set was derived from
var _streaming := true
var _stats := false
var _objects := true                      ## draw static object sprites
var _markers := false                     ## ...as flat coloured squares instead
var _only_flag := -1                      ## debug: draw only objects with this +0x08 flag
var _band_count := 1                      ## --bands=N: object depth bands per sector

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
##   interiors: bool    -- --interiors
##   regions: bool      -- --regions
##   exterior: bool     -- --exterior
##   hide_levels: int   -- --hidelevel= bitmask (default 0)
##   only_flag: int     -- --onlyflag=, or -1 for "off" (default -1)
##   band_count: int    -- --bands=N object depth bands per sector (default 1)
func setup(cam: IsoCamera, tex_pak: Sacred.Pak, tiles: Sacred.Tiles, world: Sacred.World,
		statics: Sacred.Statics, mixed: Sacred.Mixed, items: Sacred.Items, opts: Dictionary) -> void:
	_cam = cam
	_tex_pak = tex_pak
	_tiles = tiles
	_world = world
	_statics = statics
	_mixed = mixed
	_items = items
	_stats = opts.get("stats", false)
	_markers = opts.get("markers", false)
	_objects = opts.get("objects", true)
	_interiors = opts.get("interiors", false)
	_show_regions = opts.get("regions", false)
	_exterior = opts.get("exterior", false)
	_hide_levels = opts.get("hide_levels", 0)
	_only_flag = opts.get("only_flag", -1)
	# maxi(1, ...) so a caller that reaches setup() from outside main.gd's own
	# clamp (e.g. a future test harness) can never hand _band_of a divisor of 0.
	_band_count = maxi(1, opts.get("band_count", 1))


## The streaming body, moved out of main.gd's _process verbatim (its early
## returns are now local to it) so main.gd._process can also drive the sim
## accumulator on frames the streamer itself has nothing to do on.
func stream(_delta: float) -> void:
	if not _streaming or _cam == null:
		return
	# The visible set only changes when the camera does. Re-deriving it every
	# frame allocated a Dictionary and re-walked the sector grid for nothing;
	# skip while the view is still and there is no backlog.
	var view := Vector3(_cam.position.x, _cam.position.y, _cam.size)
	if view == _last_view and _pending.is_empty():
		return
	_last_view = view

	if not _pending.is_empty():
		_add_sector(_pending.pop_front())
		return

	var want := _wanted_sectors()
	for key: int in _loaded.keys():
		if not want.has(key):
			var node: Node = _loaded[key]
			if node != null:
				node.queue_free()
			_loaded.erase(key)
			probe_unloaded += 1

	var missing: Array[int] = []
	for key: int in want:
		if not _loaded.has(key):
			missing.append(key)
	if missing.is_empty():
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
	probe_reloaded += 1


## One sector -> one MeshInstance3D with its own Texture2DArray. Returns null if
## the sector holds no drawable tile.
func _build_sector(gx: int, gy: int) -> MeshInstance3D:
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

	for i in Sacred.SECT * Sacred.SECT:
		var cell := i * Sacred.CELL
		var tile_id := cells.decode_u32(cell)
		var texid := _tiles.texture_id(tile_id)
		if not layer_of.has(texid):
			var img := _image(texid)
			if img == null:
				continue
			layer_of[texid] = images.size()
			images.append(img)
		var x := float(gx * SECT + i % SECT)
		var y := float(gy * SECT + i / SECT)
		var px := (x - y) * HW
		var py := -(x + y) * HH
		var pz := (x + y) * DEPTH_STEP
		var l := float(layer_of[texid])
		var v := pos.size()
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
		pos.append_array([
			Vector3(px, py + HH + _h(cells, cell, 1), pz),    # N
			Vector3(px + HW, py + _h(cells, cell, 2), pz),    # E
			Vector3(px, py - HH + _h(cells, cell, 3), pz),    # S
			Vector3(px - HW, py + _h(cells, cell, 0), pz)])   # W
		# The texture is an 18-slot diamond atlas; the tile's orientation field
		# picks the slot. Sampling the whole image (as the pre-2.4 viewer did)
		# squeezes all 18 diamonds into every cell, which is what produced the
		# regular dotted pattern.
		# The texture is an 18-slot diamond atlas; the tile's orientation field
		# picks the slot. The diamond's corners sit at the slot rect's EDGE
		# MIDPOINTS, so the transparent rect corners are never sampled at all.
		var r := Sacred.slot_uv(_tiles.orientation(tile_id))
		var mid := r.position + r.size * 0.5
		uv.append_array([
			Vector2(mid.x, r.position.y), Vector2(r.end.x, mid.y),
			Vector2(mid.x, r.end.y), Vector2(r.position.x, mid.y)])
		# +0x14..0x17 are four per-corner light bytes (never zero; 255/235/215/195,
		# a clean step of -20), in the same W,N,E,S order.
		for c in [1, 2, 3, 0]:
			var s := cells.decode_u8(cell + 0x14 + c) / 255.0
			col.append(Color(s, s, s))
		uv2.append_array([Vector2(l, 0), Vector2(l, 0), Vector2(l, 0), Vector2(l, 0)])
		idx.append_array([v, v + 1, v + 2, v, v + 2, v + 3])

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
	mi.material_override = mat
	mi.set_meta("quads", idx.size() / 6)
	mi.set_meta("layers", images.size())
	if _objects:
		var m := _build_objects(cells, regions)
		if m != null:
			mi.add_child(m)
	if _show_regions and not regions.list.is_empty():
		var r := _build_regions(regions)
		if r != null:
			mi.add_child(r)
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
func _build_objects(cells: PackedByteArray, regions: Sacred.Regions) -> Node3D:
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
	var objs: Array[Dictionary] = []
	for i in Sacred.SECT * Sacred.SECT:
		var o := _statics.get_object(cells.decode_u32(i * Sacred.CELL + 4))
		if o.is_empty():
			continue
		if _only_flag >= 0 and o["flags"] != _only_flag:
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

	var n := objs.size()
	# One geometry set per band; layer_of/images stay function-scoped (Pattern
	# 2) -- the sector's Texture2DArray/ShaderMaterial are still built once and
	# shared by every band, only pos/uv/uv2/idx are repartitioned.
	var band_pos: Array[PackedVector3Array] = []
	var band_uv: Array[PackedVector2Array] = []
	var band_uv2: Array[PackedVector2Array] = []
	var band_idx: Array[PackedInt32Array] = []
	var band_repr: Array[float] = []
	var band_has_repr: Array[bool] = []
	for _b in _band_count:
		band_pos.append(PackedVector3Array())
		band_uv.append(PackedVector2Array())
		band_uv2.append(PackedVector2Array())
		band_idx.append(PackedInt32Array())
		band_repr.append(0.0)
		band_has_repr.append(false)

	for i in n:
		var obj: Dictionary = objs[i]
		var p: Vector2 = obj["pos"]
		# Binned by INDEX into the already-sorted objs array, never by tile --
		# every object's whole floor-then-walls-then-roof tile run lands inside
		# exactly one band (Pattern 1). Computed for every object regardless of
		# whether it ends up drawing anything (marker fallback, missing art),
		# so a band's representative depth always comes from the first index
		# assigned to that band's range, not the first index that happened to
		# emit geometry.
		var band := _band_of(i, n, _band_count)
		if not band_has_repr[band]:
			band_repr[band] = _band_depth(p)
			band_has_repr[band] = true
		var spr := _mixed.sprite(obj["type"]) if not _markers else {}
		if spr.is_empty():
			if not _markers:
				continue                   # invisible marker type, or no art
			var c := Color.from_hsv(fmod(obj["type"] * 0.137, 1.0), 0.9, 1.0)
			var mv := marks.size()
			# No sprite, so no height to add: the marker's own point is its base.
			var mz := (-p.y / HH) * DEPTH_STEP + 2.0
			marks.append_array([Vector3(p.x - 10, p.y + 10, mz), Vector3(p.x + 10, p.y + 10, mz),
				Vector3(p.x + 10, p.y - 10, mz), Vector3(p.x - 10, p.y - 10, mz)])
			mark_col.append_array([c, c, c, c])
			mark_idx.append_array([mv, mv + 1, mv + 2, mv, mv + 2, mv + 3])
			continue
		# static.pak's ox/oy is the sprite's TOP-LEFT in screen space, not its
		# ground point. Solved, not guessed: regressing the placement residual
		# against sprite size over 11465 objects gives slope -0.466 against w
		# and -0.948 against h -- i.e. ox already carries -w/2 and oy already
		# carries -h. Re-applying them (the old "bottom-centre" reading) shifted
		# every piece by an amount proportional to its OWN size, which is why
		# parts of one building came apart while each part looked fine.
		var size: Vector2i = spr["size"]
		var anchor: Vector2i = spr["anchor"]
		var origin := Vector2(p.x + anchor.x, p.y - anchor.y)
		# ...and so the object's GROUND depth is oy + h, not oy. Sorting on oy
		# made tall objects sort as if they stood at their own rooftop, which is
		# the occlusion half of the same bug.
		var pz := ((-p.y + size.y) / HH) * DEPTH_STEP + 2.0
		# Tiles are emitted in mixed.pak order, which IS the retail compositor's
		# paint order for the parts of one object -- floor, then walls, then
		# roof. Preserving it is the whole point of the single surface -- now
		# one surface PER BAND, never split across two.
		for tile: Dictionary in spr["tiles"]:
			var tid: int = tile["tex"]
			if not layer_of.has(tid):
				var img := _image(tid)
				if img == null:
					continue
				layer_of[tid] = images.size()
				images.append(img)
			var l := float(layer_of[tid])
			var d: Rect2i = tile["dst"]
			var s: Rect2 = tile["src"]
			var x0 := origin.x + d.position.x
			var y0 := origin.y - d.position.y
			var x1 := x0 + d.size.x
			var y1 := y0 - d.size.y
			# Packed*Array elements of a typed Array are value types (COW): a
			# mutating call on band_pos[band] directly would not necessarily
			# write back through the outer Array, so read, mutate the local
			# copy, then explicitly reassign -- correct regardless of whether
			# [] returns a reference or a copy.
			var bp: PackedVector3Array = band_pos[band]
			var v: int = bp.size()
			bp.append_array([Vector3(x0, y0, pz), Vector3(x1, y0, pz),
				Vector3(x1, y1, pz), Vector3(x0, y1, pz)])
			band_pos[band] = bp
			var bu: PackedVector2Array = band_uv[band]
			bu.append_array([s.position, Vector2(s.end.x, s.position.y), s.end,
				Vector2(s.position.x, s.end.y)])
			band_uv[band] = bu
			var bu2: PackedVector2Array = band_uv2[band]
			bu2.append_array([Vector2(l, 0), Vector2(l, 0), Vector2(l, 0), Vector2(l, 0)])
			band_uv2[band] = bu2
			var bidx: PackedInt32Array = band_idx[band]
			bidx.append_array([v, v + 1, v + 2, v, v + 2, v + 3])
			band_idx[band] = bidx

	# See BAND_TIE_EPS: band_repr is only non-decreasing by construction, so
	# force it strictly increasing here -- a no-op for every band whose depth
	# already differs from its predecessor.
	for b in range(1, _band_count):
		if band_repr[b] <= band_repr[b - 1]:
			band_repr[b] = band_repr[b - 1] + BAND_TIE_EPS

	var root := Node3D.new()
	root.name = "Objects"
	if not images.is_empty():
		var tex := Texture2DArray.new()
		tex.create_from_images(images)
		var mat := ShaderMaterial.new()
		mat.shader = OBJECT_SHADER
		mat.set_shader_parameter(&"tex", tex)
		for b in _band_count:
			if band_idx[b].is_empty():
				continue                   # matches the images.is_empty() guard idiom
			var band_mesh := _mesh_of(band_pos[b], band_uv[b], band_idx[b],
				PackedColorArray(), mat, band_uv2[b])
			band_mesh.sorting_use_aabb_center = false
			# Sign determined empirically, not assumed: --bands=2 on sector
			# 64,39 against /tmp/p2/base_6439.png only reproduces the baseline
			# (byte-identical) with the POSITIVE representative depth --
			# negation differed from byte 723166. Recorded as a FINDING row in
			# analysis/autoresearch-results.tsv.
			band_mesh.sorting_offset = band_repr[b]
			root.add_child(band_mesh)
	if not mark_idx.is_empty():
		var mm := StandardMaterial3D.new()
		mm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mm.vertex_color_use_as_albedo = true
		root.add_child(_mesh_of(marks, PackedVector2Array(), mark_idx, mark_col, mm))
	if root.get_child_count() == 0:
		# Node is not RefCounted: returning null without this leaks the Node3D,
		# which Godot reports as "1 ObjectDB instance was leaked at exit".
		root.free()
		return null
	return root


## Debug overlay: one flat diamond per classified region cell, colour-coded.
## This exists to VERIFY the decode against the retail captures -- the class
## grid reads as a walkable-area map with doors and thresholds, which is what
## it turned out to be (results log 308), not the interior floor plan it was
## first taken for.
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
func _band_depth(p: Vector2) -> float:
	return (-p.y / HH) * DEPTH_STEP + 2.0


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
func is_settled() -> bool:
	return not _streaming or _wanted_sectors().size() == _loaded.size()
