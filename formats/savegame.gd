class_name Savegame
extends RefCounted
## X1: the retail world-savegame container (Save/gameNN.pak). Proven against
## real bytes by X1SaveRE (tmp/x1-saves/notes.md): an uncompressed "AMS"
## stream -- 256-byte header, then a section index at 0x100 of
## {u32 id, u32 offset, u32 size}; payloads uncompressed, non-contiguous.
## This is the reader SKELETON: header validation, the index, and section
## access by id. The per-section decoders (objects/scripts/world) are the
## named next step.

const HEADER_SIZE := 0x100
const INDEX_OFF := 0x100

## Known section ids (cEngine::load sub_80CCA20's dispatch).
const SEC_ENGINE := 0x80
const SEC_WORLD := 0x81
const SEC_VIEWS := 0x82
const SEC_CALENDAR := 0x8B
const SEC_INVENTORY := 0x8D
const SEC_BLOOD := 0x94
const SEC_REGION_INFO := 0x99
const SEC_TEAM := 0x9A
const SEC_OBJECTS := 0xA0
const SEC_SCRIPTS := 0xA1
const SEC_PARTICLES := 0xA2
const SEC_HERO_BLOB := 0xC3

var found := false
var version := 0
var path := ""
var sections: Dictionary[int, Vector2i] = {}   ## id -> (offset, size)


func _init(path: String) -> void:
	self.path = path
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var head := f.get_buffer(4)
	if head.slice(0, 3).get_string_from_ascii() != "AMS":
		push_error("Savegame: %s is not an AMS stream" % path)
		return
	# "AMS" + u8 version at +3 (27 on the shipped saves), u32 count at +4.
	version = head[3]
	var count := f.get_32()
	if count > 0x40:
		push_error("Savegame: %s declares %d sections" % [path, count])
		return
	f.seek(INDEX_OFF)
	for i in count:
		var id := f.get_32()
		var off := f.get_32()
		var size := f.get_32()
		sections[id] = Vector2i(off, size)
	found = true


const COMPRESSED: PackedInt32Array = [SEC_OBJECTS, SEC_SCRIPTS, SEC_PARTICLES]
const ZLIB_MAGIC := 0xBAADC0DE


## The section bytes for `id`, or an empty buffer when absent.
## 0xA0/0xA1/0xA2 are zlib-compressed on disk: [0xBAADC0DE][csize][24
## zeros][zlib stream]; the index size is the UNCOMPRESSED size
## (X1ObjectsRE). Other sections are raw.
func section(id: int) -> PackedByteArray:
	if not sections.has(id):
		return PackedByteArray()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	var where: Vector2i = sections[id]
	f.seek(where.x)
	if not COMPRESSED.has(id):
		return f.get_buffer(where.y)
	if f.get_32() != ZLIB_MAGIC:
		push_error("Savegame: section 0x%02x lacks the compressed framing" % id)
		return PackedByteArray()
	var csize := f.get_32()
	f.seek(f.get_position() + 24)  # reserved zeros; the stream starts at +0x20
	return f.get_buffer(csize).decompress(where.y, FileAccess.COMPRESSION_DEFLATE)


## X1: a skeleton walk of the 0xA0 OBJECTS section. Returns
## {count, walked, families, desync_slot} -- bodies are skipped by
## dword-scanning for the 0xDEADC0DE end marker, which desyncs when a body
## embeds that value as data (slot 384 on the shipped save; the rigorous
## skip needs per-family sizes from the factory table).
func walk_objects() -> Dictionary:
	var payload := section(SEC_OBJECTS)
	if payload.is_empty():
		return {}
	var p := 0
	if payload.decode_u32(p) != 0x80:
		return {}
	p += 4
	var count := payload.decode_u32(p)
	p += 4
	var families: Dictionary = {}
	var walked := 0
	var desync := -1
	for i in count:
		if p + 4 > payload.size():
			desync = i; break
		var family := payload.decode_u32(p)
		p += 4
		if family == 0:
			continue
		if p + 4 > payload.size() or payload.decode_u32(p) != 0xBAADBEEF:
			desync = i; break
		p += 4
		var scan := p
		while scan + 4 <= payload.size() and payload.decode_u32(scan) != 0xDEADC0DE:
			scan += 4
		if scan + 4 > payload.size():
			desync = i; break
		families[family] = int(families.get(family, 0)) + 1
		walked += 1
		p = scan + 4
	return {"count": count, "walked": walked, "families": families,
		"desync_slot": desync}


func has_section(id: int) -> bool:
	return sections.has(id)


