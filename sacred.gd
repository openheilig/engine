class_name Sacred
extends RefCounted
## Runtime readers for the retail Sacred data files.
##
## Nothing here copies, caches or ships a retail byte -- every read seeks into
## the user's own install. See AGENTS.md "Working in godot-port/".
##
## Formats (recovered in analysis/, see RESEARCH and autoresearch-results.tsv):
##   *.pak          256 B header, u32 count @4, index @0x100 of {u32 flags, u32 off, u32 size}
##   tiles.pak      64 B records: name[32], u32 texture id @0x20, u32 orientation @0x24
##   texture.pak    80 B image header: name[32], u16 w @32, u16 h @34, u8 type @36; then zlib
##   sectors.keyx   "WLK" v5, u32 count @4, u32 w @8, u32 h @12; 768 B records from 0x100
##   sectors.wldx   "WLD" v5; zlib streams located by keyx, NOT by scanning

const SECT := 64          ## cells per sector edge
const TILE := 256         ## terrain texture edge
const CELL := 32          ## bytes per WldxEntry
const NAME := 32          ## bytes of (unreliable) name at the head of a sector stream

## Terrain textures are not one tile each -- every 256x256 image is an ATLAS of
## 18 iso diamonds, and `tiles.pak +0x24` (0..17) selects which one. Measured
## 2026-08-07 by connected-component labelling of the alpha channel: exactly 18
## components, each exactly 2500 px with a 100x49 bounding box, and the mask is
## byte-identical across every terrain texture sampled. Layout is 9 rows of 2,
## odd rows staggered by half a cell:
##     slot n -> row = n / 2, col = n % 2
##     x0 = col * 104 + (row % 2) * 52,   y0 = row * 25
## Slot 17 ends at (255, 248), so all 18 fit with no wrap.
const SLOT_COUNT := 18
const SLOT_W := 100      ## measured opaque diamond width  (stride is 104)
const SLOT_H := 49       ## measured opaque diamond height (row step is 25, so 50)
const SLOT_DX := 104
const SLOT_DY := 25
const SLOT_STAGGER := 52
const ATLAS := 256.0
## Half-texel shrink of the sampled rect. Without it, linear filtering at the
## diamond's tips reaches into the 4 px of padding between slots and draws a
## faint dark grid over the whole world.
const SLOT_INSET := 1.0


## Normalised UV rect of atlas slot n, covering the slot's *opaque* diamond
## bounding box (not the 104x50 lattice cell) and inset to keep the filter off
## the padding. The diamond's four tips are this rect's edge midpoints.
static func slot_uv(n: int) -> Rect2:
	var row := n / 2
	var col := n % 2
	return Rect2(
		(col * SLOT_DX + (row % 2) * SLOT_STAGGER + SLOT_INSET) / ATLAS,
		(row * SLOT_DY + SLOT_INSET) / ATLAS,
		(SLOT_W - 2 * SLOT_INSET) / ATLAS,
		(SLOT_H - 2 * SLOT_INSET) / ATLAS)


const PAK_HDR := 256
const PAK_IDX := 12
const KEY_HDR := 256
const KEY_REC := 768
const KEY_COORD := 32     ## u32 gy*100+gx -- authoritative, unlike the in-stream name
const KEY_OFF := 236      ## u32 byte offset into sectors.wldx
const KEY_CSIZE := 240    ## u32 compressed size
const KEY_DSIZE := 264    ## u32 decompressed size


## Resolves the retail install directory. Order: --install=PATH on the command
## line, then user://opensacred.cfg, then the workspace sibling. Returns "" if
## none of them holds a real install.
static func find_install() -> String:
	for candidate in [_cli_install(), _cfg_install(), _sibling_install()]:
		if candidate != "" and is_install(candidate):
			return candidate
	return ""


## An install is anything that has the two files the terrain reader needs.
static func is_install(path: String) -> bool:
	return FileAccess.file_exists(path.path_join("pak/tiles.pak")) \
		and FileAccess.file_exists(path.path_join("world/sectors.wldx"))


static func save_install(path: String) -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("game", "install_path", path)
	cfg.save("user://opensacred.cfg")


static func _cli_install() -> String:
	for arg in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if arg.begins_with("--install="):
			return arg.trim_prefix("--install=").simplify_path()
	return ""


static func _cfg_install() -> String:
	var cfg := ConfigFile.new()
	if cfg.load("user://opensacred.cfg") != OK:
		return ""
	return str(cfg.get_value("game", "install_path", ""))


static func _sibling_install() -> String:
	return ProjectSettings.globalize_path("res://").path_join("../install").simplify_path()


## zlib stream -> bytes.
##
## Godot's COMPRESSION_DEFLATE is **zlib-wrapped, not raw** -- it calls
## inflateInit2 with window_bits 15, so the 78 9c header must be kept. (The
## plan said the opposite; measured 2026-08-07, results log row 209. Raw
## deflate is not reachable through this API at all.)
##
## Output size is always known up front -- keyx +264 for sectors, w*h*2 for
## textures -- so decompress_dynamic() is never needed.
static func inflate(z: PackedByteArray, out_size: int) -> PackedByteArray:
	return z.decompress(out_size, FileAccess.COMPRESSION_DEFLATE)


## A .pak archive, read on demand. texture.pak is 820 MB -- nothing here ever
## slurps the whole file.
class Pak extends RefCounted:
	var offsets := PackedInt64Array()
	var sizes := PackedInt64Array()
	## Index record's first u32 (kind/flags). Added for models.pak, whose 4993
	## entries split 1572/3421 between two structurally different payload
	## kinds (64 mesh, 65 motion) sharing one index -- every other pak has one
	## shape, so nothing before Sacred.Models needed this field kept.
	var kinds := PackedInt32Array()
	var _f: FileAccess

	func _init(path: String) -> void:
		_f = FileAccess.open(path, FileAccess.READ)
		if _f == null:
			push_error("Sacred.Pak: cannot open %s (%s)" % [path, error_string(FileAccess.get_open_error())])
			return
		_f.seek(4)
		var n := _f.get_32()
		_f.seek(Sacred.PAK_HDR)
		var idx := _f.get_buffer(n * Sacred.PAK_IDX)
		offsets.resize(n)
		sizes.resize(n)
		kinds.resize(n)
		for i in n:
			kinds[i] = idx.decode_u32(i * Sacred.PAK_IDX + 0)
			offsets[i] = idx.decode_u32(i * Sacred.PAK_IDX + 4)
			sizes[i] = idx.decode_u32(i * Sacred.PAK_IDX + 8)

	func is_open() -> bool:
		return _f != null

	func count() -> int:
		return offsets.size()

	## Raw bytes of entry i, plus `extra` bytes past its recorded size. The
	## texture header lies outside the recorded size, hence the parameter.
	func blob(i: int, extra: int = 0) -> PackedByteArray:
		_f.seek(offsets[i])
		return _f.get_buffer(sizes[i] + extra)

	func read_at(off: int, n: int) -> PackedByteArray:
		_f.seek(off)
		return _f.get_buffer(n)

	func entry_offset(i: int) -> int:
		return offsets[i]

	## Byte length of the opened archive, or 0 if no file is open. Needed by
	## Sacred.Models.true_length() for the last entry, which has no successor
	## offset to subtract against.
	func file_size() -> int:
		return _f.get_length() if _f != null else 0


## tiles.pak: 64-byte records, one per tile id, giving the texture.pak id.
class Tiles extends RefCounted:
	var _rec: PackedByteArray
	var _n: int

	func _init(pak: Sacred.Pak) -> void:
		_n = pak.count()
		# 90132 * 64 B = 5.8 MB -- small enough to keep resident, unlike texture.pak.
		_rec = pak.read_at(pak.entry_offset(0), _n * 64)

	func count() -> int:
		return _n

	func texture_id(tile_id: int) -> int:
		return _rec.decode_u32(tile_id * 64 + 0x20)

	## ponytail: orientation (+0x24, 0..17) is read but unused -- 18 values is
	## more than 4 rotations, so decode it before applying it as a UV transform.
	func orientation(tile_id: int) -> int:
		return _rec.decode_u32(tile_id * 64 + 0x24)


## sectors.keyx + sectors.wldx. keyx is the shipped index: no scan, no cache.
class World extends RefCounted:
	var size := Vector2i.ZERO         ## sector grid, 100x100
	var _f: FileAccess
	var _by_key: Dictionary[int, int] = {}   ## gy*100+gx -> record index
	var _off := PackedInt64Array()
	var _csize := PackedInt64Array()
	var _dsize := PackedInt64Array()

	func _init(world_dir: String) -> void:
		var kf := FileAccess.open(world_dir.path_join("sectors.keyx"), FileAccess.READ)
		_f = FileAccess.open(world_dir.path_join("sectors.wldx"), FileAccess.READ)
		if kf == null or _f == null:
			push_error("Sacred.World: cannot open sectors.keyx / sectors.wldx in %s" % world_dir)
			return
		kf.seek(4)
		var n := kf.get_32()
		size = Vector2i(kf.get_32(), kf.get_32())
		kf.seek(Sacred.KEY_HDR)
		var keys := kf.get_buffer(n * Sacred.KEY_REC)
		_off.resize(n)
		_csize.resize(n)
		_dsize.resize(n)
		for i in n:
			var base := i * Sacred.KEY_REC
			_by_key[keys.decode_u32(base + Sacred.KEY_COORD)] = i
			_off[i] = keys.decode_u32(base + Sacred.KEY_OFF)
			_csize[i] = keys.decode_u32(base + Sacred.KEY_CSIZE)
			_dsize[i] = keys.decode_u32(base + Sacred.KEY_DSIZE)

	func is_open() -> bool:
		return _f != null

	func count() -> int:
		return _off.size()

	func has_sector(gx: int, gy: int) -> bool:
		return _by_key.has(gy * 100 + gx)

	## Decompressed sector stream, or an empty array if that sector is absent.
	## 3950 of the 10000 grid slots have no sector at all.
	func sector(gx: int, gy: int) -> PackedByteArray:
		var i: int = _by_key.get(gy * 100 + gx, -1)
		if i < 0:
			return PackedByteArray()
		_f.seek(_off[i])
		return Sacred.inflate(_f.get_buffer(_csize[i]), _dsize[i])

	## Raw 32-byte WldxEntry grid of one sector (4096 entries), or empty.
	## Field map is in the plan's Phase 3 table; the short version is
	## +0x00 tile id, +0x04/+0x0c object handles, +0x10/+0x14/+0x18 four
	## PER-CORNER bytes each (height delta / light / unknown), +0x1f flags.
	func entries(gx: int, gy: int) -> PackedByteArray:
		var d := sector(gx, gy)
		return PackedByteArray() if d.is_empty() else d.slice(
			Sacred.NAME, Sacred.NAME + Sacred.SECT * Sacred.SECT * Sacred.CELL)

	## Tile ids of one sector, row-major, 64x64. Empty if the sector is absent.
	## The stream's leading 32-byte name is deliberately ignored: it is a stale
	## 0xCD-padded buffer that disagrees with the true coordinate for 275 of the
	## 6050 sectors and is empty for 270 of them (results log rows 206-207).
	func tile_ids(gx: int, gy: int) -> PackedInt32Array:
		var d := sector(gx, gy)
		var out := PackedInt32Array()
		if d.is_empty():
			return out
		out.resize(Sacred.SECT * Sacred.SECT)
		for i in out.size():
			out[i] = d.decode_u32(Sacred.NAME + i * Sacred.CELL)
		return out


## world/static.pak -- 64-byte records, one per placed static object, indexed
## directly by WldxEntry +0x04. Record 0 is the null object.
##
##   +0x00 u32  self index (every record validates against its own index)
##   +0x04 u32  type id, 2872 distinct in 801..31936
##   +0x08 u32  flags, 9 distinct values
##   +0x0e i32  ox   <- NOT 4-byte aligned
##   +0x12 i32  oy   <- NOT 4-byte aligned
##
## ox/oy are absolute isometric SCREEN coordinates: ox = 48*(cx-cy),
## oy = 24*(cx+cy) plus a sub-cell offset. They, not the referencing cell, are
## the object's true position -- see IsoCamera's note on the 96x48 cell.
class Statics extends RefCounted:
	var _pak: Sacred.Pak

	func _init(pak: Sacred.Pak) -> void:
		_pak = pak

	func count() -> int:
		return _pak.count()

	## {type, flags, pos} for a static index, or an empty Dictionary if absent.
	func get_object(i: int) -> Dictionary:
		if i <= 0 or i >= _pak.count():
			return {}
		var r := _pak.blob(i)
		if r.size() < 64:
			return {}
		return {
			"type": r.decode_u32(4),
			"flags": r.decode_u32(8),
			# Godot's Y is up, Sacred's screen Y is down.
			"pos": Vector2(r.decode_s32(0x0e), -r.decode_s32(0x12)),
		}


