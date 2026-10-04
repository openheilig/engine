extends RefCounted
const Pak := preload("res://formats/pak.gd")
## tiles.pak: 64-byte records, one per tile id, giving the texture.pak id.
## ISO magic, NOT a generic PAK container -- read directly from the file
## rather than routing through Sacred.Pak (TOOLCHAIN-AUDIT-2026-08-12).
##
## The whole record, confirmed against the Armalion prerelease's own tiles.pak
## (ISO v3 there too, 13402 tiles against retail's 90132):
##
##   +0x00 char[32] SOURCE TGA FILENAME, NUL-padded -- "iso00.tga".."iso999.tga"
##   +0x20 u32      texture.pak id
##   +0x24 u32      orientation, and it is EXACTLY tile_id % 18
##   +0x28 u32      0
##   +0x2c u32      65536, constant in every record of both builds
##   +0x30 u32[4]   0
##
## THE TABLE IS A PRODUCT. Eighteen consecutive tile ids share one filename and
## one texture id -- 5008 of 5008 groups in retail, 745 of 745 in the
## prerelease -- so `tile_id = group * 18 + orientation`, and name, group and
## texture id are in bijection (5008 names, 5008 groups, no name on two texture
## ids). The only content in 5.8 MB is 5008 texture ids and 5008 names.
##
## That is why `orientation(i) == i % 18` can never fail: it is an identity by
## construction, not a property of the data. Any test resting on it is vacuous.

const RECORD := 64

## The {flags, offset, size} index triple, 12 bytes per tile, that sits at
## INDEX_OFF and runs exactly up to the first record: measured, not assumed,
## 0x100 + 90132 * 12 == 1081840 == the first record offset this class
## already reads below. Kept so entry_offset()/entry_size() report what the
## file SAYS rather than a stride this class assumed.
const INDEX_OFF := 0x100
const INDEX_REC := 12

var _rec: PackedByteArray
var _idx: PackedByteArray
var _n: int

func _init(path: String) -> void:
	var f := FileAccess.open(Pak.resolve(path), FileAccess.READ)
	if f == null:
		push_error("Tiles: cannot open %s (%s)" % [path, error_string(FileAccess.get_open_error())])
		return
	f.seek(4)
	_n = f.get_32()
	# Tile records begin at the offset field of the first index triple
	# at 0x100 ({flags, offset, size}) -- the same value the original
	# Sacred.Pak entry_offset(0) exposed.
	f.seek(INDEX_OFF)
	_idx = f.get_buffer(_n * INDEX_REC)
	var start := _idx.decode_u32(4) if _idx.size() >= 12 else 0
	f.seek(start)
	# 90132 * 64 B = 5.8 MB -- small enough to keep resident, unlike texture.pak.
	_rec = f.get_buffer(_n * RECORD)

func count() -> int:
	return _n

## Byte offset and length of tile `i` AS THE INDEX RECORDS THEM. verify.gd
## prints these so the tiles.pak fact line can be diffed against
## verify_ref.py, whose pak_index() reads the same triples -- Sacred.Pak
## itself refuses this file (ISO magic, dedicated reader), so without these
## the Godot side simply could not emit that line.
func entry_offset(i: int) -> int:
	return _idx.decode_u32(i * INDEX_REC + 4) if i >= 0 and i < _n else 0

func entry_size(i: int) -> int:
	return _idx.decode_u32(i * INDEX_REC + 8) if i >= 0 and i < _n else 0

## The source TGA this tile was cut from, e.g. "iso00.tga". Constant across
## each group of 18, so it names the art rather than the rotation.
func source_name(tile_id: int) -> String:
	var b := _rec.slice(tile_id * 64, tile_id * 64 + 32)
	var z := b.find(0)
	return b.slice(0, z if z >= 0 else 32).get_string_from_ascii()

func texture_id(tile_id: int) -> int:
	return _rec.decode_u32(tile_id * 64 + 0x20)

## ponytail: orientation (+0x24, 0..17) is read but unused -- 18 values is
## more than 4 rotations, so decode it before applying it as a UV transform.
func orientation(tile_id: int) -> int:
	return _rec.decode_u32(tile_id * 64 + 0x24)