## X1: the 0x8B calendar section (34 bytes on the shipped save), decoded
## structurally: seven u16-ish fields, two floats, and the 0xDEADC0DE
## end sentinel. The fields' SEMANTICS (in-game day/hour/...) are not
## pinned yet -- raw values only, no invented names.
func calendar() -> Dictionary:
	var b := section(SEC_CALENDAR)
	if b.size() < 34:
		return {}
	return {
		"i0": b.decode_u32(0), "f4": b.decode_float(4),
		"i8": b.decode_u32(8),
		"w12": b.decode_u16(12), "w14": b.decode_u16(14),
		"w16": b.decode_u16(16), "w18": b.decode_u16(18),
		"f20": b.decode_float(20),
		"end_sentinel": b.decode_u32(30) == 0xDEADC0DE,
	}


## X1: the 0x80 Engine section (64 bytes on the shipped save), decoded
## structurally: u16 0x0444, u16 0, u16 0x042F, u16 1, u16 1, u16 0,
## the 0xFACEDEAD sentinel, then the CURRENT WORLD PATH ("WORLD\" on the
## shipped save) in a fixed field -- which world the save belongs to.
func engine() -> Dictionary:
	var b := section(SEC_ENGINE)
	if b.size() < 64:
		return {}
	var end_sentinel := b.decode_u32(14)
	var world_path := b.slice(20, 52).get_string_from_ascii()
	var dot := world_path.find(".")
	if dot >= 0:
		world_path = world_path.substr(0, dot)
	return {"w0": b.decode_u16(0), "w6": b.decode_u16(6),
		"world_path": world_path.strip_edges(),
		"end_sentinel": end_sentinel == 0xFACEDEAD}




## X1: the 0x8D inventory section (raw, 142,341 bytes on the shipped
## save), decoded per the byte-validated layout (tmp/x1-saves/inventory.md):
## u32 count (32), then count records of {u32 0xDEADC0DE sentinel + 4436
## fixed bytes + quest/scroll arrays} + u8 terminator. Each record's 20x8
## item grid holds 256 12-byte slots {u32 objectRef, u8 x, u8 y, u8 count,
## u8 pad, u16 value}; ref 0 = empty. Returns {} when absent.
func inventory() -> Array:
	var b := section(SEC_INVENTORY)
	if b.size() < 8:
		return []
	var count := b.decode_u32(0)
	var out: Array = []
	var p := 4
	for k in count:
		if p + 4 > b.size() or b.decode_u32(p) != 0xDEADC0DE:
			return out  # desync: report what walked so far
		p += 4
		var rec: Dictionary = {"owner_slot": b.decode_u16(p), "grid_w": 0,
			"grid_h": 0, "items": []}
		# header u16s at +0..+11: owner, flags, ?, ?, gridW, gridH
		rec["grid_w"] = b.decode_u16(p + 8)
		rec["grid_h"] = b.decode_u16(p + 10)
		# item grid: 256 12-byte slots at fixed offset +4020 within the
		# record's fixed block (4436 = 12 header + 1024 blob + 3072 grid
		# + 120 equipment + 200 blob + 8 u32s -- grid at +12+1024 = +1036
		# from the fixed-block start, i.e. p+12+1024 after the sentinel).
		var grid := p + 12 + 1024
		for s in 256:
			var base := grid + s * 12
			var ref := b.decode_u32(base)
			if ref == 0:
				continue
			rec["items"].append({"ref": ref,
				"x": b[base + 4], "y": b[base + 5], "count": b[base + 6],
				"value": b.decode_u16(base + 10)})
		out.append(rec)
		# advance: 4436 fixed + quest array (u32 n + n*8) + scroll array
		# (u32 n + n*4)
		p += 4436
		if p + 4 > b.size():
			return out
		var nq := b.decode_u32(p)
		p += 4 + 8 * nq
		if p + 4 > b.size():
			return out
		var ns := b.decode_u32(p)
		p += 4 + 4 * ns
	return out


## X1: the 0xC3 hero blob decoder, transcribed from game01.pak's real
## bytes: +0 u32 (slot/count, 2 on the shipped save), +4 u32 class type
## (1 = Seraphim, the GetTypeName numbering), +8 a fixed-width UTF-16LE
## name. Returns {} when the section is absent.
func hero_blob() -> Dictionary:
	var b := section(SEC_HERO_BLOB)
	if b.size() < 12:
		return {}
	var name := ""
	var start := 8
	var end := b.size()
	# The name runs until a UTF-16 zero terminator (the rest of the blob is
	# portart/face data).
	var i := start
	while i + 1 < end:
		if b[i] == 0 and b[i + 1] == 0:
			name = b.slice(start, i).get_string_from_utf16()
			break
		i += 2
	if name == "":
		name = b.slice(start, end).get_string_from_utf16()
	return {"count": b.decode_u32(0), "class_type": b.decode_u32(4), "name": name}