## pak/mixed.pak -- the sprite table that static.pak's type id indexes.
##
##   header 16 B: u32 tile_count, u16 w, u16 h, i16 dx, i16 dy, u32 pad
##   then tile_count fixed 64-byte tiles; entry size is exactly 16 + 64*n.
##
## Tile: name[32] ("MIX233.444"), u32 texture.pak index @0x20,
##       u16 x1,y1,x0,y0 @0x24 (destination rect in sprite-local pixels),
##       f32 u0,v0,u1,v1 @0x30 (source rect in the texture).
##
## The tiles are NOT animation frames or facings -- they are pieces of ONE
## large sprite, packed across one or more atlases. A 195x341 object is
## assembled from 13 of them. Proof: every tile's destination rect is exactly
## the same size as its UV rect in pixels, and compositing them produces
## coherent objects (a crystal shrine, a boulder, a chair).
##
## 15840 of 32096 entries have zero tiles, including type 1037 -- the most
## common static type in the world. Those placements are invisible markers
## (collision, spawn, sound), not art.
class Mixed extends RefCounted:
	var _pak: Sacred.Pak

	func _init(pak: Sacred.Pak) -> void:
		_pak = pak

	func count() -> int:
		return _pak.count()

	## {size: Vector2i, anchor: Vector2i, tiles: Array[Dictionary]} or {} if the
	## entry has no art. Each tile is {tex: int, src: Rect2, dst: Rect2i}.
	func sprite(i: int) -> Dictionary:
		if i <= 0 or i >= _pak.count():
			return {}
		var r := _pak.blob(i)
		if r.size() < 16:
			return {}
		var n := r.decode_u32(0)
		if n <= 0 or r.size() < 16 + n * 64:
			return {}
		var tiles: Array[Dictionary] = []
		for j in n:
			var o := 16 + j * 64
			tiles.append({
				"tex": r.decode_u32(o + 0x20),
				"dst": Rect2i(r.decode_u16(o + 0x28), r.decode_u16(o + 0x2a),
					r.decode_u16(o + 0x24) - r.decode_u16(o + 0x28),
					r.decode_u16(o + 0x26) - r.decode_u16(o + 0x2a)),
				"src": Rect2(r.decode_float(o + 0x30), r.decode_float(o + 0x34),
					r.decode_float(o + 0x38) - r.decode_float(o + 0x30),
					r.decode_float(o + 0x3c) - r.decode_float(o + 0x34)),
			})
		return {
			"size": Vector2i(r.decode_u16(4), r.decode_u16(6)),
			"anchor": Vector2i(r.decode_s16(8), r.decode_s16(10)),
			"tiles": tiles,
		}


## Per-sector REGION table: building footprints with their own interior grids.
##
## Layout, immediately after the cell array (NAME + 64*64*32 = 131104):
##   36-byte records, ending at the first record whose type field is not 6.
##     +0x00 u32  region cell x   (absolute, inside the owning sector)
##     +0x04 u32  region cell y
##     +0x08 u16  w      +0x0a u16  h
##     +0x0c u32  type   (always 6; scanning for it returns exactly 2231 records
##                        world-wide, independently matching a coordinate-anchored
##                        count, which is what confirms the stride)
##     +0x10 u32  offset of this region's grid, relative to the DECOMPRESSED
##                STREAM -- not to the table, and not to the cell array
##     +0x14 u32  grid byte size, always exactly w*h*32
##     (remainder of the 36 bytes is zero padding)
##
## The grid is w*h cells of 32 bytes, of which only two are ever non-zero:
##   byte 31  cell class (see below)
##   byte 30  door attribute, only ever the value 4
##
## Class codes, counted over all 1870 grids in the world:
##   0x00 empty 143806   0xd1 wall 82866   0xd0 21064   0xe0 18580
##   0xd2 floor  16302   0xda step  2420   0xe2  1802   0xd9 door 566   0xe9 385
##
## Border cells are 87.3% wall (20305/23250). The door reading was a prediction
## made BEFORE measuring: if low-nibble 9 means door then byte 30 attaches to
## those classes and nowhere else. It does -- 0xe9 80.3%, 0xd9 30.9%, 0xd1 0.0%
## (3 of 82866), 0xd0 0.0% (4 of 21064).
##
## The 0xd_ and 0xe_ families share low nibbles and are believed to be storeys or
## an inside/outside split; sector 64,39 carries FOUR co-located 50x55 regions,
## matching the items.pak naming innenunten / innenmitte / innenoben.
##
## Why this exists: retail does a CUTAWAY, captured 2026-08-07 by driving the
## game with autopilot.so -- the roof CENTRE is removed while the tiled ring and
## the outer walls stay, it is instant with no blend, it fires while the player
## is still outside on the steps, and a whole complex swaps at once. A region
## gives the footprint, the wall ring and the door cell, which is what a trigger
## that behaves that way needs.
class Regions extends RefCounted:
	const TABLE_OFF := Sacred.NAME + Sacred.SECT * Sacred.SECT * Sacred.CELL
	const REC := 36
	const TYPE := 6

	## Cell classes. Only the low nibble is interpreted; the high nibble (0xd/0xe)
	## is an undecoded family split -- see the header.
	enum { EMPTY = 0, WALL = 1, FLOOR = 2, DOOR = 9, STEP = 0xa }

	var list: Array[Dictionary] = []   ## {cell: Vector2i, size: Vector2i, grid: PackedByteArray}

	func _init(stream: PackedByteArray, gx: int, gy: int) -> void:
		if stream.size() <= TABLE_OFF + REC:
			return
		var lo := Vector2i(gx, gy) * Sacred.SECT
		var p := TABLE_OFF
		while p + REC <= stream.size():
			if stream.decode_u32(p + 0x0c) != TYPE:
				break
			var cell := Vector2i(stream.decode_u32(p), stream.decode_u32(p + 0x04))
			var size := Vector2i(stream.decode_u16(p + 0x08), stream.decode_u16(p + 0x0a))
			var off := stream.decode_u32(p + 0x10)
			var bytes := stream.decode_u32(p + 0x14)
			# The first record is the sector origin marker (w = h = 0); skip it, and
			# reject anything whose size field disagrees with w*h*32 rather than
			# reading a mis-parsed offset as geometry.
			if size.x > 0 and size.y > 0 and bytes == size.x * size.y * Sacred.CELL \
					and off + bytes <= stream.size() \
					and Rect2i(lo, Vector2i(Sacred.SECT, Sacred.SECT)).has_point(cell):
				list.append({"cell": cell, "size": size,
					"grid": stream.slice(off, off + bytes)})
			p += REC

	## Class of one grid cell, as the low nibble of byte 31. Out of range -> EMPTY.
	static func cell_class(r: Dictionary, cx: int, cy: int) -> int:
		var size: Vector2i = r["size"]
		if cx < 0 or cy < 0 or cx >= size.x or cy >= size.y:
			return EMPTY
		var grid: PackedByteArray = r["grid"]
		var b := grid[(cy * size.x + cx) * Sacred.CELL + 31]
		return 0 if b == 0 else b & 0x0f


## pak/items.pak -- the object DEFINITION table, and the only place retail keeps
## the German authoring names ("DCTower innenunten 1A_1", "TH01 Wand innen 1_02").
##
##   "ITM" v5, 32768 uniform 128-byte records.
##   +0x10 u32  mixed.pak sprite id
##   +0x37      NUL-terminated name (ids 1..4 are SERAPHIM/GLADIATOR/MAGICIAN/DARKELVE.GRN)
##
## Why this class exists: Sacred does not fade roofs or depth-sort interiors
## against exteriors. It SWAPS the two sets -- from outside a house you see an
## unbroken roof and no interior at all, and from inside the roof and outer
## walls are gone entirely (manuals/Screenshots/sacred88.png and sacred86.png).
## Drawing both at once is what produced the "dark voids": unlit interior floors
## and walls painted over the roofs they belong under.
##
## The set is identified by NAME, which is why the whole items.pak chain matters:
##   static.pak type --indexes--> mixed.pak sprite   (209956/209956 verified)
##   items.pak +0x10 ------------> mixed.pak sprite
##   items.pak +0x37 ------------> authoring name
## so inverting +0x10 -> +0x37 gives sprite id -> name.
##
## Do NOT use the items.pak index as a mixed.pak index. That reading gives 70.2%
## art for the innen entries against a 77.6% baseline (worse than chance) and
## resolves every DCTower innen* entry to a zero-tile sprite. Reading the id from
## +0x10 instead hits 100.0% for innen against 82.0% overall.
class Items extends RefCounted:
	const SPRITE_OFF := 0x10
	const NAME_OFF := 0x37
	const REC_MIN := 0x40

	var _interior: Dictionary[int, bool] = {}   ## mixed.pak sprite id -> is interior art
	## mixed.pak sprite id -> bitmask of the building LEVELS this part belongs to.
	## Names run <BUILDING>_<level>_<part>, and the level token is either a digit
	## or a German "und" pair like 0U1 meaning the piece belongs to levels 0 AND 1
	## (a stair or a shared wall). Token frequencies over all 17408 named entries:
	## _1_ 455, _0_ 299, _2_ 249, _3_ 27, _4_ 17, _0U1_ 87, _0U2_ 63, _0U4_ 40.
	var _levels: Dictionary[int, int] = {}
	## mixed.pak sprite id -> true if this part sits on its BUILDING FAMILY's
	## highest level. Verified as the interior on two structurally different
	## buildings: BLACKSMITH (levels 0,1 -- hiding 0 opens the roof onto the
	## forge, anvil and barrel) and KLOSTER_KAPELLE01 (levels 0,1,2 -- hiding
	## 0,1 opens the roof onto the chapel floor and benches). Family is the name
	## up to the level token, so DCHOUSE01_FINAL_1_07 belongs to DCHOUSE01_FINAL.
	var _top: Dictionary[int, bool] = {}

	var _fam_top: Dictionary[String, int] = {}   ## family -> highest level seen
	var _fam_of: Dictionary[int, String] = {}    ## sprite -> family
	var _lvl_of: Dictionary[int, int] = {}       ## sprite -> its own level

	## mixed.pak sprite id -> an authoring name (RecordStore's name_of()).
	## HONEST AMBIGUITY: several items.pak records can carry the same +0x10
	## sprite id, so this stores the LAST one seen in file order, not "the"
	## name -- there is no guarantee a sprite has only one. The map is also
	## one-way: sprite -> a name, never name -> sprite.
	var _name: Dictionary[int, String] = {}

	func _init(pak: Sacred.Pak) -> void:
		var lv := RegEx.create_from_string("_(\\d)(?:U(\\d))?_\\d+$")
		for i in pak.count():
			var r := pak.blob(i)
			if r.size() < REC_MIN:
				continue
			var nm := r.slice(NAME_OFF).get_string_from_ascii()
			if nm != "":
				_name[r.decode_u32(SPRITE_OFF)] = nm
			var m := lv.search(nm)
			if m != null:
				var mask := 1 << int(m.get_string(1))
				var hi := int(m.get_string(1))
				if m.get_string(2) != "":
					mask |= 1 << int(m.get_string(2))
					hi = maxi(hi, int(m.get_string(2)))
				var sid := r.decode_u32(SPRITE_OFF)
				_levels[sid] = mask
				var f := nm.substr(0, m.get_start())
				_fam_top[f] = maxi(_fam_top.get(f, 0), hi)
				_fam_of[sid] = f
				_lvl_of[sid] = hi
			# containsn: case-insensitive. The data mixes "innen", "Innenwand" and
			# separated forms like "innen mitte", so a substring test is the rule --
			# not a prefix or an exact match.
			if nm.containsn("innen"):
				_interior[r.decode_u32(SPRITE_OFF)] = true

	func count() -> int:
		return _interior.size()

	## True if this mixed.pak sprite is building-interior art.
	func is_interior(sprite_id: int) -> bool:
		return _interior.has(sprite_id)

	## Bitmask of building levels this sprite belongs to, 0 if unnamed/unparsed.
	func levels(sprite_id: int) -> int:
		return _levels.get(sprite_id, 0)

	func level_count() -> int:
		return _levels.size()

	## True if this sprite is on its family's TOP level, i.e. the interior set.
	## Props (fences, flowers, market stalls) carry no level and return false --
	## correctly, since a fence has no storey, though it also means interior
	## props like an anvil or barrel are not caught by this and stay visible.
	func is_top_level(sprite_id: int) -> bool:
		if not _fam_of.has(sprite_id):
			return false
		return _lvl_of[sprite_id] == _fam_top[_fam_of[sprite_id]]

	## An authoring name for this mixed.pak sprite id, or "" if none was seen.
	## See _name's header for the one-way, last-wins ambiguity this carries.
	func name_of(sprite_id: int) -> String:
		return _name.get(sprite_id, "")


## texture.pak entry -> Image. Type 4 is ARGB4444.
##
## `render` picks how the 4-bit channels are resolved:
##   false -- expand nibbles to bytes (*17) into RGBA8 in GDScript. ~8.6 ms per
##            256x256 tile. Slow, but it is the path verify.gd diffs against the
##            Python decode, so it stays.
##   true  -- hand the raw 16-bit pixels to Godot as FORMAT_RGBA4444 and let the
##            engine expand them in C++ (298 us, 29x faster than the GDScript
##            loop), then generate mipmaps (55 us).
##
## Godot's FORMAT_RGBA4444 reads the u16 high-nibble-first as R,G,B,A while
## Sacred stores A,R,G,B, so the render path comes out rotated by one channel:
## the engine's R holds Sacred's alpha, G holds red, B green, A blue. That is
## not worth fixing on the CPU -- terrain.gdshader unswizzles it for free.
static func decode_texture(pak: Pak, id: int, render: bool = false) -> Image:
	var buf := pak.blob(id, 80)
	var w := buf.decode_u16(32)
	var h := buf.decode_u16(34)
	var kind := buf.decode_u8(36)
	if kind != 4:
		push_error("Sacred.decode_texture: id %d has unsupported type %d" % [id, kind])
		return null
	var px := inflate(buf.slice(80), w * h * 2)
	if px.size() != w * h * 2:
		push_error("Sacred.decode_texture: id %d inflated to %d, expected %d" % [id, px.size(), w * h * 2])
		return null
	if render:
		var img := Image.create_from_data(w, h, false, Image.FORMAT_RGBA4444, px)
		img.convert(Image.FORMAT_RGBA8)
		# ponytail: NO mipmaps -- see terrain.gdshader. Atlas slots are only 4 px
		# apart, so mip level 2 already averages across into the next diamond.
		return img
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, _argb4444_to_rgba8(px, w * h))


## Two 512-byte lookup tables turn each source byte into its two expanded
## channels, so the hot loop does table reads instead of shifts and multiplies.
static var _hi := PackedByteArray()   ## (a<<4)|r  ->  r, a
static var _lo := PackedByteArray()   ## (g<<4)|b  ->  g, b


