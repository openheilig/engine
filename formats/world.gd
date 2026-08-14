extends RefCounted
## sectors.keyx + sectors.wldx. keyx is the shipped index: no scan, no cache.

const Common := preload("res://formats/common.gd")

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
	for i in n:
		var base := i * Common.KEY_REC
		_by_key[keys.decode_u32(base + Common.KEY_COORD)] = i
		_off[i] = keys.decode_u32(base + Common.KEY_OFF)
		_csize[i] = keys.decode_u32(base + Common.KEY_CSIZE)
		_dsize[i] = keys.decode_u32(base + Common.KEY_DSIZE)

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
	return Common.inflate(_f.get_buffer(_csize[i]), _dsize[i])

## Raw 32-byte WldxEntry grid of one sector (4096 entries), or empty.
## Field map is in the plan's Phase 3 table; the short version is
## +0x00 tile id, +0x04/+0x0c object handles, +0x10/+0x14/+0x18 four
## PER-CORNER bytes each (height delta / light / unknown), +0x1f flags.
func entries(gx: int, gy: int) -> PackedByteArray:
	var d := sector(gx, gy)
	return PackedByteArray() if d.is_empty() else d.slice(
		Common.NAME, Common.NAME + Common.SECT * Common.SECT * Common.CELL)

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
