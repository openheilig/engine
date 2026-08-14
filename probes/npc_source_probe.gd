extends SceneTree
## npc_source_probe.gd -- READ-ONLY. Where do NPCs come from?
##
##   godot --headless --path godot-port --script res://probes/npc_source_probe.gd
##
## 1. every items.pak record whose name ends .grn  (model-backed placements)
## 2. how many such statics exist in sector 50,39 and the 3x3 ring
## 3. creature.pak (CIF, 474 entries) structure sniff
## 4. triggers.pak (TRG v1) record for trigger 2034
## 5. detail dump of the chapel's candidate "chest" props

const CHAPEL := Rect2i(3213, 2502, 34, 30)

func _init() -> void:
	var install := Sacred.find_install()
	var world := Sacred.World.new(install.path_join("world"))
	var static_pak := Sacred.Pak.new(install.path_join("world/static.pak"))
	var items_pak := Sacred.Pak.new(install.path_join("pak/items.pak"))
	var items := Sacred.Items.new(items_pak)
	var mixed := Sacred.Mixed.new(Sacred.Pak.new(install.path_join("pak/mixed.pak")))

	# ---------- 1. .grn-named items records ----------
	var grn: Array = []
	for i in items_pak.count():
		var nm := items.name_of(i)
		if nm.to_lower().ends_with(".grn"):
			grn.append(i)
	print("items.pak records whose name ends .grn: %d of %d" % [grn.size(), items_pak.count()])
	print("  id range %d..%d" % [grn[0], grn[grn.size() - 1]])
	print("  first 20:")
	for i in grn.slice(0, 20):
		print("    rec=%-6d sprite=%-6d name=%s" % [i, items.sprite_of(i), items.name_of(i)])
	print("  around 3489:")
	for i in grn:
		if absi(i - 3489) <= 6:
			print("    rec=%-6d sprite=%-6d name=%s" % [i, items.sprite_of(i), items.name_of(i)])
	# how many .grn records carry mixed art at all
	var grn_art := 0
	for i in grn:
		if not mixed.sprite(items.sprite_of(i)).is_empty():
			grn_art += 1
	print("  .grn records that resolve to mixed art: %d of %d" % [grn_art, grn.size()])
	# contiguity: is the .grn block a solid range?
	var lo: int = grn[0]
	var hi: int = grn[grn.size() - 1]
	print("  named records in [%d..%d] that are NOT .grn:" % [lo, hi])
	var notgrn := 0
	for i in range(lo, hi + 1):
		var nm := items.name_of(i)
		if nm != "" and not nm.to_lower().ends_with(".grn"):
			notgrn += 1
			if notgrn <= 15:
				print("    rec=%-6d name=%s" % [i, nm])
	print("    total=%d" % notgrn)

	# ---------- 2. .grn statics placed in the ring ----------
	print("\n-- .grn-named statics placed, by sector --")
	var grn_set := {}
	for i in grn:
		grn_set[i] = true
	for gy in range(38, 41):
		for gx in range(49, 52):
			var stream := world.sector(gx, gy)
			if stream.is_empty():
				continue
			var seen := {}
			var hits: Array = []
			var tot := 0
			for c in Sacred.SECT * Sacred.SECT:
				var cur := stream.decode_u32(Sacred.NAME + c * Sacred.CELL + 4)
				var guard := {}
				while cur > 0 and cur < static_pak.count() and not guard.has(cur):
					guard[cur] = true
					if not seen.has(cur):
						seen[cur] = true
						tot += 1
						var r := static_pak.blob(cur)
						if grn_set.has(r.decode_u32(4)):
							hits.append({"rec": cur, "type": r.decode_u32(4),
								"f8": r.decode_u32(8), "trig": r.decode_u32(0x27),
								"fC": r.decode_s16(0x0c), "u16": r.decode_u8(0x16),
								"pos": Vector2(r.decode_s32(0x0e), -r.decode_s32(0x12))})
					cur = static_pak.blob(cur).decode_u32(0x1f)
			print("sector %d,%d\tstatics=%d\tgrn=%d" % [gx, gy, tot, hits.size()])
			for h in hits:
				var cell: Vector2i = Sacred.Footprints._object_cell(h["pos"])
				print("    rec=%-8d type=%-6d f8=%-4d fC=%-6d u16=%-4d trig=%-6d cell=%s in_chapel=%s  %s" % [
					h["rec"], h["type"], h["f8"], h["fC"], h["u16"], h["trig"], str(cell),
					CHAPEL.has_point(cell), items.name_of(h["type"])])

	# ---------- 3. creature.pak ----------
	print("\n-- creature.pak --")
	var cf := FileAccess.open(install.path_join("pak/creature.pak"), FileAccess.READ)
	cf.seek(4)
	var cn := cf.get_32()
	print("  magic=CIF count=%d file=%d" % [cn, cf.get_length()])
	cf.seek(0x100)
	var cidx := cf.get_buffer(cn * 12)
	var off0 := cidx.decode_u32(4)
	var sz0 := cidx.decode_u32(8)
	print("  index[0]={kind=%d off=%d size=%d} index[1]={%d,%d,%d} index[%d]={%d,%d,%d}" % [
		cidx.decode_u32(0), off0, sz0,
		cidx.decode_u32(12), cidx.decode_u32(16), cidx.decode_u32(20),
		cn - 1, cidx.decode_u32((cn - 1) * 12), cidx.decode_u32((cn - 1) * 12 + 4),
		cidx.decode_u32((cn - 1) * 12 + 8)])
	var szs := {}
	for i in cn:
		szs[cidx.decode_u32(i * 12 + 8)] = int(szs.get(cidx.decode_u32(i * 12 + 8), 0)) + 1
	print("  record sizes: %s" % str(szs))
	for i in [0, 1, 2, 3, 100, 473]:
		cf.seek(cidx.decode_u32(i * 12 + 4))
		var b := cf.get_buffer(cidx.decode_u32(i * 12 + 8))
		print("  rec %d: %s" % [i, _hex(b)])
		print("        ascii: %s" % _asc(b))

	# ---------- 4. triggers.pak ----------
	print("\n-- triggers.pak --")
	var tf := FileAccess.open(install.path_join("world/triggers.pak"), FileAccess.READ)
	tf.seek(4)
	var tn := tf.get_32()
	var tlen := tf.get_length()
	print("  magic=TRG count=%d file=%d  (file-256)/count=%.3f" % [tn, tlen, float(tlen - 256) / tn])
	for stride in [12, 16, 20]:
		print("  -- assuming stride %d, record 2034 --" % stride)
		tf.seek(256 + 2034 * stride)
		print("     %s" % _hex(tf.get_buffer(stride * 2)))
	tf.seek(256)
	print("  first 96 bytes after header: %s" % _hex(tf.get_buffer(96)))

	# ---------- 5. chapel prop detail ----------
	print("\n-- chapel props of interest (detail) --")
	var want := ["MINI_BLUE_1", "MINI_BLUE_4", "MINI_RED_1", "MINI_RED_2", "MINI_RED_4",
		"MINI_YELLOW_1", "MINI_YELLOW_3", "Crates 2", "Crates 5", "Cabinet 3", "sack2",
		"Shelf", "Panel", "MARKET11", "mage_elements_cowl.grn"]
	var stream2 := world.sector(50, 39)
	var seen2 := {}
	for c in Sacred.SECT * Sacred.SECT:
		var cur := stream2.decode_u32(Sacred.NAME + c * Sacred.CELL + 4)
		var guard2 := {}
		while cur > 0 and cur < static_pak.count() and not guard2.has(cur):
			guard2[cur] = true
			if not seen2.has(cur):
				seen2[cur] = true
				var r := static_pak.blob(cur)
				var t := r.decode_u32(4)
				var nm := items.name_of(t)
				var cell := Sacred.Footprints._object_cell(Vector2(r.decode_s32(0x0e), -r.decode_s32(0x12)))
				if nm in want and CHAPEL.has_point(cell):
					var sid := items.sprite_of(t)
					var sp := mixed.sprite(sid)
					print("  rec=%-8d type=%-6d sprite=%-6d tiles=%-3d size=%-10s anchor=%-10s cell=%s pos=(%d,%d) f8=%d levels=%d interior=%s  %s" % [
						cur, t, sid, 0 if sp.is_empty() else (sp["tiles"] as Array).size(),
						"-" if sp.is_empty() else str(sp["size"]),
						"-" if sp.is_empty() else str(sp["anchor"]), str(cell),
						r.decode_s32(0x0e), r.decode_s32(0x12), r.decode_u32(8),
						items.levels(t), items.is_interior(t), nm])
			cur = static_pak.blob(cur).decode_u32(0x1f)
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