static func _argb4444_to_rgba8(px: PackedByteArray, n: int) -> PackedByteArray:
	if _hi.is_empty():
		_hi.resize(512)
		_lo.resize(512)
		for b in 256:
			_hi[b * 2] = (b & 0xF) * 17          # r
			_hi[b * 2 + 1] = (b >> 4) * 17       # a
			_lo[b * 2] = (b >> 4) * 17           # g
			_lo[b * 2 + 1] = (b & 0xF) * 17      # b
	var out := PackedByteArray()
	out.resize(n * 4)
	for i in n:
		var lo := _lo[px[i * 2] * 2]
		var hi := px[i * 2 + 1] * 2
		var o := i * 4
		out[o] = _hi[hi]
		out[o + 1] = lo
		out[o + 2] = _lo[px[i * 2] * 2 + 1]
		out[o + 3] = _hi[hi + 1]
	return out


## pak/models.pak -- Granny 1.x tagged-chunk container. R1.1: two payload
## kinds share one index (64 mesh, 3421 65 motion), each with its own root-tag
## offset and its own truth about whether the index's third field is a byte
## length. Measured directly against install/pak/models.pak, not read from
## Iris1 (GPL) or the statically-linked Granny runtime -- every offset and
## chunk size below is byte evidence recorded in
## .planning/phases/03-granny-grn-tag-walk-then-posed-mesh/03-RESEARCH.md.
##
## This class emits (tag, offset, length) triples only -- no field
## interpretation. Mesh/skeleton decode is a later plan's job.
class Models extends RefCounted:
	## High 16 bits of every documented tag; also the root chunk's own value.
	const MAGIC := 0xCA5E0000
	const TERMINATOR := 0xCA5EFFFF
	const KIND_MESH := 64
	const KIND_MOTION := 65
	## kind==64 (mesh) ONLY. Do not generalise -- kind==65 (motion, R1.5) puts
	## the root tag at MAGIC_OFF_MOTION instead, confirmed on the full corpus
	## for kind==64 and a 25-entry sample for kind==65 (03-RESEARCH.md
	## "Magic offset is kind-dependent").
	const MAGIC_OFF_MESH := 0x4EA
	const MAGIC_OFF_MOTION := 0x140   ## not used this phase; recorded so R1.5 doesn't re-derive it.
	const NAME_LEN := 64
	## Fixed sizes (tag included) for the tags this phase can walk. The header
	## chain only, for now -- Plan 01 Task 2 and Plan 02 extend this with the
	## fixed 12-byte leaf families research documented.
	##
	## object and final are 20/36, NOT the 16/32 03-RESEARCH.md prose states --
	## corrected against a direct hex census of GLADIATOR.GRN (pak index 589):
	## root@1258 (32) -> copyright@1290 (20) -> object@1310 (20, ends 1330,
	## not 1326) -> final@1330 (36, ends 1366 where the first leaf tag
	## 0xCA5E0200 begins). Sized 16/32 stopped `walk()` after 3 tags: it read
	## the final tag's own offset (1326) as reserved/zero padding one field
	## short of where 0xCA5E0101 actually starts.
	const TAG_SIZES := {
		MAGIC: 32,          # 0xCA5E0000 root
		0xCA5E0102: 20,     # copyright
		0xCA5E0103: 20,     # object
		0xCA5E0101: 36,     # final
		# Fixed 12-byte leaf families (4-byte tag + 8-byte payload), confirmed
		# by hex walk (03-RESEARCH.md "Chunk stream structure"): delta to the
		# next tag is exactly 12 for every one of these, no exceptions seen.
		0xCA5E0200: 12,
		0xCA5E1000: 12,
		0xCA5E1001: 12,
		0xCA5E1002: 12,
		0xCA5E1003: 12,
		0xCA5E0F00: 12,
		0xCA5E0F01: 12,
		0xCA5E0F02: 12,
		0xCA5E0F03: 12,
		0xCA5E0F04: 12,
		0xCA5E0F05: 12,
		0xCA5E0F06: 12,
	}
	## Hard cap on triples emitted per entry (all objects combined). Research
	## counted 537 repetitions of the 0F01/0F02/0F06 family alone in
	## GLADIATOR.GRN's single object; sized generously above that so a
	## multi-object file has headroom without the cap ever being the reason
	## a well-formed entry's walk is cut short.
	const WALK_BUDGET := 4096
	## Byte offset, from an object's 0xCA5E0000 root chunk start, of the H1
	## candidate object-byte-length field. 03-RESEARCH.md's prose calls this
	## field "+0x14"; a raw census (03-01-SUMMARY.md, this task) found it one
	## u32 word earlier, at +0x10 -- root_off + 0x14 reads 0 in every sample
	## checked, while root_off + 0x10 exactly equals true_length(entry) -
	## magic_offset(entry) for BAT.GRN, GLAD_SA5_SHOULDER.GRN and GLADIATOR.GRN.
	const H1_LEN_OFF := 0x10

	var _pak: Sacred.Pak

	func _init(pak: Sacred.Pak) -> void:
		_pak = pak

	func count() -> int:
		return _pak.count()

	## Bounds-checked read of the entry's stored kind (64 mesh, 65 motion).
	## -1 for an out-of-range index.
	func kind_of(entry: int) -> int:
		if entry < 0 or entry >= _pak.count():
			return -1
		return _pak.kinds[entry]

	## MAGIC_OFF_MESH for kind==64, MAGIC_OFF_MOTION for kind==65, -1
	## otherwise. Never a single unqualified constant -- see MAGIC_OFF_MESH.
	func magic_offset(entry: int) -> int:
		var kind := kind_of(entry)
		if kind == KIND_MESH:
			return MAGIC_OFF_MESH
		if kind == KIND_MOTION:
			return MAGIC_OFF_MOTION
		return -1

	## True on-disk length, derived from the gap to the next entry's offset
	## (or to end of file, for the last entry). NEVER _pak.sizes[entry]: index
	## field 3 averages 1.95x the true gap for kind==64 (03-RESEARCH.md
	## "Index field 3 is not a byte length for kind=64, and IS one for
	## kind=65") -- this method does not even branch on kind, because the
	## rule ("derive from offsets, not from the index") is uniform; only the
	## RATIO to field3 differs by kind, and this method never reads field3.
	## Returns 0 for an out-of-range index or a non-positive derived length.
	func true_length(entry: int) -> int:
		if entry < 0 or entry >= _pak.count():
			return 0
		var length: int
		if entry + 1 < _pak.count():
			length = _pak.entry_offset(entry + 1) - _pak.entry_offset(entry)
		else:
			length = _pak.file_size() - _pak.entry_offset(entry)
		if length <= 0:
			push_error("Sacred.Models: entry %d has non-positive derived length %d" % [entry, length])
			return 0
		return length

	## First NAME_LEN bytes of the entry, truncated at the first NUL and
	## decoded as ASCII. A byte at or above 0x80, or NAME_LEN bytes with no
	## NUL, is returned as-is -- get_string_from_ascii() maps each byte to its
	## own code point, it does not substitute U+FFFD, so no silent
	## normalisation happens here.
	func entry_name(entry: int) -> String:
		if entry < 0 or entry >= _pak.count():
			return ""
		var length := true_length(entry)
		if length <= 0:
			return ""
		var r := _pak.read_at(_pak.entry_offset(entry), mini(NAME_LEN, length))
		var nul := r.find(0)
		if nul == -1:
			return r.get_string_from_ascii()
		return r.slice(0, nul).get_string_from_ascii()

	## The single exclusion predicate for the whole phase: false when this
	## entry has no kind-scoped magic offset, is too short to reach it, or
	## the u32 there is not MAGIC. INVALID_MODEL (index 0) and INVALID_MOTION
	## (index 1572) are rejected by this same check, not by an index list or
	## a size cutoff (03-RESEARCH.md Pitfall 9 -- the exclusion set must fall
	## out of the walker's own logic, never be hardcoded).
	func magic_ok(entry: int) -> bool:
		var off := magic_offset(entry)
		if off == -1:
			return false
		var length := true_length(entry)
		if length < off + 4:
			return false
		var r := _pak.read_at(_pak.entry_offset(entry) + off, 4)
		if r.size() < 4:
			return false
		return r.decode_u32(0) == MAGIC

	## Populated by the most recent walk() call: {h1_confirmed: bool,
	## objects: int, h1_bytes: int, object_lengths: Array[int], consumed: int,
	## stop_reason: String, stop_tag: int, stop_off: int}. object_lengths
	## holds each object's own H1-declared byte length, in emission order --
	## the per-model-varying declared fact grnwalk.gd folds into the triples
	## md5 so entries with an identical tag-structure prefix still hash
	## differently (03-01-SUMMARY.md, Task 2, discrimination requirement).
	## Single-threaded use only -- Models carries no concurrency contract, so
	## do not call walk() for two entries concurrently and expect both
	## results to be held at once.
	var last_walk_meta: Dictionary = {}

	## (tag, offset, length) triples across every top-level object in the
	## entry, entry-relative offsets, advancing strictly by each tag's
	## declared size from TAG_SIZES -- never by scanning for the next
	## tag-shaped byte pattern. Empty for an entry that fails magic_ok().
	##
	## Within one object, the inner walk stops on the terminator, on a tag
	## absent from TAG_SIZES (recorded in last_walk_meta as
	## stop_reason=unknown-tag with stop_tag/stop_off), on a read that would
	## pass the buffer end, or on WALK_BUDGET.
	##
	## H1 (stated before measuring, 03-01-PLAN.md Task 2): the u32 at +0x14
	## inside an object's 0xCA5E0000 root chunk is that object's byte length,
	## measured from the root chunk's own start.
	## [Corrected during Task 2 execution] 03-RESEARCH.md's "+0x14" is one u32
	## word off: a raw census of the root chunk's own bytes (see 03-01-SUMMARY.md)
	## found the size-like field at root_off + 0x10, not root_off + 0x14 (which
	## reads 0 in every sample). Confirmed against three independent entries by
	## checking true_length(entry) - magic_offset(entry): BAT.GRN 35220, GLAD_SA5_
	## SHOULDER.GRN 38188, GLADIATOR.GRN 185584 -- each an exact match to the u32
	## at root_off + 0x10 and nowhere else in the root chunk. The code below uses
	## the measured offset (+0x10); the doc comment keeps "+0x14" in its own name
	## only because that is what H1's hypothesis statement (and the plan text) call
	## it -- the constant itself is not re-literal'd, see H1_LEN_OFF below.
	## On a clean terminator this
	## is tested by jumping root_off + h1_len and checking whether MAGIC
	## lands there (another object follows, so the walk continues into it)
	## or the jump lands exactly on true_length(entry) (this was the last
	## object, and the whole entry is now accounted for). Either outcome
	## keeps last_walk_meta.h1_confirmed true; any other outcome -- the
	## predicted position is neither the next object's root nor the entry's
	## end -- refutes H1 for this entry and stops rather than guessing a
	## replacement length.
	func walk(entry: int) -> Array[Dictionary]:
		var triples: Array[Dictionary] = []
		var object_lengths: Array[int] = []
		last_walk_meta = {
			"h1_confirmed": false, "objects": 0, "h1_bytes": 0,
			"object_lengths": object_lengths, "consumed": 0,
			"stop_reason": "", "stop_tag": 0, "stop_off": 0,
		}
		if not magic_ok(entry):
			return triples
		var length := true_length(entry)
		var buf := _pak.read_at(_pak.entry_offset(entry), length)
		var pos := magic_offset(entry)
		last_walk_meta["consumed"] = pos
		var objects := 0
		var h1_total := 0
		var confirmed := true
		while pos + 4 <= buf.size() and buf.decode_u32(pos) == MAGIC:
			var root_off := pos
			var h1_len := 0
			if root_off + H1_LEN_OFF + 4 <= buf.size():
				h1_len = buf.decode_u32(root_off + H1_LEN_OFF)
			var terminated := false
			while pos + 4 <= buf.size():
				if triples.size() >= WALK_BUDGET:
					last_walk_meta["stop_reason"] = "budget"
					confirmed = false
					break
				var tag := buf.decode_u32(pos)
				if tag == TERMINATOR:
					terminated = true
					break
				if not TAG_SIZES.has(tag):
					last_walk_meta["stop_reason"] = "unknown-tag"
					last_walk_meta["stop_tag"] = tag
					last_walk_meta["stop_off"] = pos
					confirmed = false
					push_error("Sacred.Models: entry %d unknown tag 0x%08x at offset %d" % [entry, tag, pos])
					break
				var size: int = TAG_SIZES[tag]
				if pos + size > buf.size():
					last_walk_meta["stop_reason"] = "truncated"
					confirmed = false
					break
				triples.append({"tag": tag, "off": pos, "len": size})
				pos += size
			if not terminated:
				last_walk_meta["consumed"] = pos
				break
			objects += 1
			h1_total += h1_len
			object_lengths.append(h1_len)
			var predicted := root_off + h1_len
			if predicted == length:
				last_walk_meta["consumed"] = predicted
				last_walk_meta["stop_reason"] = "end-of-entry"
				break
			if predicted + 4 <= buf.size() and buf.decode_u32(predicted) == MAGIC:
				pos = predicted
				last_walk_meta["consumed"] = predicted
				continue
			confirmed = false
			last_walk_meta["stop_reason"] = "h1-mismatch"
			last_walk_meta["stop_off"] = predicted
			last_walk_meta["consumed"] = pos  # last verified position; the failed guess is not counted as consumed
			break
		last_walk_meta["h1_confirmed"] = confirmed and objects > 0
		last_walk_meta["objects"] = objects
		last_walk_meta["h1_bytes"] = h1_total
		return triples

	# ---------------------------------------------------------------------
	# Geometry decode (Plan 05).
	#
	# CORRECTION to every earlier document that calls the post-terminator
	# region "the untagged bulk region": it is not untagged. It opens with a
	# flat node directory, and every node carries a 0xCA5E____ tag -- the same
	# tag space the chunk stream uses. Nothing below scans for a byte pattern;
	# geometry is found by tag through that directory.
	#
	#   SECTION_OFF_MESH + 0                    u32 numNodes
	#   SECTION_OFF_MESH + DIR_OFF + j*12       {u32 tag, u32 rel, u32 children}
	#   a node's payload starts at SECTION_OFF_MESH + rel
	#
	# SECTION_OFF_MESH was solved against the oracle
	# (analysis/tools/granny_oracle -> granny2 2.7.0.30, which reports each GR2
	# mesh's first vertex), not guessed. For GLADIATOR.GRN the oracle's three
	# first-vertex float triples -- (0.913,-0.150,68.470), (-0.916,2.864,69.745)
	# and (-4.380,-0.136,38.286) -- each occur exactly ONCE in the entry's
	# 186842 bytes, at 22066, 99622 and 124734. The three MeshVertices nodes
	# declare rel 20432, 97988 and 123100. The differences are 1634, 1634 and
	# 1634: one base, three independent confirmations, on a test that could
	# have disagreed three ways and did not.
	#
	# Two index spaces, one Godot index space. A MeshTriangles record is 24
	# bytes of six int32 {a,b,c, na,nb,nc}: three POSITION indices then three
	# NORMAL indices. Godot's add_surface_from_arrays takes a single index
	# space, so mesh_arrays() de-interleaves -- each distinct (position,normal)
	# pair becomes one Godot vertex. Face counts are not stored in the node;
	# they are derived from the gap to the next node with a strictly larger
	# rel, and that derivation is what the oracle check below validates.
	const SECTION_OFF_MESH := 1634
	## Byte offset of the directory from SECTION_OFF_MESH; numNodes is the u32
	## at SECTION_OFF_MESH + 0.
	const DIR_OFF := 16
	const NODE_STRIDE := 12
	## Ceiling on the declared node count, applied before the count is used to
	## size anything -- the same posture Mixed.sprite() takes with its declared
	## tile count. GLADIATOR.GRN, the largest entry sampled, declares 1271.
	const MAX_NODES := 1 << 20
	const TAG_MESH := 0xCA5E0601
	const TAG_MESH_VERTICES := 0xCA5E0801
	const TAG_MESH_NORMALS := 0xCA5E0802
	const TAG_MESH_TRIANGLES := 0xCA5E0901
	## MeshField holds one vertex-attribute channel: a u32 component count
	## (measured = 3 for every field in GLADIATOR.GRN) then that many float32
	## per entry. Texture coordinates are the first two components.
	const TAG_MESH_FIELD := 0xCA5E0803
	## Root of the RenderPass tree, which is where the per-CORNER UV indices
	## live. They are NOT in the face record: that carries position and normal
	## indices only, which is why a UV split cannot be derived from faces alone.
	const TAG_FORM_MESH := 0xCA5E0C03
	const TAG_MODEL_SECTION := 0xCA5E0E01
	## 3x float32 per position and per normal; 6x int32 per face.
	const VEC3_STRIDE := 12
	const TRI_STRIDE := 24
	## Bytes per MeshField entry (3x float32) and per RenderPass face-UV record
	## ({int32 faceIndex, int32 uvA, int32 uvB, int32 uvC}). Each MeshField also
	## carries a 4-byte component-count header ahead of its entries.
	const UV_FIELD_STRIDE := 12
	const UV_FIELD_HEADER := 4
	const UV_RECORD_STRIDE := 16
	## Granny-stored axes to Godot's. Columns are the images of the stored basis
	## vectors: x -> +X, y -> -Z, z -> +Y. Determinant +1, so no mirroring.
	## See coordinate_basis() for how this was derived from per-mesh bounding
	## boxes rather than picked to make the render look upright.
	const GRN_TO_GODOT := Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0))

	## Set by the most recent coordinate_basis() call: true when the basis has
	## been established with confidence, NOT when it was found as literal bytes.
	##
	## The original meaning was the literal one -- "nine consecutive orthonormal
	## float32 were found in the file" -- and it was always false, because an
	## exhaustive scan of the header and node directory returns zero hits: this
	## format does not store its basis. Plan 06 replaced the scan with a basis
	## DERIVED from measured per-mesh bounding boxes and corroborated against two
	## independent oracles to four decimals (findings row 495), and redefined
	## `located` accordingly. Consumers printing `basis=located` are asserting
	## "derived and corroborated", not "read from the file".
	##
	## Single-threaded use only, exactly like last_walk_meta.
	var last_basis_located := false

	## First entry whose name matches, comparing case-insensitively and adding
	## the .GRN suffix when the caller omitted it; -1 when nothing matches.
	## This is the ONLY way a caller-supplied model name is resolved: the string
	## is compared against the pak's own 64-byte name fields and never joined
	## into a path or handed to FileAccess, so an operator-supplied name cannot
	## reach the filesystem.
	func index_of(name: String) -> int:
		var want := name.strip_edges().to_upper()
		if want == "":
			return -1
		if not want.ends_with(".GRN"):
			want += ".GRN"
		for i in _pak.count():
			if entry_name(i).to_upper() == want:
				return i
		return -1

	## Flat node directory of one entry, or [] when the declared count or the
	## implied directory extent does not fit the entry's real bytes. Every node
	## must carry a 0xCA5E____ tag; one that does not means this is not a
	## directory and the whole read is abandoned rather than partially trusted.
	func _directory(buf: PackedByteArray) -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		if buf.size() < SECTION_OFF_MESH + DIR_OFF + NODE_STRIDE:
			return out
		var n := buf.decode_u32(SECTION_OFF_MESH)
		if n <= 0 or n > MAX_NODES:
			return out
		var dir_off := SECTION_OFF_MESH + DIR_OFF
		if dir_off + n * NODE_STRIDE > buf.size():
			return out
		for j in n:
			var o := dir_off + j * NODE_STRIDE
			var tag := buf.decode_u32(o)
			if (tag & 0xFFFF0000) != MAGIC:
				return []
			out.append({"tag": tag, "rel": buf.decode_u32(o + 4), "children": buf.decode_u32(o + 8)})
		return out

	## Payload byte length of node j: the gap to the next node with a strictly
	## larger rel, or to the end of the section for the last one. Nodes that
	## share a rel (a Mesh and its first child both point at the same bytes)
	## are skipped rather than yielding a zero-length span.
	func _span(dir: Array[Dictionary], j: int, buf_size: int) -> int:
		var r: int = dir[j]["rel"]
		for k in range(j + 1, dir.size()):
			var nr: int = dir[k]["rel"]
			if nr > r:
				return nr - r
		return buf_size - SECTION_OFF_MESH - r

	## DIRECT children of node j -- one level only. _child_with_tag() searches
	## the whole subtree, which is right for finding a uniquely-tagged array but
	## wrong for walking ModelSection > Model > RenderPassSection > RenderPass,
	## where the same tag recurs at several depths. "children" is the count of
	## ALL descendants, so a direct child is reached by skipping the previous
	## child's entire subtree.
	func _direct_children(dir: Array[Dictionary], j: int) -> Array[int]:
		var out: Array[int] = []
		var last: int = mini(j + 1 + int(dir[j]["children"]), dir.size())
		var k := j + 1
		while k < last:
			out.append(k)
			k += 1 + int(dir[k]["children"])
		return out

	## First child of node j (exclusive of j itself, within its declared
	## children run) carrying `tag`, or -1.
	func _child_with_tag(dir: Array[Dictionary], j: int, tag: int) -> int:
		var last: int = mini(j + 1 + int(dir[j]["children"]), dir.size())
		for k in range(j + 1, last):
			if dir[k]["tag"] == tag:
				return k
		return -1

	## Typed arrays for every Mesh in the entry, concatenated into one surface:
	##   positions PackedVector3Array, normals PackedVector3Array,
	##   uvs PackedVector2Array, indices PackedInt32Array,
	##   vertex_count, triangle_count, index_max, meshes,
	##   source_positions, source_normals  (the two GRN index spaces' sizes)
	## Empty Dictionary plus push_error on any malformed input.
	##
	## Every declared count is re-validated against the entry's real remaining
	## bytes before it sizes an array or indexes into the buffer, and every
	## triangle index is checked against the array it indexes before use --
	## an index at or above its array's count aborts the whole decode instead
	## of being clamped, because a clamped index renders a quietly wrong mesh
	## and this phase exists to be able to see wrongness.
	##
	## uvs is currently always empty: the per-vertex texture coordinates have
	## not been located in the file yet (see 03-05-SUMMARY.md "Known Stubs").
	## Returning an empty array is deliberate -- inventing a UV layout that
	## merely looked plausible would defeat the oracle check.
	## Per-mesh UV entry byte offsets, from every MeshField in the mesh subtree
	## concatenated in directory order. A mesh may carry more than one field
	## (GLADIATOR mesh 0 carries two, 2322 + 896 entries), and the RenderPass
	## indices address that concatenation, so they are NOT read independently.
	func _uv_field_offsets(buf: PackedByteArray, dir: Array[Dictionary], j: int) -> Array[int]:
		var out: Array[int] = []
		var last: int = mini(j + 1 + int(dir[j]["children"]), dir.size())
		for k in range(j + 1, last):
			if dir[k]["tag"] != TAG_MESH_FIELD:
				continue
			var off := SECTION_OFF_MESH + int(dir[k]["rel"])
			var n := (_span(dir, k, buf.size()) - UV_FIELD_HEADER) / UV_FIELD_STRIDE
			if n <= 0 or off + UV_FIELD_HEADER + n * UV_FIELD_STRIDE > buf.size():
				continue
			for i in n:
				out.append(off + UV_FIELD_HEADER + i * UV_FIELD_STRIDE)
		return out

	## face_uv[mesh][face] = PackedInt32Array([uvA, uvB, uvC]), or an empty array
	## for a face no RenderPass claimed. Walks
	## ModelSection > Model > RenderPassSection > RenderPass, whose leaf child
	## holds {int32 count} then count x {int32 faceIndex, int32 uvA/B/C}.
	##
	## A RenderPass names a FormMesh SLOT, not a mesh: its first int32 indexes
	## the FormMesh list, whose own first int32 is a 1-based mesh ordinal. The
	## two are joined through that map rather than assumed equal, because for
	## GLADIATOR they are not -- the map is [2, 0, 1].
	func _face_uv_indices(buf: PackedByteArray, dir: Array[Dictionary], face_counts: Array[int]) -> Array:
		var face_uv := []
		for n in face_counts:
			var per_mesh := []
			per_mesh.resize(n)
			face_uv.append(per_mesh)
		var form_map: Array[int] = []
		for j in dir.size():
			if dir[j]["tag"] != TAG_FORM_MESH:
				continue
			var o := SECTION_OFF_MESH + int(dir[j]["rel"])
			form_map.append(-1 if o + 4 > buf.size() else buf.decode_s32(o) - 1)
		for j in dir.size():
			if dir[j]["tag"] != TAG_MODEL_SECTION:
				continue
			for model in _direct_children(dir, j):
				for pass_sec in _direct_children(dir, model):
					for rp in _direct_children(dir, pass_sec):
						var ro := SECTION_OFF_MESH + int(dir[rp]["rel"])
						if ro + 4 > buf.size():
							continue
						var slot := buf.decode_s32(ro)
						if slot < 0 or slot >= form_map.size():
							continue
						var mi := form_map[slot]
						if mi < 0 or mi >= face_counts.size():
							continue
						for leaf in _direct_children(dir, rp):
							if int(dir[leaf]["children"]) > 0:
								continue
							var off := SECTION_OFF_MESH + int(dir[leaf]["rel"])
							if off + 4 > buf.size():
								continue
							var count := buf.decode_s32(off)
							# A block claiming more faces than the mesh has is not
							# a face-UV block; skipping beats trusting it.
							if count <= 0 or count > face_counts[mi]:
								continue
							if off + 4 + count * UV_RECORD_STRIDE > buf.size():
								continue
							for i in count:
								var r := off + 4 + i * UV_RECORD_STRIDE
								var fi := buf.decode_s32(r)
								if fi < 0 or fi >= face_counts[mi]:
									continue
								face_uv[mi][fi] = PackedInt32Array([
									buf.decode_s32(r + 4), buf.decode_s32(r + 8), buf.decode_s32(r + 12)])
		return face_uv

	func mesh_arrays(entry: int) -> Dictionary:
		var length := true_length(entry)
		if length <= 0:
			push_error("Sacred.Models.mesh_arrays: entry %d has no derivable length" % entry)
			return {}
		if not magic_ok(entry):
			push_error("Sacred.Models.mesh_arrays: entry %d is not a walkable mesh entry" % entry)
			return {}
		var buf := _pak.read_at(_pak.entry_offset(entry), length)
		if buf.size() < length:
			push_error("Sacred.Models.mesh_arrays: entry %d short read (%d of %d)" % [entry, buf.size(), length])
			return {}
		var dir := _directory(buf)
		if dir.is_empty():
			push_error("Sacred.Models.mesh_arrays: entry %d has no readable node directory" % entry)
			return {}

		var positions := PackedVector3Array()
		var normals := PackedVector3Array()
		var uvs := PackedVector2Array()
		var indices := PackedInt32Array()
		# Per Godot vertex, which source position it came from and which Mesh
		# node produced it. mesh_weights() keys its per-vertex weight records on
		# the SOURCE position index, and each Mesh node has its own mesh-local
		# bone index space, so a skinned build needs both to route a weight to a
		# Godot vertex. They are emitted here, in the de-interleave loop that
		# already knows the answer, rather than reconstructed by a second walk
		# that could disagree with this one.
		var vertex_source := PackedInt32Array()
		var vertex_mesh := PackedInt32Array()
		var meshes := 0
		var src_pos := 0
		var src_nrm := 0
		var index_max := -1
		var uv_complete := true

		# Two passes. The RenderPass tree addresses meshes by ordinal, so the
		# ordinals have to exist before any UV can be resolved -- which means
		# the mesh list is settled first, using exactly the same accept/reject
		# test the de-interleave below uses, so the two orderings cannot drift.
		var mesh_nodes: Array[int] = []
		var face_counts: Array[int] = []
		for j in dir.size():
			if dir[j]["tag"] != TAG_MESH:
				continue
			var tj0 := _child_with_tag(dir, j, TAG_MESH_TRIANGLES)
			if _child_with_tag(dir, j, TAG_MESH_VERTICES) == -1 \
					or _child_with_tag(dir, j, TAG_MESH_NORMALS) == -1 or tj0 == -1:
				continue
			mesh_nodes.append(j)
			face_counts.append(maxi(0, _span(dir, tj0, buf.size()) / TRI_STRIDE))
		var face_uv := _face_uv_indices(buf, dir, face_counts)

		for mo in mesh_nodes.size():
			var j := mesh_nodes[mo]
			var uv_offsets := _uv_field_offsets(buf, dir, j)
			var vj := _child_with_tag(dir, j, TAG_MESH_VERTICES)
			var nj := _child_with_tag(dir, j, TAG_MESH_NORMALS)
			var tj := _child_with_tag(dir, j, TAG_MESH_TRIANGLES)
			if vj == -1 or nj == -1 or tj == -1:
				continue

			var v_off := SECTION_OFF_MESH + int(dir[vj]["rel"])
			var n_off := SECTION_OFF_MESH + int(dir[nj]["rel"])
			var t_off := SECTION_OFF_MESH + int(dir[tj]["rel"])
			var v_len := _span(dir, vj, buf.size())
			var n_len := _span(dir, nj, buf.size())
			var t_len := _span(dir, tj, buf.size())
			if v_len <= 0 or n_len <= 0 or t_len <= 0:
				push_error("Sacred.Models.mesh_arrays: entry %d mesh at node %d has a non-positive span" % [entry, j])
				return {}
			# A span that is not a whole number of records means the stride is
			# wrong or the span was mis-derived. Integer division would drop the
			# remainder and hand back a truncated-but-plausible mesh -- exactly the
			# quietly-wrong result this decoder refuses everywhere else.
			# mesh_weights() already demands zero slack for the structurally
			# identical case; demand it here too.
			if v_len % VEC3_STRIDE != 0 or n_len % VEC3_STRIDE != 0 \
					or t_len % TRI_STRIDE != 0:
				push_error("Sacred.Models.mesh_arrays: entry %d mesh at node %d has a misaligned span (v=%d n=%d t=%d against strides %d/%d/%d)" % [
					entry, j, v_len, n_len, t_len, VEC3_STRIDE, VEC3_STRIDE, TRI_STRIDE])
				return {}
			var n_pos := v_len / VEC3_STRIDE
			var n_nrm := n_len / VEC3_STRIDE
			var n_face := t_len / TRI_STRIDE
			if n_pos <= 0 or n_nrm <= 0 or n_face <= 0:
				push_error("Sacred.Models.mesh_arrays: entry %d mesh at node %d resolves to zero geometry" % [entry, j])
				return {}
			# Declared extents re-checked against the buffer that actually exists.
			if v_off < 0 or v_off + n_pos * VEC3_STRIDE > buf.size() \
					or n_off < 0 or n_off + n_nrm * VEC3_STRIDE > buf.size() \
					or t_off < 0 or t_off + n_face * TRI_STRIDE > buf.size():
				push_error("Sacred.Models.mesh_arrays: entry %d mesh at node %d runs past the entry" % [entry, j])
				return {}

			# De-interleave the three GRN index spaces into Godot's one.
			#
			# The key is the position INDEX plus the normal and UV BIT PATTERNS.
			# Index-space keying was measured and is wrong: it splits far too
			# much (3755 vertices against granny's 1196) because the normal and
			# UV arrays store the same value at many indices. Welding those two
			# by value reproduces granny per mesh (609 and 307 exactly, 279
			# against 280 on the head). Position stays keyed by INDEX, not by
			# value, so that two vertices that merely sit at the same point are
			# never merged -- their bone weights are keyed on the position index
			# and need not agree. Measured to cost nothing here: both keys give
			# 609/279/307.
			var tuple_to_vertex := {}
			for fi in n_face:
				var ro := t_off + fi * TRI_STRIDE
				var fuv: PackedInt32Array = face_uv[mo][fi] if face_uv[mo][fi] != null else PackedInt32Array()
				for corner in 3:
					var p := buf.decode_s32(ro + corner * 4)
					var q := buf.decode_s32(ro + 12 + corner * 4)
					if p < 0 or p >= n_pos or q < 0 or q >= n_nrm:
						push_error("Sacred.Models.mesh_arrays: entry %d face %d references position %d of %d / normal %d of %d" % [entry, fi, p, n_pos, q, n_nrm])
						return {}
					var no := n_off + q * VEC3_STRIDE
					# -1 marks "this corner has no UV". It is a distinct key
					# value, so an unclaimed corner never silently welds onto a
					# textured one; it also trips uv_complete, which suppresses
					# the whole UV array rather than shipping a zero-filled one.
					var uo := -1
					if fuv.size() == 3 and fuv[corner] >= 0 and fuv[corner] < uv_offsets.size():
						uo = uv_offsets[fuv[corner]]
					else:
						uv_complete = false
					var key := "%d|%d,%d,%d|%d,%d" % [
						p, buf.decode_u32(no), buf.decode_u32(no + 4), buf.decode_u32(no + 8),
						-1 if uo < 0 else buf.decode_u32(uo),
						-1 if uo < 0 else buf.decode_u32(uo + 4)]
					var vi: int = tuple_to_vertex.get(key, -1)
					if vi == -1:
						vi = positions.size()
						tuple_to_vertex[key] = vi
						var po := v_off + p * VEC3_STRIDE
						positions.append(Vector3(buf.decode_float(po), buf.decode_float(po + 4), buf.decode_float(po + 8)))
						normals.append(Vector3(buf.decode_float(no), buf.decode_float(no + 4), buf.decode_float(no + 8)))
						uvs.append(Vector2(0.0, 0.0) if uo < 0 else Vector2(buf.decode_float(uo), buf.decode_float(uo + 4)))
						vertex_source.append(p)
						vertex_mesh.append(meshes)
					indices.append(vi)
					index_max = maxi(index_max, vi)
			meshes += 1
			src_pos += n_pos
			src_nrm += n_nrm

		if meshes == 0 or positions.is_empty() or indices.is_empty():
			push_error("Sacred.Models.mesh_arrays: entry %d contains no decodable mesh" % entry)
			return {}
		# All-or-nothing: a partly-resolved UV array is worse than none, because
		# the zero-filled corners would texture as a smear that still looks like
		# geometry. Callers test uvs.is_empty().
		if not uv_complete:
			uvs = PackedVector2Array()
		return {
			"positions": positions, "normals": normals, "uvs": uvs, "indices": indices,
			"vertex_count": positions.size(), "triangle_count": indices.size() / 3,
			"index_max": index_max, "meshes": meshes,
			"source_positions": src_pos, "source_normals": src_nrm,
			"vertex_source": vertex_source, "vertex_mesh": vertex_mesh,
		}

	## The one matrix converting Granny's stored coordinate system to Godot's.
	##
	## DERIVED FROM MEASUREMENT, not chosen because the render improved. An
	## earlier revision scanned the header and node directory for nine
	## consecutive orthonormal float32 and found ZERO hits, so the file does not
	## carry the matrix as data and it has to be established from the geometry.
	##
	## Derivation. An external render of GLADIATOR.GRN reports per-mesh bounding
	## boxes that climb foot-to-crown along ITS up axis: legs [-4.0335, 44.1928],
	## body [32.3761, 71.5712], head [61.9141, 77.8393], feet at ~0. Computing
	## the same three boxes from OUR decode reproduces those intervals on our
	## STORED COMPONENT 2 (legs [-4.03, 44.20], body [32.38, 71.58], head
	## [61.91, 77.84]) and on neither other component. So stored component 2 is
	## up, and the mapping is (X, Y, Z) = (x, z, y).
	##
	## That mapping alone is a reflection (determinant -1), which would silently
	## mirror the model. The determinant +1 member of the pair is the -90 degree
	## rotation about X, (x, y, z) -> (x, z, -y), and it is the one used, because
	## a retail asset is not stored mirrored. Handedness is NOT claimed as
	## verified: the shoulder-pad oracle that was meant to settle it is its own
	## Y-mirror and therefore cannot fail, so it settles nothing. What remains
	## unfixed by the bbox evidence is one rotation about the up axis -- the
	## facing direction. That is a separate question from handedness.
	func coordinate_basis(_entry: int) -> Basis:
		last_basis_located = true
		return GRN_TO_GODOT

	# ---------------------------------------------------------------------
	# Skeleton decode (Plan 06).
	#
	# Found through the SAME flat node directory the geometry uses -- nothing
	# below scans for a byte pattern:
	#
	#   0xCA5E0507 SkeletonSection   numTotalChildren = bones + 2
	#   0xCA5E0508 BoneSection       numTotalChildren = bone count, EXACTLY
	#   0xCA5E0506 Bone              one node per bone, 68 bytes, rel step 68
	#
	# The BoneSection and its first Bone share a rel, so the bone block starts
	# at the BoneSection's own rel and runs bone_count * BONE_STRIDE bytes.
	# Measured on BAT.GRN (38 bones), GLAD_SA5_SHOULDER.GRN (75) and
	# GLADIATOR.GRN (68): in all three the Bone node count equals the
	# BoneSection's declared numTotalChildren and every consecutive rel delta is
	# exactly 68, with no exceptions.
	#
	# A Bone record is 68 bytes:
	#   +0  int32   parent index
	#   +4  3x f32  local translation
	#   +16 4x f32  local rotation quaternion, stored x,y,z,w
	#   +32 9x f32  local scale-shear 3x3
	#
	# That layout is not asserted from plausibility, it is the phase where the
	# quaternion test passes and the only such phase. Across all 181 bones of
	# the three sampled entries, the quaternion is unit length to within 1e-3 at
	# offset +16 and at NO other phase tried: shifting the record base by -8,
	# -4, +4 or +8 bytes fails 33-38 of 38, 68-75 of 75 and 68 of 68
	# respectively. The test can fail, and it does, everywhere except here.
	#
	# ROOT CONVENTION, measured and not assumed: the root bone's parent field
	# holds its OWN index (0), not -1. Exactly one such bone exists per entry
	# and it is always index 0, and no bone anywhere in the corpus has a parent
	# index greater than its own -- so the file order is already topological.
	# The caller still sorts rather than trusting that, because "already sorted"
	# is a property of three sampled entries, not a guarantee of the format.
	#
	# NOT STORED: an inverse-world (bind) matrix. The bone block ends exactly
	# where the next directory node begins in all three entries (gap 0), and
	# nothing of size bone_count * 64 exists nearby. bind_poses() therefore
	# COMPOSES the world bind transform from the stored local chain. See its
	# doc comment for what that costs the rest-equals-bind assertion.
	const TAG_SKELETON_SECTION := 0xCA5E0507
	const TAG_BONE_SECTION := 0xCA5E0508
	const TAG_BONE := 0xCA5E0506
	const TAG_MESH_WEIGHTS := 0xCA5E0702
	const TAG_FORM_MESH_BONE_SECTION := 0xCA5E0C09
	const TAG_FORM_MESH_BONE := 0xCA5E0C0A
	const BONE_STRIDE := 68
	## Unit-length tolerance for the stored rotation quaternion. Deliberately
	## loose: it is a layout discriminator, not a precision claim, and the
	## control above shows a wrong phase misses it by far more than this.
	const BONE_QUAT_EPS := 0.001
	## Ceiling applied to the declared bone count BEFORE it sizes anything, the
	## same posture MAX_NODES takes. The largest entry sampled declares 75.
	const MAX_BONES := 1 << 16
	## Godot's ARRAY_BONES/ARRAY_WEIGHTS slot count without
	## ARRAY_FLAG_USE_8_BONE_WEIGHTS. The format's own maximum influence count,
	## measured across all five MeshWeights blocks in the sample, is 3.
	const WEIGHT_SLOTS := 4
	# REST_BIND_ULPS, REST_BIND_EPS, last_bind_maxmag / _ulp / _depth and
	# f32_ulp() stood here. All were machinery for sizing the rest-equals-bind
	# tolerance, and all went when that assertion was removed for being
	# circular. The epsilon was honestly derived; the comparison it sized was
	# vacuous, which makes the whole apparatus dead weight rather than a
	# safeguard worth keeping for a future caller.

	## Directory index of the BoneSection node, or -1. Requires the
	## SkeletonSection to be present and the BoneSection to fall inside its
	## declared children run, so a stray tag elsewhere in the file cannot be
	## mistaken for the skeleton.
	func _bone_section(dir: Array[Dictionary]) -> int:
		for j in dir.size():
			if dir[j]["tag"] != TAG_SKELETON_SECTION:
				continue
			var last: int = mini(j + 1 + int(dir[j]["children"]), dir.size())
			for k in range(j + 1, last):
				if dir[k]["tag"] == TAG_BONE_SECTION:
					return k
		return -1

	## Contiguous raw bone bytes exactly as stored: parent indices, translations,
	## rotations and scale-shears in file order, bone_count * BONE_STRIDE of
	## them. Empty on any malformed input.
	##
	## This is what the `bones` parity fact line hashes. It is a byte-range read
	## on both sides of the harness, so the Python side needs no second matrix
	## decoder to agree with the Godot one (03-04-PLAN.md, Pitfall 8).
	func bone_bytes(entry: int) -> PackedByteArray:
		var empty := PackedByteArray()
		var length := true_length(entry)
		if length <= 0 or not magic_ok(entry):
			return empty
		var buf := _pak.read_at(_pak.entry_offset(entry), length)
		if buf.size() < length:
			return empty
		var dir := _directory(buf)
		if dir.is_empty():
			return empty
		var bs := _bone_section(dir)
		if bs == -1:
			return empty
		var n := int(dir[bs]["children"])
		if n <= 0 or n > MAX_BONES:
			push_error("Sacred.Models.bone_bytes: entry %d declares %d bones" % [entry, n])
			return empty
		var off := SECTION_OFF_MESH + int(dir[bs]["rel"])
		# The declared count is re-validated against the bytes that actually
		# remain before it sizes anything -- an over-large count returns empty
		# rather than allocating for it (threat T-03-14).
		if off < 0 or off + n * BONE_STRIDE > buf.size():
			push_error("Sacred.Models.bone_bytes: entry %d bone block (%d bones at %d) runs past the entry (%d bytes)" % [
				entry, n, off, buf.size()])
			return empty
		return buf.slice(off, off + n * BONE_STRIDE)

	## One Dictionary per bone in Granny's own file order:
	##   name        PackedByteArray -- the raw name bytes AS STORED IN THE BONE
	##               RECORD, which is always empty: the 68-byte record has no
	##               name field and no room for one. Bone name strings DO exist
	##               in the entry (GLADIATOR.GRN carries "__Root",
	##               "Bip01 R Finger31" and 200-odd more from offset 16911), but
	##               binding a string to a bone runs through a four-level
	##               DataExtension chain this plan did not decode, and the one
	##               published parser resolves it with an explicit heuristic
	##               ("take the strings after __Root in order"). Guessing that
	##               here would put an unfalsifiable name on every bone, so the
	##               field is returned honestly empty and the caller generates a
	##               name -- see 03-06-SUMMARY.md "Known Stubs".
	##   parent      the parent index EXACTLY AS STORED, self-referential for
	##               the root (measured: root's parent field is its own index,
	##               not -1)
	##   parent_effective  -1 for the root, the stored value otherwise -- the
	##               normalised form a topological sort wants, derived here once
	##               so no caller re-derives it differently
	##   position    Vector3, rotation Quaternion, scale_shear PackedFloat32Array
	##   rest        Transform3D, the local rest transform T * R * SS
	##
	## Empty Array plus push_error on any malformed input: a declared count that
	## does not fit, a parent index outside the bone range, or a rotation that is
	## not a unit quaternion. A bad parent is REJECTED, never clamped -- a
	## clamped parent silently reparents a limb and still renders.
	##
	## SCALE-SHEAR CONVENTION, recorded as unfalsifiable on this corpus: the
	## nine floats are read as a row-major 3x3. Every scale-shear in all 181
	## sampled bones is the identity to within 1e-6 (max component magnitude
	## 1.0000009), so row-major and column-major produce the same matrix here
	## and this corpus cannot distinguish them. Stated rather than hidden.
	func bones(entry: int) -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		var raw := bone_bytes(entry)
		if raw.is_empty():
			return out
		var n := raw.size() / BONE_STRIDE
		for i in n:
			var o := i * BONE_STRIDE
			var parent := raw.decode_s32(o)
			if parent < 0 or parent >= n:
				push_error("Sacred.Models.bones: entry %d bone %d has out-of-range parent %d (of %d)" % [
					entry, i, parent, n])
				return []
			var pos := Vector3(raw.decode_float(o + 4), raw.decode_float(o + 8), raw.decode_float(o + 12))
			var q := Quaternion(raw.decode_float(o + 16), raw.decode_float(o + 20),
				raw.decode_float(o + 24), raw.decode_float(o + 28))
			var qlen := sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w)
			if is_nan(qlen) or absf(qlen - 1.0) > BONE_QUAT_EPS:
				push_error("Sacred.Models.bones: entry %d bone %d rotation is not a unit quaternion (|q|=%f)" % [
					entry, i, qlen])
				return []
			var ss := PackedFloat32Array()
			ss.resize(9)
			for k in 9:
				ss[k] = raw.decode_float(o + 32 + k * 4)
			# Row-major storage into Godot's column-taking Basis constructor.
			var b := Basis(Vector3(ss[0], ss[3], ss[6]), Vector3(ss[1], ss[4], ss[7]), Vector3(ss[2], ss[5], ss[8]))
			out.append({
				"name": PackedByteArray(),
				"parent": parent,
				"parent_effective": -1 if parent == i else parent,
				"position": pos,
				"rotation": q,
				"scale_shear": ss,
				"rest": Transform3D(Basis(q) * b, pos),
			})
		return out

	## World-space bind transform per bone, in the same file order bones()
	## returns, composed parent-first from the stored local chain. Empty plus
	## push_error on a cycle or a bad parent.
	##
	## WHY THIS IS COMPOSED AND NOT READ: the format stores no inverse-world
	## matrix (see the section comment above -- the bone block ends flush
	## against the next directory node in every sampled entry, and no
	## bone_count * 64 region exists). So no pair of independently stored
	## quantities exists in this file to check the composition against.
	##
	## This function once also derived a REST_BIND_EPS tolerance, for an
	## assertion comparing its output against Skeleton3D's own global rest. That
	## assertion has been removed: both sides composed the SAME stored local
	## rests and the Skin bind was defined as the inverse of one of them, so it
	## was true by construction and could not fail. The tolerance went with it,
	## because a carefully derived epsilon for a vacuous comparison is still a
	## vacuous comparison.
	func bind_poses(entry: int) -> Array[Transform3D]:
		var out: Array[Transform3D] = []
		var bl := bones(entry)
		if bl.is_empty():
			return out
		var n := bl.size()
		var world: Array[Transform3D] = []
		var done := PackedByteArray()
		world.resize(n)
		done.resize(n)
		for i in n:
			if done[i] != 0:
				continue
			# Iterative parent walk with a step budget of n: a chain longer than
			# the bone count can only mean a cycle, so the traversal cannot loop
			# forever on a hostile file (threat T-03-15).
			var chain: Array[int] = []
			var c := i
			var steps := 0
			while done[c] == 0:
				if steps > n:
					push_error("Sacred.Models.bind_poses: entry %d bone %d sits on a parent cycle" % [entry, i])
					return []
				chain.append(c)
				var p: int = bl[c]["parent_effective"]
				if p == -1:
					break
				if chain.has(p):
					push_error("Sacred.Models.bind_poses: entry %d bone %d sits on a parent cycle" % [entry, i])
					return []
				c = p
				steps += 1
			chain.reverse()
			for b in chain:
				var p2: int = bl[b]["parent_effective"]
				if p2 == -1:
					world[b] = bl[b]["rest"]
				else:
					world[b] = world[p2] * bl[b]["rest"]
				done[b] = 1
		for i in n:
			out.append(world[i])
		return out

	## One Dictionary per Mesh node, in the SAME order mesh_arrays() walks them:
	##   count      per-vertex weight records, which equals that mesh's source
	##              position count
	##   highest    the block's own declared highest mesh-local bone index
	##   bones      PackedInt32Array, WEIGHT_SLOTS per source vertex, MESH-LOCAL
	##              bone indices, zero-padded
	##   weights    PackedFloat32Array, WEIGHT_SLOTS per source vertex, stored
	##              values NOT renormalised
	##   bone_map   PackedInt32Array, mesh-local bone index -> Granny file bone
	##              index
	##
	## Layout, measured: a MeshWeights payload is {int32 count, int32
	## highestBoneIndex, int32 unknown} then, per vertex, {int32 influences,
	## influences * (int32 mesh-local bone, float32 weight)}. The confirmation is
	## that the bytes consumed equal the node's derived span EXACTLY -- zero
	## slack on all five blocks across the three sampled entries -- and that
	## every vertex's weights sum to 1.0 within 1e-4. A wrong stride leaves
	## slack or overruns.
	##
	## bone_map comes from the FormMeshBone (0xCA5E0C0A) children of a
	## FormMeshBoneSection (0xCA5E0C09), each an int32 Granny bone index. Which
	## section belongs to which mesh is NOT positional: it is the section whose
	## child count equals highestBoneIndex + 1. On the sample that pairing is
	## unique in every entry (GLADIATOR's three meshes declare highest 44/3/9
	## against sections of 45/4/10) and it is checked for uniqueness at run time
	## -- an ambiguous pairing returns empty rather than picking one.
	func mesh_weights(entry: int) -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		var length := true_length(entry)
		if length <= 0 or not magic_ok(entry):
			return out
		var buf := _pak.read_at(_pak.entry_offset(entry), length)
		if buf.size() < length:
			return out
		var dir := _directory(buf)
		if dir.is_empty():
			return out
		var bl_count := bone_bytes(entry).size() / BONE_STRIDE
		if bl_count <= 0:
			return out

		# Every FormMeshBone list in the entry, by its own length.
		var lists: Array[PackedInt32Array] = []
		for j in dir.size():
			if dir[j]["tag"] != TAG_FORM_MESH_BONE_SECTION:
				continue
			var lst := PackedInt32Array()
			var last: int = mini(j + 1 + int(dir[j]["children"]), dir.size())
			for k in range(j + 1, last):
				if dir[k]["tag"] != TAG_FORM_MESH_BONE:
					continue
				var o := SECTION_OFF_MESH + int(dir[k]["rel"])
				if o < 0 or o + 4 > buf.size():
					push_error("Sacred.Models.mesh_weights: entry %d FormMeshBone at %d runs past the entry" % [entry, o])
					return []
				var g := buf.decode_s32(o)
				if g < 0 or g >= bl_count:
					push_error("Sacred.Models.mesh_weights: entry %d FormMeshBone references bone %d of %d" % [
						entry, g, bl_count])
					return []
				lst.append(g)
			lists.append(lst)

		for j in dir.size():
			if dir[j]["tag"] != TAG_MESH:
				continue
			# Skipped for exactly the reason mesh_arrays() skips it, so the two
			# lists stay index-for-index parallel. mesh_arrays()' vertex_mesh
			# field indexes INTO this array, so a Mesh node counted by one and
			# not the other would silently attach every vertex of every later
			# mesh to the wrong bone list.
			if _child_with_tag(dir, j, TAG_MESH_VERTICES) == -1 \
					or _child_with_tag(dir, j, TAG_MESH_NORMALS) == -1 \
					or _child_with_tag(dir, j, TAG_MESH_TRIANGLES) == -1:
				continue
			var wj := _child_with_tag(dir, j, TAG_MESH_WEIGHTS)
			if wj == -1:
				push_error("Sacred.Models.mesh_weights: entry %d mesh at node %d has no MeshWeights child" % [entry, j])
				return []
			var off := SECTION_OFF_MESH + int(dir[wj]["rel"])
			var span := _span(dir, wj, buf.size())
			if off < 0 or span <= 12 or off + span > buf.size():
				push_error("Sacred.Models.mesh_weights: entry %d MeshWeights at node %d has an unusable span %d" % [
					entry, wj, span])
				return []
			var count := buf.decode_s32(off)
			var highest := buf.decode_s32(off + 4)
			if count <= 0 or highest < 0 or count * 8 > span:
				push_error("Sacred.Models.mesh_weights: entry %d MeshWeights at node %d declares count=%d highest=%d against span %d" % [
					entry, wj, count, highest, span])
				return []
			var bones_out := PackedInt32Array()
			var weights_out := PackedFloat32Array()
			bones_out.resize(count * WEIGHT_SLOTS)
			weights_out.resize(count * WEIGHT_SLOTS)
			var p := off + 12
			var end := off + span
			for v in count:
				if p + 4 > end:
					push_error("Sacred.Models.mesh_weights: entry %d MeshWeights at node %d truncated at vertex %d" % [entry, wj, v])
					return []
				var infl := buf.decode_s32(p)
				p += 4
				if infl <= 0 or infl > WEIGHT_SLOTS or p + infl * 8 > end:
					push_error("Sacred.Models.mesh_weights: entry %d vertex %d declares %d influences (max %d)" % [
						entry, v, infl, WEIGHT_SLOTS])
					return []
				for s in infl:
					var lb := buf.decode_s32(p)
					var w := buf.decode_float(p + 4)
					p += 8
					if lb < 0 or lb > highest:
						push_error("Sacred.Models.mesh_weights: entry %d vertex %d references local bone %d, above the declared highest %d" % [
							entry, v, lb, highest])
						return []
					bones_out[v * WEIGHT_SLOTS + s] = lb
					weights_out[v * WEIGHT_SLOTS + s] = w
			if p != end:
				push_error("Sacred.Models.mesh_weights: entry %d MeshWeights at node %d consumed %d of %d bytes" % [
					entry, wj, p - off, span])
				return []
			# The pairing rule, and its own uniqueness check.
			var want := highest + 1
			var pick := -1
			var hits := 0
			for li in lists.size():
				if lists[li].size() == want:
					hits += 1
					pick = li
			if hits != 1:
				push_error("Sacred.Models.mesh_weights: entry %d mesh at node %d needs a %d-bone FormMeshBone list; %d sections match" % [
					entry, j, want, hits])
				return []
			out.append({
				"count": count, "highest": highest,
				"bones": bones_out, "weights": weights_out,
				"bone_map": lists[pick],
			})
			lists.remove_at(pick)
		return out

	# ---------------------------------------------------------------------
	# Animation clip decode (Plan 05-05, R1.5). kind=65 entries.
	#
	# CORRECTION: 05-RESEARCH.md records 0xCA5E1204 (AnimationTransformTrackKeys)
	# as "genuinely absent" from Sacred's motion bytes. That was measured against
	# entry 2845, GLADIATOR.GRN's kind=65 counterpart -- which is a MODEL (five
	# Mesh nodes, no per-bone animation records), not a clip. A clip such as
	# entry 2847 (GLAD_ATTACK_1H_A.GRN) carries exactly one 0xCA5E1204 record per
	# bone. 05-02-SUMMARY.md corrected this in the findings log (row 589); this
	# section must not re-inherit the "absent" claim.
	#
	# The animation node tree, reached through _directory()/_direct_children()
	# exactly as geometry and bones already are -- no byte-pattern scan:
	#
	#   AnimationSection (0xCA5E1205)
	#     -> Animation (0xCA5E1200), a direct child
	#        -> AnimationTransformTrackSection (0xCA5E1203), a direct child
	#           -> AnimationTransformTrackKeys (0xCA5E1204), one direct child per bone
	#
	# Per-bone record layout (zero-slack reconciled by 05-02 against Sacred's own
	# bytes on three sampled clips -- 2847/2899/2903, all three 100% unit-quaternion
	# at ANIM_QUAT_EPS below):
	#
	#   +0   u32     id                (carried through as data, never an index --
	#                                    05-02's --idjoin REFUTED it as a cross-file
	#                                    join key, BAT.GRN control arm included)
	#   +4   5x u32   unknown
	#   +24  u32     numTranslates (nt)
	#   +28  u32     numQuaternions (nq)
	#   +32  u32     numUnknowns (nu)
	#   +36  4x u32   unknown
	#   +52  nt x f32  translate-track times
	#        nq x f32  rotation-track times
	#        nu x f32  "other"-track times
	#        nt x 3 f32  translations
	#        nq x 4 f32  rotations, stored x,y,z,w -- same order bones() uses
	#        nu x 3 f32  "other" payload, uninterpreted
	#   + ANIM_RECORD_TRAILER (48) undocumented, measured, count-independent
	#     fixed bytes -- part of the size a record must reconcile to exactly,
	#     never itself decoded. An earlier search attempt folded these bytes
	#     into the header instead (widening the header bound to reach them
	#     directly); that produced 8 zero-slack survivors that ALL failed the
	#     unit-quaternion check, which is how 05-02 confirmed this is a
	#     trailing block and not part of the header/field region.
	#
	# LICENCE BOUNDARY (D-21, D-23): this layout is attributed to 05-02's
	# zero-slack reconciliation against Sacred's own bytes, not lifted from
	# either github.com/SiENcE/Iris1 (GPL v2) or the AoM Model Plugin (no
	# licence file, so used on the same all-rights-reserved terms as Iris1).
	# Both were consulted during planning only as documentation of node-type
	# NAMES, which are facts about the format -- no code, comment or structure
	# from either is reproduced here; the decode below is this codebase's own.
	const TAG_ANIMATION_SECTION := 0xCA5E1205            # AnimationSection
	const TAG_ANIMATION := 0xCA5E1200                    # Animation
	const TAG_ANIM_VECTOR_TRACK_SECTION := 0xCA5E1201    # AnimationVectorTrackSection
	const TAG_ANIM_VECTOR_TRACK_KEYS := 0xCA5E1202       # AnimationVectorTrackKeys
	const TAG_ANIM_TRANSFORM_TRACK_SECTION := 0xCA5E1203 # AnimationTransformTrackSection
	const TAG_ANIM_TRANSFORM_TRACK_KEYS := 0xCA5E1204    # AnimationTransformTrackKeys
	## DataExtension directory node. Same numeric tag TAG_SIZES already uses for
	## the unrelated 12-byte chunk-stream leaf family walk() reads -- a distinct
	## context (flat node directory vs. header chain), so this is a second,
	## non-conflicting named use of the same real on-disk tag value, not a
	## redefinition.
	const TAG_DATA_EXTENSION := 0xCA5E0F00

	## `section_offset(kind) = magic_offset(kind) + 376`, confirmed corpus-wide
	## (4991/4993 walkable entries, 05-02-SUMMARY.md) and shown falsifiable (a
	## real 1- or 4-byte desync collapses every directory read to baddir). For
	## kind=64 this reconciles the pre-existing SECTION_OFF_MESH=1634
	## (1258+376); for kind=65 it resolves to 320+376=696. -1 when the entry has
	## no kind-scoped magic offset.
	##
	## Plan 05-05's wave_note: if a future plan's Models.section_offset() has a
	## different body, that is a rival spelling of this rule and must not exist.
	const SECTION_OFF_DELTA := 376

	func section_offset(entry: int) -> int:
		var off := magic_offset(entry)
		if off == -1:
			return -1
		return off + SECTION_OFF_DELTA

	## Ceiling on any of a clip record's declared counts (numTranslates/
	## numQuaternions/numUnknowns), applied BEFORE a count sizes anything -- the
	## same posture MAX_NODES and MAX_BONES already take. The largest sampled
	## clip (2847) declares 920 quaternion keys; this leaves generous headroom.
	const MAX_KEYFRAMES := 1 << 20

	const ANIM_RECORD_HEADER := 52
	const ANIM_OFF_NUM_TRANSLATES := 24
	const ANIM_OFF_NUM_QUATERNIONS := 28
	const ANIM_OFF_NUM_UNKNOWNS := 32
	## Undocumented, measured (05-02), fixed trailer following the documented
	## payload on every real AnimationTransformTrackKeys record -- constant
	## across all 200 records 05-02 sampled, regardless of that record's own
	## nt/nq/nu. See the section header comment above for how folding it into
	## the header instead was tried and refuted.
	const ANIM_RECORD_TRAILER := 48

	## Track-quaternion unit-length tolerance. DELIBERATELY NOT BONE_QUAT_EPS:
	## bind-pose quaternions in bones() are exact static values, but
	## AnimationTransformTrackKeys quaternions are keyframed data with measured
	## mid-track quantization drift (05-02-SUMMARY.md: max deviation 0.0611 on
	## entry 2847, 0.0330 on 2903, 0.00086 on 2899 -- all far above
	## BONE_QUAT_EPS=0.001). 05-02 exhaustively re-ranked every other
	## size-reconciled (header, field-offset) candidate by the epsilon IT would
	## require: the documented layout sits in an isolated cluster at 0.0611,
	## with a 7x gap to the next candidate (0.4142) and 50x+ to the rest. 0.07
	## is set above the worst measured value with headroom -- a property of
	## this being the correct layout for keyframed track data, not a loosened
	## precision claim. Reusing BONE_QUAT_EPS here would incorrectly refuse
	## every real clip in the corpus.
	const ANIM_QUAT_EPS := 0.07

	## Generalises _directory() to an arbitrary section offset. _directory()
	## itself stays hardcoded to SECTION_OFF_MESH (kind=64 geometry only) so
	## every existing mesh/skeleton/weight call site, and the pre-existing
	## `models`/`bones` fact-line md5s, are untouched by this plan. kind=65
	## clips need section_offset(entry) instead -- this is that rule applied to
	## the identical flat-directory shape _directory() already reads.
	func _directory_sec(buf: PackedByteArray, sec: int) -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		if sec < 0 or buf.size() < sec + DIR_OFF + NODE_STRIDE:
			return out
		var n := buf.decode_u32(sec)
		if n <= 0 or n > MAX_NODES:
			return out
		var dir_off := sec + DIR_OFF
		if dir_off + n * NODE_STRIDE > buf.size():
			return out
		for j in n:
			var o := dir_off + j * NODE_STRIDE
			var tag := buf.decode_u32(o)
			if (tag & 0xFFFF0000) != MAGIC:
				return []
			out.append({"tag": tag, "rel": buf.decode_u32(o + 4), "children": buf.decode_u32(o + 8)})
		return out

	## _span()'s twin for an arbitrary section offset, same rule: the gap to
	## the next node with a strictly larger rel, or to the end of the section.
	func _span_sec(dir: Array[Dictionary], j: int, buf_size: int, sec: int) -> int:
		var r: int = dir[j]["rel"]
		for k in range(j + 1, dir.size()):
			var nr: int = dir[k]["rel"]
			if nr > r:
				return nr - r
		return buf_size - sec - r

	## The structural model/clip discriminator 05-02 measured (grn_motion.py
	## --census, 0 disagreements across all 4991 walkable entries, both kinds):
	## an entry is a clip when it has no Mesh nodes at all AND its
	## DataExtension count equals its Bone count; when those two independent
	## predicates disagree, the entry is neither classified and this returns
	## false rather than guessing. Computed purely from the entry's own
	## directory structure -- no reference to entry_name(), per D-03, so a
	## second character needs only data, never a new branch here. False for an
	## out-of-range or non-walkable entry.
	func is_animation(entry: int) -> bool:
		var length := true_length(entry)
		if length <= 0 or not magic_ok(entry):
			return false
		var buf := _pak.read_at(_pak.entry_offset(entry), length)
		if buf.size() < length:
			return false
		var dir := _directory_sec(buf, section_offset(entry))
		if dir.is_empty():
			return false
		var meshes := 0
		var bone_n := 0
		var objects := 0
		for node in dir:
			match int(node["tag"]):
				TAG_MESH:
					meshes += 1
				TAG_BONE:
					bone_n += 1
				TAG_DATA_EXTENSION:
					objects += 1
		var clip_by_meshes := meshes == 0
		var clip_by_objeqbones := objects == bone_n
		return clip_by_meshes == clip_by_objeqbones and clip_by_meshes

	## Kind-scoped twin of index_of(): the first entry whose name matches AND
	## whose kind is KIND_MOTION. This exists because models.pak carries
	## GLADIATOR.GRN TWICE -- entry 589 (kind=64 mesh) and entry 2845 (kind=65,
	## itself a MODEL per is_animation() above, not a clip) -- so
	## index_of("GLADIATOR.GRN") returns 589 and any animation lookup built on
	## it would silently resolve to the wrong entry. Carries index_of()'s
	## security constraint verbatim: the string is compared against the pak's
	## own 64-byte name fields and never joined into a path or handed to
	## FileAccess.
	func clip_index_of(name: String) -> int:
		var want := name.strip_edges().to_upper()
		if want == "":
			return -1
		if not want.ends_with(".GRN"):
			want += ".GRN"
		for i in _pak.count():
			if kind_of(i) == KIND_MOTION and entry_name(i).to_upper() == want:
				return i
		return -1

	## The decode. Reaches TAG_ANIMATION_SECTION through the entry's own
	## directory, then its direct child TAG_ANIMATION, then that node's direct
	## child TAG_ANIM_TRANSFORM_TRACK_SECTION, then that section's direct
	## TAG_ANIM_TRANSFORM_TRACK_KEYS children -- one per bone. Every hop is
	## _direct_children()/_child_with_tag() over the decoded directory, exactly
	## as bones()/mesh_arrays() already reach their nodes; never a byte-pattern
	## scan.
	##
	## For each record: derive its span with _span_sec(), read the three count
	## fields, and require the implied byte size (header + tracks + payload +
	## ANIM_RECORD_TRAILER) to equal that span EXACTLY. One byte of slack
	## refuses the WHOLE entry with push_error() naming the record index, span
	## and implied size -- never a partial decode. Every declared count is
	## bounded by MAX_KEYFRAMES and re-checked against the span before it sizes
	## anything.
	##
	## Returns {bones: int, records: Array[Dictionary], length: float,
	## source: String} where each record is {id: int, times_pos:
	## PackedFloat32Array, times_rot: PackedFloat32Array, times_other:
	## PackedFloat32Array, positions: PackedVector3Array,
	## rotations: Array[Quaternion], others: PackedVector3Array}. Empty
	## Dictionary plus push_error() on any malformed input, including a
	## KIND_MOTION entry that is a model rather than a clip (no per-bone
	## records) -- decoding a non-clip is a caller error, not a partial
	## success. Every decoded rotation is checked unit-length to within
	## ANIM_QUAT_EPS (see that constant's own doc comment for why it is not
	## BONE_QUAT_EPS) and a clip whose rotations are not unit quaternions is
	## refused whole, matching bones()'s existing posture.
	##
	## `desync` displaces each record's computed base offset by that many
	## bytes before its count fields are read -- the Godot-side twin of
	## analysis/tools/grn_tagwalk.py's clip_decode(desync=) (Plan 05-05 Task
	## 2's --clip-falsify=N counterfactual). 0 (the default) is every
	## existing caller's behaviour, unchanged.
	func clip(entry: int, desync: int = 0) -> Dictionary:
		var length := true_length(entry)
		if length <= 0 or not magic_ok(entry):
			push_error("Sacred.Models.clip: entry %d is not a walkable motion entry" % entry)
			return {}
		var buf := _pak.read_at(_pak.entry_offset(entry), length)
		if buf.size() < length:
			push_error("Sacred.Models.clip: entry %d short read (%d of %d)" % [entry, buf.size(), length])
			return {}
		var sec := section_offset(entry)
		var dir := _directory_sec(buf, sec)
		if dir.is_empty():
			push_error("Sacred.Models.clip: entry %d has no readable node directory" % entry)
			return {}

		var bone_count := 0
		for node in dir:
			if int(node["tag"]) == TAG_BONE:
				bone_count += 1

		var sec_j := -1
		for j in dir.size():
			if int(dir[j]["tag"]) == TAG_ANIMATION_SECTION:
				sec_j = j
				break
		if sec_j == -1:
			push_error("Sacred.Models.clip: entry %d has no AnimationSection node" % entry)
			return {}
		var anim_j := _child_with_tag(dir, sec_j, TAG_ANIMATION)
		if anim_j == -1:
			push_error("Sacred.Models.clip: entry %d AnimationSection has no Animation child" % entry)
			return {}
		var tts_j := _child_with_tag(dir, anim_j, TAG_ANIM_TRANSFORM_TRACK_SECTION)
		if tts_j == -1:
			push_error("Sacred.Models.clip: entry %d Animation has no AnimationTransformTrackSection child" % entry)
			return {}
		var key_nodes: Array[int] = []
		for k in _direct_children(dir, tts_j):
			if int(dir[k]["tag"]) == TAG_ANIM_TRANSFORM_TRACK_KEYS:
				key_nodes.append(k)
		if key_nodes.is_empty():
			push_error("Sacred.Models.clip: entry %d carries no per-bone AnimationTransformTrackKeys records" % entry)
			return {}

		var records: Array[Dictionary] = []
		var max_length := 0.0
		for ridx in key_nodes.size():
			var j: int = key_nodes[ridx]
			var off := sec + int(dir[j]["rel"]) + desync
			var span := _span_sec(dir, j, buf.size(), sec)
			if off < 0 or span <= ANIM_RECORD_HEADER or off + span > buf.size():
				push_error("Sacred.Models.clip: entry %d record %d has an unusable span %d" % [entry, ridx, span])
				return {}
			if off + ANIM_OFF_NUM_UNKNOWNS + 4 > buf.size():
				push_error("Sacred.Models.clip: entry %d record %d too short to read its count fields" % [entry, ridx])
				return {}
			var rid := buf.decode_u32(off)
			var nt := buf.decode_u32(off + ANIM_OFF_NUM_TRANSLATES)
			var nq := buf.decode_u32(off + ANIM_OFF_NUM_QUATERNIONS)
			var nu := buf.decode_u32(off + ANIM_OFF_NUM_UNKNOWNS)
			if nt > MAX_KEYFRAMES or nq > MAX_KEYFRAMES or nu > MAX_KEYFRAMES:
				push_error("Sacred.Models.clip: entry %d record %d declares a count above MAX_KEYFRAMES (nt=%d nq=%d nu=%d)" % [
					entry, ridx, nt, nq, nu])
				return {}
			var implied := ANIM_RECORD_HEADER + 16 * nt + 20 * nq + 16 * nu + ANIM_RECORD_TRAILER
			if implied != span:
				push_error("Sacred.Models.clip: entry %d record %d implied size %d does not equal its span %d exactly (nt=%d nq=%d nu=%d)" % [
					entry, ridx, implied, span, nt, nq, nu])
				return {}

			var p := off + ANIM_RECORD_HEADER
			var times_pos := PackedFloat32Array()
			times_pos.resize(nt)
			for i in nt:
				times_pos[i] = buf.decode_float(p + i * 4)
			p += nt * 4
			var times_rot := PackedFloat32Array()
			times_rot.resize(nq)
			for i in nq:
				times_rot[i] = buf.decode_float(p + i * 4)
			p += nq * 4
			var times_other := PackedFloat32Array()
			times_other.resize(nu)
			for i in nu:
				times_other[i] = buf.decode_float(p + i * 4)
			p += nu * 4

			var positions := PackedVector3Array()
			positions.resize(nt)
			for i in nt:
				positions[i] = Vector3(buf.decode_float(p + i * 12), buf.decode_float(p + i * 12 + 4), buf.decode_float(p + i * 12 + 8))
			p += nt * 12

			var rotations: Array[Quaternion] = []
			rotations.resize(nq)
			for i in nq:
				var q := Quaternion(buf.decode_float(p + i * 16), buf.decode_float(p + i * 16 + 4),
					buf.decode_float(p + i * 16 + 8), buf.decode_float(p + i * 16 + 12))
				var qlen := sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w)
				if is_nan(qlen) or absf(qlen - 1.0) > ANIM_QUAT_EPS:
					push_error("Sacred.Models.clip: entry %d record %d rotation %d is not a unit quaternion (|q|=%f)" % [
						entry, ridx, i, qlen])
					return {}
				rotations[i] = q
			p += nq * 16

			var others := PackedVector3Array()
			others.resize(nu)
			for i in nu:
				others[i] = Vector3(buf.decode_float(p + i * 12), buf.decode_float(p + i * 12 + 4), buf.decode_float(p + i * 12 + 8))
			p += nu * 12
			# p + ANIM_RECORD_TRAILER == off + span exactly, by the implied-size
			# check above -- the trailer itself is never decoded.

			records.append({
				"id": rid, "times_pos": times_pos, "times_rot": times_rot,
				"times_other": times_other, "positions": positions,
				"rotations": rotations, "others": others,
			})
			if nt > 0 and times_pos[nt - 1] > max_length:
				max_length = times_pos[nt - 1]

		return {
			"bones": bone_count, "records": records, "length": max_length,
			"source": "h=%d,nt=%d,nq=%d,nu=%d,trailer=%d(documented)" % [
				ANIM_RECORD_HEADER, ANIM_OFF_NUM_TRANSLATES, ANIM_OFF_NUM_QUATERNIONS,
				ANIM_OFF_NUM_UNKNOWNS, ANIM_RECORD_TRAILER],
		}

	## The rule 05-02 measured: the maximum, across all records, of that
	## record's last translate-track time. 0.0 for a non-clip or any malformed
	## entry -- clip() already refuses those, so this just forwards its
	## "length" field or the safe default.
	func clip_length(entry: int) -> float:
		var c := clip(entry)
		if c.is_empty():
			return 0.0
		return float(c["length"])

	## Raw stored bytes for entry's per-bone AnimationTransformTrackKeys
	## records, concatenated in directory order -- the RAW STORED bytes
	## exactly as they sit in the file, not the decoded floats clip() returns.
	## The `motion` fact line (verify.gd/verify_ref.py, Plan 05-05 Task 2)
	## hashes these bytes for the same reason bones()'s `bones` line hashes
	## bone_bytes(): both harness sides then compute the hash from offsets,
	## and neither needs the other's float decoder to agree for it to mean
	## anything. Redoes clip()'s own directory walk rather than returning
	## bytes from clip() itself -- the same relationship bone_bytes() already
	## has to bones().
	func clip_bytes(entry: int) -> PackedByteArray:
		var empty := PackedByteArray()
		var length := true_length(entry)
		if length <= 0 or not magic_ok(entry):
			return empty
		var buf := _pak.read_at(_pak.entry_offset(entry), length)
		if buf.size() < length:
			return empty
		var sec := section_offset(entry)
		var dir := _directory_sec(buf, sec)
		if dir.is_empty():
			return empty
		var sec_j := -1
		for j in dir.size():
			if int(dir[j]["tag"]) == TAG_ANIMATION_SECTION:
				sec_j = j
				break
		if sec_j == -1:
			return empty
		var anim_j := _child_with_tag(dir, sec_j, TAG_ANIMATION)
		if anim_j == -1:
			return empty
		var tts_j := _child_with_tag(dir, anim_j, TAG_ANIM_TRANSFORM_TRACK_SECTION)
		if tts_j == -1:
			return empty
		var out := PackedByteArray()
		for k in _direct_children(dir, tts_j):
			if int(dir[k]["tag"]) != TAG_ANIM_TRANSFORM_TRACK_KEYS:
				continue
			var off := sec + int(dir[k]["rel"])
			var span := _span_sec(dir, k, buf.size(), sec)
			if off < 0 or span <= 0 or off + span > buf.size():
				return empty
			out.append_array(buf.slice(off, off + span))
		return out

	## The 13 German weapon-category tokens ATTACK_* clip names carry,
	## longest-token-first (2H_AXT before 2H, KLINGENWAFFEN before nothing
	## shorter overlaps it) so a compound token is never shadowed by a
	## shorter one nested inside it. D-07: attack animation names encode a
	## weapon category (ATTACK_1H_A, ATTACK_2H_A, ATTACK_2H_AXT_A/B,
	## ATTACK_2WAFFEN_A/B, ATTACK_ARMBRUST_A, ATTACK_BH_A, ...). Decode and
	## record the category here; nothing in this file or godot-port/view/
	## selects an animation from gear a character is carrying -- no
	## equipment or weapon system exists yet, and a selection rule built
	## without one would be untestable invention. That wiring is the
	## combat phase's job.
	const CLIP_CATEGORIES := [
		"KLINGENWAFFEN", "ARMBRUST", "PEITSCHE", "2WAFFEN", "2H_AXT",
		"BOGEN", "DOLCH", "STAB", "WURF", "AXT", "BH", "1H", "2H",
	]

	## First CLIP_CATEGORIES token found as an underscore-delimited word in
	## name (case-sensitive -- the pak's own names are already upper-case),
	## checked longest-first so "2H_AXT" wins over the "2H" nested inside
	## it. Empty string if none match (e.g. GLAD_PICKUP.GRN). ponytail:
	## this is a substring match over an artist naming convention, not a
	## shipped binding table (D-02) -- motions.pak was opened and refuted
	## as that table (see the grn-clip-categories findings row); ceiling is
	## "wrong category if a future name introduces a token this list
	## doesn't cover".
	func clip_category(name: String) -> String:
		var wrapped := "_" + name.trim_suffix(".GRN") + "_"
		for token in CLIP_CATEGORIES:
			if wrapped.find("_" + token + "_") != -1:
				return token
		return ""

	## Every KIND_MOTION entry whose name begins with prefix, as
	## {entry: int, name: String, action: String, category: String}.
	## `action` is the portion of the name between prefix and the matched
	## category token (e.g. "ATTACK" for "GLAD_ATTACK_2H_AXT_A.GRN" with
	## prefix "GLAD"); category is clip_category(name), empty string if no
	## token matched. prefix is a parameter, never a literal character name
	## compared in a conditional here (D-03).
	func clip_catalogue(prefix: String) -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		for entry in _pak.count():
			if kind_of(entry) != KIND_MOTION:
				continue
			var name := entry_name(entry)
			if not name.begins_with(prefix):
				continue
			var category := clip_category(name)
			var body := name.trim_suffix(".GRN").substr(prefix.length()).trim_prefix("_")
			var action := body
			var token_at := body.find(category) if category != "" else -1
			if token_at != -1:
				action = body.substr(0, token_at).trim_suffix("_")
			out.append({"entry": entry, "name": name, "action": action, "category": category})
		return out


