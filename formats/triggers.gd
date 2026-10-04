extends RefCounted
const Pak := preload("res://formats/pak.gd")
## Raw WORLD/TRIGGERS.PAK, not a compressed Pak archive. LGP 0x080EF982 and
## Win 2.28 0x00638570 copy header.u32(+4) sixteen-byte records after 256+12
## bytes. Record +10 is the authored u16 state; zero-filled slots stay zero.

signal state_changed(trigger_id: int, previous: int, state: int)

const TABLE_OFF := 0x10c
const RECORD_SIZE := 16
var _records := PackedByteArray()

func _init(path: String) -> void:
	var file := FileAccess.open(Pak.resolve(path), FileAccess.READ)
	if file == null:
		push_error("Triggers: cannot open %s" % path)
		return
	var header := file.get_buffer(TABLE_OFF)
	if header.size() != TABLE_OFF or header.decode_u32(0) != 0x01475254:
		push_error("Triggers: invalid TRG v1 header in %s" % path)
		return
	var bytes := header.decode_u32(4) * RECORD_SIZE
	if bytes > file.get_length() - TABLE_OFF:
		push_error("Triggers: truncated record table in %s" % path)
		return
	_records = file.get_buffer(bytes)

func count() -> int:
	return _records.size() / RECORD_SIZE

func has_trigger(trigger_id: int) -> bool:
	return trigger_id >= 0 and trigger_id < count()

func record(trigger_id: int) -> Dictionary:
	if not has_trigger(trigger_id):
		push_error("Triggers: missing record %d" % trigger_id)
		return {}
	var offset := trigger_id * RECORD_SIZE
	return {"self": _records.decode_u32(offset), "flags": _records.decode_u16(offset + 4),
		"ref": _records.decode_u32(offset + 6), "state": _records.decode_u16(offset + 10),
		"prerequisite": _records.decode_u32(offset + 12)}

func state(trigger_id: int) -> int:
	if not has_trigger(trigger_id):
		push_error("Triggers: missing state %d (not a null parent)" % trigger_id)
		return -1
	return _records.decode_u16(trigger_id * RECORD_SIZE + 10)

## Whole-state assignment for authored/save/script/runtime snapshots. Unlike
## set_bits/reset_bits, this preserves the exact supplied state, including zero.
func replace_state(trigger_id: int, value: int) -> bool:
	if not has_trigger(trigger_id) or value < 0 or value > 0xffff:
		push_error("Triggers: invalid state assignment %d=%d" % [trigger_id, value])
		return false
	var previous := state(trigger_id)
	if previous != value:
		_records.encode_u16(trigger_id * RECORD_SIZE + 10, value)
		state_changed.emit(trigger_id, previous, value)
	return true

## W2: the whole state array for save/snapshot. 2268 u16 states -- trivial
## to carry whole, and matching retail's own save-everything shape.
func snapshot_states() -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(count())
	for i in count():
		out[i] = _records.decode_u16(i * RECORD_SIZE + 10)
	return out


## Counterpart: restores every state exactly (replace_state keeps zero and
## fires state_changed for the interior's bindings). False if the array is
## the wrong size -- a partial restore would be a silently different world.
func restore_states(states: PackedInt32Array) -> bool:
	if states.size() != count():
		push_error("Triggers: restore size %d != %d" % [states.size(), count()])
		return false
	for i in count():
		replace_state(i, states[i])
	return true


## W2: door open/close, transcribed from the use-object executors
## sub_82E2CF2 / sub_82BAE52: OPEN = setState(state | 1), CLOSE =
## resetState(1) on the door static's OWN trigger (object+52 <- static +39).
## Doors are item category 10; visibility follows free from the exact-mask
## interior admission. The interactive personality (flags & 0x44): a locked
## trigger (state 0x4000 set) refuses, and an unopened door with a nonzero
## prerequisite (+12) refuses too -- retail plays a locked sound there; the
## port has no prerequisite checker yet, so it just refuses (named gap).
## Returns true when the state changed (or was already open).
func open_door(trigger_id: int) -> bool:
	if not has_trigger(trigger_id):
		return false
	var st := state(trigger_id)
	if st & 1:
		return true
	if st & 0x4000:
		return false
	var rec := record(trigger_id)
	if (rec["flags"] & 0x44) != 0 and st == 0 and rec["prerequisite"] != 0:
		return false  # locked: retail plays sounds 331/332 here
	return set_bits(trigger_id, 1)


func close_door(trigger_id: int) -> bool:
	if not has_trigger(trigger_id):
		return false
	if state(trigger_id) & 1 == 0:
		return true
	return reset_bits(trigger_id, 1)


## Ordinary building setters: LGP 0x083A51DA / 0x083A5AC8, cross-build
## Win 0x00415F00 / 0x00416280. Interaction triggers (flags&0x44) additionally
## require the event/prerequisite/delayed-unlock systems, not implemented here.
func set_bits(trigger_id: int, mask: int) -> bool:
	if not _ordinary_update(trigger_id, mask):
		return false
	var value := state(trigger_id)
	if (mask & 0x8000) != 0:
		value |= 0x8000
	if ((value & 0x8000) == 0 or (mask & 1) == 0) and (value & 0x4000) == 0:
		value |= mask
	return replace_state(trigger_id, value)

func reset_bits(trigger_id: int, mask: int) -> bool:
	if not _ordinary_update(trigger_id, mask):
		return false
	var value := state(trigger_id) & ~(mask & 0xc000)
	if (value & 0xc000) == 0:
		value &= ~mask
	return replace_state(trigger_id, value)

func _ordinary_update(trigger_id: int, mask: int) -> bool:
	if not has_trigger(trigger_id) or mask < 0 or mask > 0xffff:
		push_error("Triggers: invalid bit update %d mask=%d" % [trigger_id, mask])
		return false
	if (_records.decode_u16(trigger_id * RECORD_SIZE + 4) & 0x44) != 0:
		push_error("Triggers: interaction events for record %d are not implemented" % trigger_id)
		return false
	return true
