extends RefCounted
## tiles.pak: 64-byte records, one per tile id, giving the texture.pak id.
## ISO magic, NOT a generic PAK container -- read directly from the file
## rather than routing through Sacred.Pak (TOOLCHAIN-AUDIT-2026-08-12).

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
	var f := FileAccess.open(path, FileAccess.READ)
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

func texture_id(tile_id: int) -> int:
	return _rec.decode_u32(tile_id * 64 + 0x20)

## ponytail: orientation (+0x24, 0..17) is read but unused -- 18 values is
## more than 4 rotations, so decode it before applying it as a UV transform.
func orientation(tile_id: int) -> int:
	return _rec.decode_u32(tile_id * 64 + 0x24)