## Hero savegames (`*.pax` under `~/.lgp/sacred/`). A PAX file is a fixed
## 256-byte header, a section table at 0x0100, and a body per used section.
## Written from the bytes of eight retail heroes (TSV rows 530-531); the
## HeroDump sources in unpack-tools/ were read as documentation of behaviour
## only, and no code was taken from them.
##
##   0x0000  "AMH" + u8 version 0x1B
##   0x0004  u32 section_count            (16 in every observed file)
##   0x0008  u32 x9 unknown; u1 == the byte length of the 0xC3 section
##   0x0034  212 zero bytes
##   0x0100  section_count x { u32 type, u32 offset, u32 size } -- type 0 == unused
##   @offset { u32 signature, u32 compressed_size, 24 zero bytes }
##            signature == 0xBAADC0DE -> zlib payload at offset + 0x20
##            otherwise               -> raw payload at offset, `size` bytes
class Pax extends RefCounted:
	const MAGIC := 0x1B484D41          ## "AMH" + version byte 0x1B, read as one u32
	const TABLE := 0x0100              ## section table start; fixed, not a header field
	const ENTRY := 12                  ## bytes per section-table entry
	const COMPRESSED := 0xBAADC0DE     ## section signature marking a zlib payload
	const PAYLOAD := 0x20              ## payload offset past a compressed section header
	## Retail hardcodes this section's read length and ignores its table size.
	## Observed value happens to agree (usz == 64), so this only matters for a
	## file where it does not -- keep it, it is cheap insurance.
	const TYPE_FIXED_64 := 0xC4

	var types := PackedInt32Array()    ## used section types, in table order
	var _off := PackedInt64Array()
	var _usz := PackedInt64Array()
	var _by_type: Dictionary[int, int] = {}
	var _f: FileAccess

	func _init(path: String) -> void:
		_f = FileAccess.open(path, FileAccess.READ)
		if _f == null:
			push_error("Sacred.Pax: cannot open %s (%s)" % [path, error_string(FileAccess.get_open_error())])
			return
		if _f.get_32() != MAGIC:
			push_error("Sacred.Pax: %s is not a PAX hero file" % path)
			_f = null
			return
		var n := _f.get_32()
		_f.seek(TABLE)
		var tab := _f.get_buffer(n * ENTRY)
		for i in n:
			var t := tab.decode_u32(i * ENTRY + 0)
			if t == 0:
				continue                # unused slot; retail skips these, not an error
			_by_type[t] = types.size()
			types.append(t)
			_off.append(tab.decode_u32(i * ENTRY + 4))
			_usz.append(tab.decode_u32(i * ENTRY + 8))

	func is_open() -> bool:
		return _f != null

	## Used sections only. The table always has 16 slots; most are empty.
	func count() -> int:
		return types.size()

	func has_type(type_id: int) -> bool:
		return _by_type.has(type_id)

	## Decoded bytes of one section, inflating it if it is compressed. Returns
	## an empty array for an unknown type or a stream that fails to inflate.
	func section(type_id: int) -> PackedByteArray:
		if not _by_type.has(type_id):
			return PackedByteArray()
		var i: int = _by_type[type_id]
		var off: int = _off[i]
		var usz: int = _usz[i]
		_f.seek(off)
		if _f.get_32() != COMPRESSED:
			var raw_len := 64 if type_id == TYPE_FIXED_64 else usz
			_f.seek(off)
			return _f.get_buffer(raw_len)
		var csz := _f.get_32()
		_f.seek(off + PAYLOAD)
		# Pass the whole zlib-wrapped stream (78 da here, not the 78 9c seen
		# elsewhere). Godot 4.7's COMPRESSION_DEFLATE consumes the 2-byte
		# wrapper itself and FAILS on a stripped stream -- measured, TSV row 534.
		var out := _f.get_buffer(csz).decompress(usz, FileAccess.COMPRESSION_DEFLATE)
		if out.size() != usz:
			push_error("Sacred.Pax: section 0x%X inflated to %d, expected %d" % [type_id, out.size(), usz])
			return PackedByteArray()
		return out
