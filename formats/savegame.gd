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


## The section bytes for `id`, or an empty buffer when absent.
func section(id: int) -> PackedByteArray:
	if not sections.has(id):
		return PackedByteArray()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	var where: Vector2i = sections[id]
	f.seek(where.x)
	return f.get_buffer(where.y)


func has_section(id: int) -> bool:
	return sections.has(id)
