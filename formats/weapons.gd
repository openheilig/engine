extends RefCounted
## weapon.pak: WPN v8+, parallel tables of 258-byte and 64-byte rows.
## Generated item definitions inherit in FILE ORDER, not recursively.
## LGP 0x0814D288 / 0x0813B5D8 / 0x0813A398; Gold ENG/RUS 0x004257A0.

const MAX_TYPE := 32351
const HEADER_SIZE := 256
const RECORD_SIZE := 258
const EXTRA_SIZE := 64
const Pak := preload("res://formats/pak.gd")

var found := false
var _types := PackedInt32Array()
var _parents := PackedInt32Array()
var _req := PackedInt32Array()
var _level := PackedInt32Array()
var _row_of_type: Dictionary = {}

func _init(path: String) -> void:
	path = Pak.resolve(path)
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
	_req.resize(count)
	_level.resize(count)
	for row in count:
		file.seek(HEADER_SIZE + row * RECORD_SIZE)
		# 154 bytes: +148 is the REQUIRED level and +153 the ITEM level --
		# the pair TypeManager::getRandomItem's window filters on
		# (tmp/e2-loot/item-level.md; sub_814D1CC returns the raw 258-byte
		# weapon.pak row, so those offsets are file bytes).
		var record := file.get_buffer(154)
		_types[row] = record.decode_u32(128)
		_parents[row] = record.decode_u32(36)
		_req[row] = record[148]
		_level[row] = record[153]
		var t := _types[row]
		if t > 0:
			# Retail's load stamps the reverse index per row, so the LAST row
			# wins (loadWeaponInfo's u16 stamp at items base + type*128 + 40).
			_row_of_type[t] = row
	found = true

## E2: the weapon row carrying an items.pak type's stats, -1 when none.
func row_for_type(type: int) -> int:
	return _row_of_type.get(type, -1)

## Required level (weapon.pak row +148).
func req_level(row: int) -> int:
	return _req[row] if row >= 0 and row < _req.size() else 0

## Item level (weapon.pak row +153) -- the level getRandomItem's window
## filters on.
func item_level(row: int) -> int:
	return _level[row] if row >= 0 and row < _level.size() else 0

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
