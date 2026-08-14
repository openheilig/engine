extends RefCounted
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
		push_error("Pax: cannot open %s (%s)" % [path, error_string(FileAccess.get_open_error())])
		return
	if _f.get_32() != MAGIC:
		push_error("Pax: %s is not a PAX hero file" % path)
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
		push_error("Pax: section 0x%X inflated to %d, expected %d" % [type_id, out.size(), usz])
		return PackedByteArray()
	return out
