extends "res://checks/check.gd"
## walk_door_bit_doesnt_allow_check.gd -- door-bit path through Sacred.Walkable
## must BLOCK when the door's collision bitmask shares NO bit with the type
## table's mask for the static's type id.
##
##   godot --headless --path godot-port --script res://checks/walk_door_bit_doesnt_allow_check.gd
##
## Wire A (rows 1148-1157). Synthetic data at user://. The static.pak is
## written in the real Sacred.Pak container format (256-byte header, count,
## 12-byte index entries, payload bytes), using the SND magic the Pak reader
## allows -- the magic is only checked against the allowlist, never read
## into the payload walk the rest of the project does. The triggers.pak is a
## genuine TRG v1 file: 0x100 header, count, 16-byte entries. The world is
## one sector whose (0,0) cell carries the door bit (WldxEntry +0x1e bit 2)
## and the static chain head +0x04 pointing at the synthetic door record.
##
## Object mask = 0x0001 and type mask = 0 -> zero intersection -> BLOCKED.

const SYNTH_DIR := "user://_wire_a_test_deny"

const DOOR_TYPE := 17
const DOOR_OBJ_MASK := 0x0001
const DOOR_FLAGS := 0x200

func _init() -> void:
	super()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SYNTH_DIR))
	_write_world_stream()
	_write_static_pak()
	# Door type 17 mask = 0 -> (obj_mask & type_mask) = 0 -> blocked.
	_write_triggers({DOOR_TYPE: 0x0000})

	var world := Sacred.World.new(SYNTH_DIR)
	var statics := Sacred.Statics.new(Sacred.Pak.new(SYNTH_DIR.path_join("static.pak")))
	var types := Sacred.TriggerType.new(SYNTH_DIR.path_join("triggers.pak"))
	var walk := Walkable.new(world)
	walk.bind_statics_and_types(statics, types)

	expect(not walk.is_open(0, 0),
		"door-bit cell with obj_mask=0x0001 type_mask=0 must be blocked, not opened by byte26")

	print("walk_door_bit_doesnt_allow_check\tOK\tdoor=blocked")
	finish(0)


func _write_static_pak() -> void:
	# Real Sacred.Pak container: 256-byte header + 12-byte index entries +
	# payload. SND magic passes the allowlist; payload bytes are read verbatim.
	var n := 2
	var hdr := PackedByteArray()
	hdr.resize(256)
	hdr[0] = 0x53; hdr[1] = 0x4e; hdr[2] = 0x44
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
	# Build the per-cell 32-byte WldxEntry grid first, then the keyx + wldx
	# container around it. Cell (0,0) carries the door bit (WldxEntry +0x1e
	# bit 2) and a static chain head pointing at the synthetic door record;
	# every other cell is empty outdoor ground.
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
