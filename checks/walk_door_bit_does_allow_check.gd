extends "res://checks/check.gd"
## walk_door_bit_does_allow_check.gd -- door-bit path through Sacred.Walkable
## must ALLOW when the door's collision bitmask has at least one bit in
## common with the type table's mask for the static's type id.
##
##   godot --headless --path godot-port --script res://checks/walk_door_bit_does_allow_check.gd
##
## Wire A (rows 1148-1157). Polarity was corrected by row 1155: walkable
## iff (obj_mask & type_mask) != 0. This file exercises the positive case
## the corrected polarity unlocks.

const SYNTH_DIR := "user://_wire_a_test_allow"
const DOOR_TYPE := 17
const DOOR_OBJ_MASK := 0x0004
const DOOR_TYPE_MASK := 0x000C    # shares bit 2 with obj_mask
const DOOR_FLAGS := 0x200

func _init() -> void:
	super()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SYNTH_DIR))
	_write_world_stream()
	_write_static_pak()
	_write_triggers({DOOR_TYPE: DOOR_TYPE_MASK})

	var world := Sacred.World.new(SYNTH_DIR)
	var statics := Sacred.Statics.new(Sacred.Pak.new(SYNTH_DIR.path_join("static.pak")))
	var types := Sacred.TriggerType.new(SYNTH_DIR.path_join("triggers.pak"))
	var walk := Walkable.new(world)
	walk.bind_statics_and_types(statics, types)

	expect(walk.is_open(0, 0),
		"door-bit cell with obj_mask=0x0004 type_mask=0x000C must be open (intersection = 0x0004)")

	print("walk_door_bit_does_allow_check\tOK\tdoor=open\tmask_intersection=nonzero")
	finish(0)


func _write_static_pak() -> void:
	var n := 2
	var hdr := PackedByteArray()
	hdr.resize(256)
	hdr[0] = 0x53; hdr[1] = 0x4e; hdr[2] = 0x44  # SND
	hdr.encode_u32(4, n)
	var idx := PackedByteArray()
	idx.resize(12 * n)
	idx.encode_u32(0, 0)
	idx.encode_u32(4, 256 + 12 * n)
	idx.encode_u32(8, 64)
	idx.encode_u32(12, 0)
	idx.encode_u32(16, 256 + 12 * n + 64)
	idx.encode_u32(20, 64)
	var payload := PackedByteArray()
	for k in 64:
		payload.append(0)
	var rec := PackedByteArray()
	rec.resize(64)
	rec.encode_u32(0x00, 1)
	rec.encode_u32(0x04, DOOR_TYPE)
	rec.encode_u32(0x08, DOOR_FLAGS)
	rec.encode_u32(0x1f, 0)
	rec.encode_u32(0x27, DOOR_TYPE)
	rec.encode_u32(0x2b, DOOR_OBJ_MASK)
	payload.append_array(rec)
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


func _write_world_stream() -> void:
	var entries := PackedByteArray()
	for i in 64 * 64:
		var is_cell0 := (i == 0)
		entries.append(0); entries.append(0); entries.append(0); entries.append(0)
		entries.append(1); entries.append(0); entries.append(0); entries.append(0)
		entries.append(0); entries.append(0); entries.append(0); entries.append(0)
		entries.append(0); entries.append(0); entries.append(0); entries.append(0)
		entries.append(0); entries.append(0); entries.append(0); entries.append(0)
		entries.append(0); entries.append(0); entries.append(0); entries.append(0)
		entries.append(0); entries.append(0); entries.append(0); entries.append(0)
		entries.append(0); entries.append(0)
		entries.append(0x04 if is_cell0 else 0)
		entries.append(0)
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
