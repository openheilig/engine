extends SceneTree
## trigger_creature_probe.gd -- READ-ONLY. triggers.pak + creature.pak + chapel props.
##   godot --headless --path godot-port --script res://trigger_creature_probe.gd

const CHAPEL := Rect2i(3213, 2502, 34, 30)

func _init() -> void:
	var install := Sacred.find_install()

	# ---------- triggers.pak ----------
	var tf := FileAccess.open(install.path_join("world/triggers.pak"), FileAccess.READ)
	tf.seek(4)
	var tn := tf.get_32()
	var tlen := tf.get_length()
	print("triggers.pak TRG count=%d file=%d  (len-256)/n=%.4f  len/n=%.4f" % [
		tn, tlen, float(tlen - 256) / tn, float(tlen) / tn])
	tf.seek(0)
	var all := tf.get_buffer(tlen)
	# find where the 0xcc padding ends
	var p: int = 0x100
	while p < tlen and all[p] == 0xcc:
		p += 1
	print("  0xcc padding ends at 0x%x (%d); (len-%d)/n = %.4f" % [p, p, p, float(tlen - p) / tn])
	print("  bytes at data start:")
	for k in 6:
		print("    +%04d %s | %s" % [k * 16, _hex(all.slice(p + k * 16, p + k * 16 + 16)), _asc(all.slice(p + k * 16, p + k * 16 + 16))])
	for stride: int in [12, 16, 20, 24]:
		var off: int = p + 2034 * stride
		if off + stride * 2 > tlen:
			print("  stride %d: record 2034 is past EOF" % stride)
			continue
		print("  stride %d -> rec 2033/2034/2035:" % stride)
		for r: int in [2033, 2034, 2035]:
			var o: int = p + r * stride
			if o + stride <= tlen:
				print("     %d: %s | %s" % [r, _hex(all.slice(o, o + stride)), _asc(all.slice(o, o + stride))])
	print("  last 64 bytes of file: %s" % _hex(all.slice(tlen - 64)))

	# ---------- creature.pak, 86-byte flat stride ----------
	var cf := FileAccess.open(install.path_join("pak/creature.pak"), FileAccess.READ)
	var clen := cf.get_length()
	cf.seek(4)
	var cn := cf.get_32()
	cf.seek(0)
	var cb := cf.get_buffer(clen)
	print("\ncreature.pak CIF count=%d file=%d  (len-256)/n=%.4f" % [cn, clen, float(clen - 256) / cn])
	var STRIDE: int = 86
	print("  assuming flat %d-byte records from 0x100:" % STRIDE)
	var ids := []
	var cls := {}
	for i in cn:
		var o := 0x100 + i * STRIDE
		if o + STRIDE > clen:
			break
		ids.append(cb.decode_u32(o))
		cls[cb.decode_u32(o + 4)] = int(cls.get(cb.decode_u32(o + 4), 0)) + 1
	var seq := 0
	for i in range(1, ids.size()):
		if ids[i] > ids[i - 1]:
			seq += 1
	print("  +0x00 u32 strictly ascending in %d of %d steps  (first=%s last=%s)" % [
		seq, ids.size() - 1, str(ids[0]), str(ids[ids.size() - 1])])
	var ck: Array = cls.keys(); ck.sort()
	print("  +0x04 u32 value histogram: %s" % str(ck.map(func(k): return "%d:%d" % [k, cls[k]])))
	for i: int in [0, 1, 2, 40, 200, 473]:
		var o: int = 0x100 + i * STRIDE
		print("  rec %d @0x%x: %s" % [i, o, _hex(cb.slice(o, o + STRIDE))])

	# ---------- chapel prop detail ----------
	var world := Sacred.World.new(install.path_join("world"))
	var static_pak := Sacred.Pak.new(install.path_join("world/static.pak"))
	var items := Sacred.Items.new(Sacred.Pak.new(install.path_join("pak/items.pak")))
	var mixed := Sacred.Mixed.new(Sacred.Pak.new(install.path_join("pak/mixed.pak")))
	var want := ["MINI_BLUE_1", "MINI_BLUE_4", "MINI_RED_1", "MINI_RED_2", "MINI_RED_4",
		"MINI_YELLOW_1", "MINI_YELLOW_3", "Crates 2", "Crates 5", "Cabinet 3", "sack2",
		"Shelf", "Panel", "MARKET11", "mage_elements_cowl.grn", "Grave 16", "Coalpot 1"]
	print("\n-- sector 50,39 props of interest inside CHAPEL --")
	var stream := world.sector(50, 39)
	var seen := {}
	for c in Sacred.SECT * Sacred.SECT:
		var cur := stream.decode_u32(Sacred.NAME + c * Sacred.CELL + 4)
		var guard := {}
		while cur > 0 and cur < static_pak.count() and not guard.has(cur):
			guard[cur] = true
			if not seen.has(cur):
				seen[cur] = true
				var r := static_pak.blob(cur)
				var t := r.decode_u32(4)
				var nm := items.name_of(t)
				var pos := Vector2(r.decode_s32(0x0e), -r.decode_s32(0x12))
				var cell := Sacred.Footprints._object_cell(pos)
				if nm in want and CHAPEL.has_point(cell):
					var sid := items.sprite_of(t)
					var sp := mixed.sprite(sid)
					print("  %-24s rec=%-8d type=%-6d sprite=%-6d tiles=%-3d size=%-10s anchor=%-10s cell=%s scr=(%d,%d) f8=%d lv=%d int=%s" % [
						nm, cur, t, sid, 0 if sp.is_empty() else (sp["tiles"] as Array).size(),
						"-" if sp.is_empty() else str(sp["size"]),
						"-" if sp.is_empty() else str(sp["anchor"]), str(cell),
						r.decode_s32(0x0e), r.decode_s32(0x12), r.decode_u32(8),
						items.levels(t), items.is_interior(t)])
			cur = static_pak.blob(cur).decode_u32(0x1f)

	# ---------- world-wide .grn static census on a wider band ----------
	print("\n-- .grn statics over sectors 46..54 x 35..43 --")
	var grn_set := {}
	for i in 32768:
		if items.name_of(i).to_lower().ends_with(".grn"):
			grn_set[i] = true
	var tot_st := 0
	var tot_grn := 0
	var trigs := []
	for gy in range(35, 44):
		for gx in range(46, 55):
			var s := world.sector(gx, gy)
			if s.is_empty():
				continue
			var sn := {}
			for c in Sacred.SECT * Sacred.SECT:
				var cur := s.decode_u32(Sacred.NAME + c * Sacred.CELL + 4)
				var g := {}
				while cur > 0 and cur < static_pak.count() and not g.has(cur):
					g[cur] = true
					if not sn.has(cur):
						sn[cur] = true
						tot_st += 1
						var r := static_pak.blob(cur)
						if grn_set.has(r.decode_u32(4)):
							tot_grn += 1
							trigs.append([gx, gy, cur, r.decode_u32(4), r.decode_u32(8),
								r.decode_u32(0x27), items.name_of(r.decode_u32(4))])
					cur = static_pak.blob(cur).decode_u32(0x1f)
	print("  statics=%d  .grn=%d" % [tot_st, tot_grn])
	trigs.sort_custom(func(a, b): return a[5] < b[5])
	for t in trigs:
		print("   sec=%d,%d rec=%-8d type=%-6d f8=%-4d trig=%-6d %s" % [t[0], t[1], t[2], t[3], t[4], t[5], t[6]])
	quit(0)


func _hex(b: PackedByteArray) -> String:
	var s := ""
	for i in b.size():
		s += "%02x" % b[i]
		if i % 4 == 3:
			s += " "
	return s

func _asc(b: PackedByteArray) -> String:
	var s := ""
	for i in b.size():
		s += char(b[i]) if b[i] >= 32 and b[i] < 127 else "."
	return s
