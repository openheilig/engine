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
## Physical extents, derived once from distinct active offsets (not index
## order). TEX and MDL kind64 sizes are metadata, not reliable disk lengths.
var _physical_sizes := PackedInt64Array()
var _magic := ""
## Index record's first u32 (kind/flags). Added for models.pak, whose 4993
## entries split 1572/3421 between two structurally different payload
## kinds (64 mesh, 65 motion) sharing one index -- every other pak has one
## shape, so nothing before Sacred.Models needed this field kept.
var kinds := PackedInt32Array()
var _f: FileAccess
## The archive path as opened -- cache keys and diagnostics.
var path := ""
## Logical install path, retained for dependent archives that may fall through.
var requested_path := ""
## True when this archive was served from the mod overlay, not the install.
var from_mod := false

## One fully validated D1 profile, mounted before any archive opens.
## RefCounted avoids a preload cycle with ModManifest's PAK preflight.
static var _profile: RefCounted
const MAX_INDEX_BYTES := 128 * 1024 * 1024

static func configure_profile(profile: RefCounted) -> String:
	if profile == null or not profile.ok():
		return "cannot mount invalid data profile" if profile == null else profile.error_text()
	_profile = profile
	return ""

static func clear_profile() -> void:
	_profile = null

static func content_identity(install_path: String = "") -> Dictionary:
	if _profile == null or (install_path != "" and not _profile.matches_install(install_path)):
		return {}
	return _profile.identity()

## Also used by dedicated data/retail-bytecode readers, never ResourceLoader.
static func resolve(archive_path: String) -> String:
	return archive_path if _profile == null else _profile.resolve(archive_path)

## D1 preflight checks index bounds without allocating payloads. Dedicated
## ISO/TRG/WPN-parallel/PAX readers retain their own format contracts.
static func validate_archive(archive_path: String, extra_magic: String = "") -> String:
	var file := FileAccess.open(archive_path, FileAccess.READ)
	if file == null:
		return "cannot open archive: %s" % archive_path
	var problem := _validate_index(file, extra_magic, {})
	file.close()
	return "" if problem == "" else "%s: %s" % [archive_path, problem]

static func _validate_index(file: FileAccess, extra_magic: String, parsed: Dictionary) -> String:
	var length := file.get_length()
	if length < Common.PAK_HDR:
		return "truncated PAK header"
	file.seek(0)
	var magic := file.get_buffer(4).get_string_from_ascii().substr(0, 3)
	if not ALLOWED_MAGIC.has(magic) and (extra_magic == "" or magic != extra_magic):
		return "non-PAK magic %s -- use the dedicated reader" % magic
	var count := file.get_32()
	var index_bytes := count * Common.PAK_IDX
	if index_bytes > MAX_INDEX_BYTES or index_bytes > length - Common.PAK_HDR:
		return "PAK index exceeds file/resource bounds"
	file.seek(Common.PAK_HDR)
	var index_end := Common.PAK_HDR + index_bytes
	var offsets_out := PackedInt64Array()
	var sizes_out := PackedInt64Array()
	var kinds_out := PackedInt32Array()
	offsets_out.resize(count)
	sizes_out.resize(count)
	kinds_out.resize(count)
	# Only bounded index metadata is resident; payloads stay on demand.
	var remaining := count
	while remaining > 0:
		var entries := mini(remaining, 4096)
		var index := file.get_buffer(entries * Common.PAK_IDX)
		if index.size() != entries * Common.PAK_IDX:
			return "truncated PAK index"
		for i in entries:
			var record := count - remaining + i
			var kind := index.decode_u32(i * Common.PAK_IDX)
			var offset := index.decode_u32(i * Common.PAK_IDX + 4)
			var size := index.decode_u32(i * Common.PAK_IDX + 8)
			if offset > length:
				return "PAK record %d offset exceeds file bounds" % record
			if size > 0 and offset < index_end:
				return "PAK record %d overlaps header/index" % record
			offsets_out[record] = offset
			sizes_out[record] = size
			kinds_out[record] = kind
		remaining -= entries
	var physical := _physical_extents(offsets_out, index_end, length)
	for i in count:
		var metadata_size := magic == "TEX" or (magic == "MDL" and kinds_out[i] == 64)
		if not metadata_size and sizes_out[i] > physical[i]:
			return "PAK record %d declared bytes exceed physical entry bounds" % i
		if metadata_size and sizes_out[i] > 0 and physical[i] <= 0:
			return "PAK record %d has no physical payload" % i
		# TEX width/height/format at +32/+34/+36 must belong to this entry.
		if magic == "TEX" and sizes_out[i] > 0 and physical[i] < 37:
			return "TEX record %d has a truncated texture header" % i
	parsed["offsets"] = offsets_out
	parsed["sizes"] = sizes_out
	parsed["kinds"] = kinds_out
	parsed["physical"] = physical
	parsed["magic"] = magic
	return ""

