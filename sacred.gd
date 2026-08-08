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
	}

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

	## (tag, offset, length) triples from the entry's root tag, entry-relative
	## offsets, advancing strictly by each tag's declared size from
	## TAG_SIZES -- never by scanning for the next tag-shaped byte pattern.
	## Stops (returning what was collected so far) on the terminator, on a
	## tag with no TAG_SIZES entry, or on a read that would pass the buffer
	## end. Empty for an entry that fails magic_ok().
	func walk(entry: int) -> Array[Dictionary]:
		var triples: Array[Dictionary] = []
		if not magic_ok(entry):
			return triples
		var length := true_length(entry)
		var buf := _pak.read_at(_pak.entry_offset(entry), length)
		var off := magic_offset(entry)
		while off + 4 <= buf.size():
			var tag := buf.decode_u32(off)
			if tag == TERMINATOR:
				break
			if not TAG_SIZES.has(tag):
				break
			var size: int = TAG_SIZES[tag]
			if off + size > buf.size():
				break
			triples.append({"tag": tag, "off": off, "len": size})
			off += size
		return triples
