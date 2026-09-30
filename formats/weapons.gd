extends RefCounted
## weapon.pak: WPN v8+, parallel tables of 258-byte and 64-byte rows.
## Generated item definitions inherit in FILE ORDER, not recursively.
## LGP 0x0814D288 / 0x0813B5D8 / 0x0813A398; Gold ENG/RUS 0x004257A0.

const MAX_TYPE := 32351
const HEADER_SIZE := 256
const RECORD_SIZE := 258
const EXTRA_SIZE := 64

var found := false
var _types := PackedInt32Array()
var _parents := PackedInt32Array()

func _init(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("Weapons: cannot open %s" % path)
		return
	var header := file.get_buffer(HEADER_SIZE)
	if header.size() != HEADER_SIZE or header.slice(0, 3).get_string_from_ascii() != "WPN" or header[3] < 8:
		push_error("Weapons: unsupported header in %s" % path)
		return
	var count := header.decode_u32(4)
	if count > (file.get_length() - HEADER_SIZE) / (RECORD_SIZE + EXTRA_SIZE):
		push_error("Weapons: truncated parallel tables in %s" % path)
		return
	_types.resize(count)
	_parents.resize(count)
	for row in count:
		file.seek(HEADER_SIZE + row * RECORD_SIZE)
		var record := file.get_buffer(132)
		_types[row] = record.decode_u32(128)
		_parents[row] = record.decode_u32(36)
	found = true

## Stamp all weapon-row indices BEFORE copying any inherited definition.
## PackedByteArray assignment has value semantics; later parent mutations
## must not retroactively alter an earlier child (nor chase forward links).
func apply_to(definitions: Array[PackedByteArray]) -> void:
	if not found:
		return
	for type in _types:
		if type < 0 or type >= definitions.size() or definitions[type].size() != 128:
			push_error("Weapons: missing item definition %d" % type)
			return
	for row in _types.size():
		var type := _types[row]
		var definition := definitions[type]
		definition.encode_u16(24, row & 0xffff)
		if type == 4053:
			definition[46] = 6
		if definition.decode_u32(32) != 0:
			definition.encode_u32(32, type)
		definitions[type] = definition
	for row in _types.size():
		var type := _types[row]
		var parent := _parents[row]
		if type < 1 or type > MAX_TYPE or parent < 1 or parent > MAX_TYPE:
			continue
		if parent >= definitions.size() or definitions[parent].size() != 128:
			push_error("Weapons: missing parent definition %d" % parent)
			return
		var weapon_row := definitions[type].decode_u16(24)
		var resource := definitions[type].decode_u32(32)
		var inherited := definitions[parent]
		inherited.encode_u16(24, weapon_row)
		inherited.encode_u32(32, type if resource == 0 else resource)
		definitions[type] = inherited
