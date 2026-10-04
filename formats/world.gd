extends RefCounted
## sectors.keyx + sectors.wldx. keyx is the shipped index: no scan, no cache.

const Common := preload("res://formats/common.gd")
const Sectors := preload("res://formats/sectors.gd")
const Pak := preload("res://formats/pak.gd")

var size := Vector2i.ZERO         ## sector grid, 100x100
var _f: FileAccess
var _by_key: Dictionary[int, int] = {}   ## gy*100+gx -> record index
var _key_by_native_id: Dictionary[int, int] = {}
var _off := PackedInt64Array()
var _csize := PackedInt64Array()
var _dsize := PackedInt64Array()
## The two per-sector liquid material ids out of the record's embedded
## environment block (Common.KEY_LIQ9/KEY_LIQ10, row 1010) -- kept as two
## bytes per record rather than the whole block, because nothing else in the
## block is decoded yet.
var _liq9 := PackedByteArray()
var _liq10 := PackedByteArray()

func _init(world_dir: String) -> void:
	var kf := FileAccess.open(Pak.resolve(world_dir.path_join("sectors.keyx")), FileAccess.READ)
	_f = FileAccess.open(Pak.resolve(world_dir.path_join("sectors.wldx")), FileAccess.READ)
	if kf == null or _f == null:
		push_error("World: cannot open sectors.keyx / sectors.wldx in %s" % world_dir)
		return
	kf.seek(4)
	var n := kf.get_32()
	size = Vector2i(kf.get_32(), kf.get_32())
	kf.seek(Common.KEY_HDR)
	var keys := kf.get_buffer(n * Common.KEY_REC)
	_off.resize(n)
	_csize.resize(n)
	_dsize.resize(n)
	_liq9.resize(n)
	_liq10.resize(n)
	for i in n:
		var base := i * Common.KEY_REC
		_by_key[keys.decode_u32(base + Common.KEY_COORD)] = i
		_key_by_native_id[keys.decode_u32(base + Sectors.O_INDEX)] = keys.decode_u32(base + Common.KEY_COORD)
		_off[i] = keys.decode_u32(base + Common.KEY_OFF)
		_csize[i] = keys.decode_u32(base + Common.KEY_CSIZE)
		_dsize[i] = keys.decode_u32(base + Common.KEY_DSIZE)
		_liq9[i] = keys[base + Common.KEY_LIQ9]
		_liq10[i] = keys[base + Common.KEY_LIQ10]

func is_open() -> bool:
	return _f != null

func count() -> int:
	return _off.size()

func has_sector(gx: int, gy: int) -> bool:
	return _by_key.has(gy * 100 + gx)

## Static+12 is this authored sector id, NOT the keyx record ordinal.
func coordinates_for_id(native_id: int) -> Vector2i:
	if not _key_by_native_id.has(native_id):
		push_error("World: unknown native sector id %d" % native_id)
		return Vector2i(-1, -1)
	var key: int = _key_by_native_id[native_id]
	return Vector2i(key % 100, key / 100)

## Decompressed sector stream, or an empty array if that sector is absent.
## 3950 of the 10000 grid slots have no sector at all.
func sector(gx: int, gy: int) -> PackedByteArray:
	var i: int = _by_key.get(gy * 100 + gx, -1)
	if i < 0:
		return PackedByteArray()
	_f.seek(_off[i])
	return Common.inflate(_f.get_buffer(_csize[i]), _dsize[i])

## Raw 32-byte WldxEntry grid of one sector (4096 entries), or empty.
## Field map is in the plan's Phase 3 table; the short version is
## +0x00 tile id, +0x04/+0x0c object handles, +0x10/+0x14/+0x18 four
## PER-CORNER bytes each (height delta / light / unknown), +0x1f flags.
func entries(gx: int, gy: int) -> PackedByteArray:
	var d := sector(gx, gy)
	return PackedByteArray() if d.is_empty() else d.slice(
		Common.NAME, Common.NAME + Common.SECT * Common.SECT * Common.CELL)

## The sector's liquid material id for one of the two liquid cell nibbles
## (WldxEntry +0x1f high nibble 9 or 10) -- an index into the 14-entry
## animated-liquid material table, or -1 if the sector is absent. Retail
## keeps two ids per sector because 22 sectors really do carry two different
## liquids at once (water shore against a lava flow).
func liquid_id(gx: int, gy: int, nibble: int) -> int:
	var i: int = _by_key.get(gy * 100 + gx, -1)
	if i < 0:
		return -1
	return _liq10[i] if nibble == 10 else _liq9[i]


## Tile ids of one sector, row-major, 64x64. Empty if the sector is absent.
## The stream's leading 32-byte name is deliberately ignored: it is a stale
## 0xCD-padded buffer that disagrees with the true coordinate for 275 of the
## 6050 sectors and is empty for 270 of them (results log rows 206-207).
func tile_ids(gx: int, gy: int) -> PackedInt32Array:
	var d := sector(gx, gy)
	var out := PackedInt32Array()
	if d.is_empty():
		return out
	out.resize(Common.SECT * Common.SECT)
	for i in out.size():
		out[i] = d.decode_u32(Common.NAME + i * Common.CELL)
	return out
