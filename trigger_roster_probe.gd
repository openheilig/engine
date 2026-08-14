extends SceneTree
## trigger_roster_probe.gd -- READ-ONLY. What is the complete roster of
## trigger-owned (dynamic) objects in the world, and where are the chests?
##   godot --headless --path godot-port --script res://trigger_roster_probe.gd

const BASE := 0x10c
const STRIDE := 16

func _init() -> void:
	var install := Sacred.find_install()
	var static_pak := Sacred.Pak.new(install.path_join("world/static.pak"))
	var items := Sacred.Items.new(Sacred.Pak.new(install.path_join("pak/items.pak")))

	var tf := FileAccess.open(install.path_join("world/triggers.pak"), FileAccess.READ)
	tf.seek(4)
	var tn := tf.get_32()
	tf.seek(0)
	var t := tf.get_buffer(tf.get_length())

	var names := {}
	var live := 0
	var chest_trigs: Array = []
	for i in tn:
		var o := BASE + i * STRIDE
		if t.decode_u16(o + 4) != 16:
			continue
		live += 1
		var v := t.decode_u32(o + 6)
		if v <= 0 or v >= static_pak.count():
			continue
		var r := static_pak.blob(v)
		var typ := r.decode_u32(4)
		var nm := items.name_of(typ)
		names[nm] = int(names.get(nm, 0)) + 1
		if nm.to_lower().begins_with("chest") or nm.to_lower().contains("truhe"):
			chest_trigs.append([i, v, typ, nm, Vector2(r.decode_s32(0x0e), -r.decode_s32(0x12))])
	print("live triggers (+0x04==16): %d of %d" % [live, tn])
	var k: Array = names.keys()
	k.sort_custom(func(a, b): return names[a] > names[b])
	print("distinct target names: %d" % k.size())
	print("-- all trigger target names, by count --")
	for x in k:
		print("   %-38s x%d" % [x, names[x]])
	print("\n-- chest*.grn trigger placements world-wide: %d --" % chest_trigs.size())
	for c: Array in chest_trigs:
		var pos: Vector2 = c[4]
		var cell: Vector2i = Sacred.Footprints._object_cell(pos)
		print("   trig=%-6d static=%-8d type=%-6d cell=%s sector=%d,%d  %s" % [
			c[0], c[1], c[2], str(cell), cell.x / 64, cell.y / 64, c[3]])

	# --- brute scan: EVERY static in static.pak whose type is a chest*.grn ---
	print("\n-- brute scan of all %d static.pak records for chest*.grn types --" % static_pak.count())
	var chest_types := {}
	for i in 32768:
		var nm := items.name_of(i).to_lower()
		if nm.begins_with("chest") and nm.ends_with(".grn"):
			chest_types[i] = items.name_of(i)
	print("   chest*.grn items records: %s" % str(chest_types.keys()))
	var f := FileAccess.open(install.path_join("world/static.pak"), FileAccess.READ)
	var n := static_pak.count()
	var found := 0
	var near: Array = []
	var CH := 1 << 16
	var idx := 0
	while idx < n:
		var batch := mini(CH, n - idx)
		f.seek(static_pak.entry_offset(idx))
		var buf := f.get_buffer(batch * 64)
		for j in batch:
			var typ := buf.decode_u32(j * 64 + 4)
			if chest_types.has(typ):
				found += 1
				var pos := Vector2(buf.decode_s32(j * 64 + 0x0e), -buf.decode_s32(j * 64 + 0x12))
				var cell := Sacred.Footprints._object_cell(pos)
				if found <= 40:
					print("   rec=%-8d type=%-6d %-14s cell=%s sector=%d,%d f8=%d trig=%d" % [
						idx + j, typ, chest_types[typ], str(cell), cell.x / 64, cell.y / 64,
						buf.decode_u32(j * 64 + 8), buf.decode_u32(j * 64 + 0x27)])
				if absi(cell.x - 3230) < 200 and absi(cell.y - 2517) < 200:
					near.append([idx + j, typ, cell])
		idx += batch
	print("   total chest*.grn statics in world: %d" % found)
	print("   within 200 cells of the chapel: %d" % near.size())
	for x: Array in near:
		print("     rec=%d type=%d cell=%s sector=%d,%d" % [x[0], x[1], str(x[2]),
			(x[2] as Vector2i).x / 64, (x[2] as Vector2i).y / 64])
	quit(0)
