extends RefCounted
## A .pak archive, read on demand. texture.pak is 820 MB -- nothing here ever
## slurps the whole file.

const Common := preload("res://formats/common.gd")

## Magic allowlist (TOOLCHAIN-AUDIT-2026-08-12): only these signatures are
## the generic {u32 count @4, 12-byte index @0x100} container. Files with
## other magics (tiles ISO, triggers TRG, tmp caches) must use their own
## readers; routing them here silently misreads the index.
const ALLOWED_MAGIC := {
	"SND": true, "TEX": true, "MDL": true, "MIX": true, "ITM": true,
	"OBJ": true, "CIF": true, "WPN": true, "MHP": true, "SPF": true,
}
var offsets := PackedInt64Array()
var sizes := PackedInt64Array()
## Index record's first u32 (kind/flags). Added for models.pak, whose 4993
## entries split 1572/3421 between two structurally different payload
## kinds (64 mesh, 65 motion) sharing one index -- every other pak has one
## shape, so nothing before Sacred.Models needed this field kept.
var kinds := PackedInt32Array()
var _f: FileAccess
## The archive path as opened -- cache keys and diagnostics.
var path := ""

func _init(archive_path: String) -> void:
	path = archive_path
	_f = FileAccess.open(path, FileAccess.READ)
	if _f == null:
		push_error("Pak: cannot open %s (%s)" % [path, error_string(FileAccess.get_open_error())])
		return
	# Fourth byte is the format version (TEX\x03, ITM\x05, ...); compare
	# only the three-letter signature.
	var magic := _f.get_buffer(4).get_string_from_ascii().substr(0, 3)
	if not ALLOWED_MAGIC.has(magic):
		push_error("Pak: %s has non-PAK magic %s -- use the dedicated reader" % [path, magic])
		_f = null
		return
	_f.seek(4)
	var n := _f.get_32()
	_f.seek(Common.PAK_HDR)
	var idx := _f.get_buffer(n * Common.PAK_IDX)
	offsets.resize(n)
	sizes.resize(n)
	kinds.resize(n)
	for i in n:
		kinds[i] = idx.decode_u32(i * Common.PAK_IDX + 0)
		offsets[i] = idx.decode_u32(i * Common.PAK_IDX + 4)
		sizes[i] = idx.decode_u32(i * Common.PAK_IDX + 8)

func is_open() -> bool:
	return _f != null

func source_path() -> String:
	return _f.get_path() if _f != null else ""

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
