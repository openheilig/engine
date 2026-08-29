extends "res://checks/check.gd"
## walk_no_door_uses_byte26_check.gd -- non-door cells keep the byte-26
## heuristic (`b != 1 && b != 4`); the door-bit branch must NOT touch them.
##
##   godot --headless --path godot-port --script res://checks/walk_no_door_uses_byte26_check.gd
##
## Wire A (rows 1148-1157). A cell whose +0x1e has bit 2 CLEAR (no door
## bit) is governed by the byte-26 fallback: open iff b != 1 && b != 4.
## The test sets byte 26 (+0x1a) = 0 on a door-bit-CLEAR cell and asserts
## open; a second cell with byte 26 = 1 must be blocked.

const SYNTH_DIR := "user://_wire_a_test_no_door"

func _init() -> void:
	super()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SYNTH_DIR))
	_write_world_stream()
	_write_static_pak()
	_write_triggers({})

	var world := Sacred.World.new(SYNTH_DIR)
	var statics := Sacred.Statics.new(Sacred.Pak.new(SYNTH_DIR.path_join("static.pak")))
	var types := Sacred.TriggerType.new(SYNTH_DIR.path_join("triggers.pak"))
	var walk := Walkable.new(world)
	walk.bind_statics_and_types(statics, types)

	expect(walk.is_open(0, 0),
		"non-door cell with byte 26 = 0 must be open (no door path)")
	expect(not walk.is_open(1, 0),
		"non-door cell with byte 26 = 1 must be blocked (b != 1 fails)")

	print("walk_no_door_uses_byte26_check\tOK\tdoor_clear_open=0,0\tdoor_clear_block=1,0")
	finish(0)


func _write_static_pak() -> void:
	var n := 1
	var hdr := PackedByteArray()
	hdr.resize(256)
	hdr[0] = 0x53; hdr[1] = 0x4e; hdr[2] = 0x44
	hdr.encode_u32(4, n)
	var idx := PackedByteArray()
	idx.resize(12 * n)
	idx.encode_u32(0, 0)
	idx.encode_u32(4, 256 + 12 * n)
	idx.encode_u32(8, 64)
	var payload := PackedByteArray()
	for k in 64:
		payload.append(0)
	var f := FileAccess.open(SYNTH_DIR.path_join("static.pak"), FileAccess.WRITE)
	f.store_buffer(hdr)
	f.store_buffer(idx)
	f.store_buffer(payload)
	f.close()


func _write_triggers(type_masks: Dictionary) -> void:
	var max_key := 0
	for k in type_masks.keys():
		if int(k) > max_key:
			max_key = int(k)
	var n := maxi(1, max_key + 1)
	var buf := PackedByteArray()
	buf.resize(0x10c + n * 16)
	buf[0] = 0x54; buf[1] = 0x52; buf[2] = 0x47; buf[3] = 0x01
	buf.encode_u32(4, n)
	buf.encode_u32(0x100, 136)
	buf.encode_u32(0x104, 0x10c)
	buf.encode_u32(0x108, n * 16)
	for i in n:
		var o := 0x10c + i * 16
		buf.encode_u32(o, i)
		buf.encode_u16(o + 4, 0)
		var m: int = int(type_masks.get(i, 0))
		buf.encode_u16(o + 0xa, m & 0xffff)
	var f := FileAccess.open(SYNTH_DIR.path_join("triggers.pak"), FileAccess.WRITE)
	f.store_buffer(buf)
	f.close()


## Appends one 32-byte WldxEntry to `entries`. `byte26` is the value at
## +0x1a, the byte the byte-26 fallback reads. All other fields are zero.
func _append_cell(entries: PackedByteArray, byte26: int) -> PackedByteArray:
	var e := PackedByteArray()
	for k in 32:
		e.append(0)
	e[0x1a] = byte26
	entries.append_array(e)
	return entries


func _write_world_stream() -> void:
	# Cell (0,0): door bit CLEAR, byte 26 = 0 -> open.
	# Cell (1,0): door bit CLEAR, byte 26 = 1 -> blocked.
	var entries := PackedByteArray()
	for i in 64 * 64:
		var is_cell1 := (i == 1)
		var byte26 := 1 if is_cell1 else 0
		entries = _append_cell(entries, byte26)
	var name := PackedByteArray()
	for k in 32:
		name.append(0)
	var stream := PackedByteArray()
	stream.append_array(name)
	stream.append_array(entries)
	var compressed := stream.compress(FileAccess.COMPRESSION_DEFLATE)
	var keyx := PackedByteArray()
	keyx.resize(256 + 768)
	keyx[0] = 0x57; keyx[1] = 0x4c; keyx[2] = 0x4b; keyx[3] = 0x01
	keyx.encode_u32(4, 1)
	keyx.encode_u32(8, 100)
	keyx.encode_u32(12, 100)
	keyx.encode_u32(256 + 32, 0)
	keyx.encode_u32(256 + 236, 0)
	keyx.encode_u32(256 + 240, compressed.size())
	keyx.encode_u32(256 + 264, stream.size())
	var kf := FileAccess.open(SYNTH_DIR.path_join("sectors.keyx"), FileAccess.WRITE)
	kf.store_buffer(keyx)
	kf.close()
	var wf := FileAccess.open(SYNTH_DIR.path_join("sectors.wldx"), FileAccess.WRITE)
	wf.store_buffer(compressed)
	wf.close()