## Vanilla indexes are ascending: derive spans in one reverse pass. Reordered
## indexes sort once and binary-search the next DISTINCT offset; aliases get
## the same extent. Zero/header sentinel offsets never delimit real payloads.
static func _physical_extents(index_offsets: PackedInt64Array, index_end: int,
		length: int) -> PackedInt64Array:
	var result := PackedInt64Array()
	result.resize(index_offsets.size())
	var ascending := true
	var previous := -1
	for offset in index_offsets:
		if offset < index_end:
			continue
		if offset < previous:
			ascending = false
			break
		previous = offset
	if ascending:
		var next := length
		previous = -1
		var span := 0
		for i in range(index_offsets.size() - 1, -1, -1):
			var offset := index_offsets[i]
			if offset < index_end:
				continue
			if offset != previous:
				span = next - offset
				next = offset
				previous = offset
			result[i] = span
	else:
		var ordered := index_offsets.duplicate()
		ordered.sort()
		for i in index_offsets.size():
			var offset := index_offsets[i]
			if offset < index_end:
				continue
			var successor := ordered.bsearch(offset, false)
			var next: int = ordered[successor] if successor < ordered.size() else length
			result[i] = next - offset
	return result

## Did the overlay serve this archive?
func is_mod() -> bool:
	return from_mod


func _init(archive_path: String) -> void:
	requested_path = archive_path
	var open_path := resolve(archive_path)
	from_mod = _profile != null and _profile.is_mod_archive(archive_path)
	path = open_path
	_f = FileAccess.open(path, FileAccess.READ)
	if _f == null:
		push_error("Pak: cannot open %s (%s)" % [path, error_string(FileAccess.get_open_error())])
		return
	var parsed: Dictionary = {}
	var problem := _validate_index(_f, "", parsed)
	if problem != "":
		push_error("Pak: %s: %s" % [path, problem])
		_f = null
		return
	offsets = parsed["offsets"]
	sizes = parsed["sizes"]
	kinds = parsed["kinds"]
	_physical_sizes = parsed["physical"]
	_magic = parsed["magic"]

func is_open() -> bool:
	return _f != null

func source_path() -> String:
	return _f.get_path() if _f != null else ""

func count() -> int:
	return offsets.size()

## Ordinary archives read declared bytes plus `extra`, strictly inside their
## physical entry. TEX (and MDL mesh metadata) reads the complete physical
## extent instead: TEX index sizes can be compressed OR inflated extents.
## This includes the texture header, never bytes borrowed from another entry.
func blob(i: int, extra: int = 0) -> PackedByteArray:
	if _f == null or i < 0 or i >= sizes.size() or extra < 0:
		push_error("Pak: invalid record/range in %s: %d + %d" % [path, i, extra])
		return PackedByteArray()
	var metadata_size := _magic == "TEX" or (_magic == "MDL" and kinds[i] == 64)
	var length := _physical_sizes[i] if metadata_size else sizes[i] + extra
	if length > _physical_sizes[i]:
		push_error("Pak: record read exceeds physical entry in %s: %d + %d" % [path, i, extra])
		return PackedByteArray()
	_f.seek(offsets[i])
	return _f.get_buffer(length)

func read_at(off: int, n: int) -> PackedByteArray:
	if _f == null or off < 0 or n < 0 or off > _f.get_length() \
			or n > _f.get_length() - off:
		push_error("Pak: invalid byte range in %s: %d + %d" % [path, off, n])
		return PackedByteArray()
	_f.seek(off)
	return _f.get_buffer(n)

func entry_offset(i: int) -> int:
	return offsets[i] if i >= 0 and i < offsets.size() else -1

func physical_size(i: int) -> int:
	return _physical_sizes[i] if i >= 0 and i < _physical_sizes.size() else 0

## Byte length of the opened archive, or 0 if no file is open. Needed by
## Sacred.Models.true_length() for the last entry, which has no successor
## offset to subtract against.
func file_size() -> int:
	return _f.get_length() if _f != null else 0
