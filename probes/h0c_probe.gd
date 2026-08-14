extends SceneTree
## Probe: is the WldxEntry +0x0c object handle populated, and if so what does it
## point at? Read-only measurement over sector (50,39) -- Silver Creek Cathedral,
## region KLOSTER_KAPELLE01 rect (3213,2502) size 34x30. The port only ever reads
## +0x04; nothing anywhere reads +0x0c.
##   godot --headless --path godot-port --script res://probes/h0c_probe.gd
const GX := 50
const GY := 39

func _init() -> void:
	var install := Sacred.find_install()
	var world := Sacred.World.new(install.path_join("world"))
	var statics := Sacred.Statics.new(Sacred.Pak.new(install.path_join("world/static.pak")))
	var items := Sacred.Items.new(Sacred.Pak.new(install.path_join("pak/items.pak")))

	var stream := world.sector(GX, GY)
	print("sector\t%d,%d\tpresent=%s\tstream=%d bytes" % [GX, GY, world.has_sector(GX, GY), stream.size()])
	var need := Sacred.NAME + Sacred.SECT * Sacred.SECT * Sacred.CELL
	if stream.size() < need:
		printerr("stream too short: %d < %d" % [stream.size(), need]); quit(1); return

	var n04 := 0
	var n0c := 0
	var both := 0
	var same := 0
	var resolved := 0
	var unresolved := 0
	var names: Dictionary = {}
	var rows := 0
	for i in Sacred.SECT * Sacred.SECT:
		var base := Sacred.NAME + i * Sacred.CELL
		var h04 := stream.decode_u32(base + 4)
		var h0c := stream.decode_u32(base + 0x0c)
		if h04 != 0: n04 += 1
		if h0c != 0: n0c += 1
		if h04 != 0 and h0c != 0: both += 1
		if h0c != 0 and h0c == h04: same += 1
		if h0c == 0:
			continue
		var o := statics.get_object(h0c)
		if o.is_empty():
			unresolved += 1
			if rows < 400:
				rows += 1
				print("cell\t%d\t(%d,%d)\th04=%d\th0c=%d\tUNRESOLVED" % [i, i % Sacred.SECT, i / Sacred.SECT, h04, h0c])
			continue
		resolved += 1
		var sid: int = o["type"]
		var nm := items.name_of(sid)
		names[nm] = int(names.get(nm, 0)) + 1
		if rows < 400:
			rows += 1
			print("cell\t%d\t(%d,%d)\th04=%d\th0c=%d\tsid=%d\tname=%s\tlevels=%d\ttop=%s\tinterior=%s\tpos=%s" % [
				i, i % Sacred.SECT, i / Sacred.SECT, h04, h0c, sid, nm,
				items.levels(sid), items.is_top_level(sid), items.is_interior(sid), o["pos"]])

	print("summary\tcells=%d\tnonzero_h04=%d\tnonzero_h0c=%d\tboth=%d\th0c_eq_h04=%d\tresolved=%d\tunresolved=%d" % [
		Sacred.SECT * Sacred.SECT, n04, n0c, both, same, resolved, unresolved])
	var keys: Array = names.keys()
	keys.sort()
	print("distinct_h0c_names=%d" % keys.size())
	for k: String in keys:
		print("name\t%d\t%s" % [names[k], k])

	# Byte-level sanity: what values actually live at +0x08..+0x0f across the
	# whole sector, regardless of whether they look like handles?
	var hist08: Dictionary = {}
	var hist0c: Dictionary = {}
	for i in Sacred.SECT * Sacred.SECT:
		var base := Sacred.NAME + i * Sacred.CELL
		var v8 := stream.decode_u32(base + 8)
		var vc := stream.decode_u32(base + 0x0c)
		hist08[v8] = int(hist08.get(v8, 0)) + 1
		hist0c[vc] = int(hist0c.get(vc, 0)) + 1
	print("distinct_u32_at_0x08=%d\tdistinct_u32_at_0x0c=%d" % [hist08.size(), hist0c.size()])
	_top("0x08", hist08)
	_top("0x0c", hist0c)
	quit()

func _top(label: String, h: Dictionary) -> void:
	var ks: Array = h.keys()
	ks.sort_custom(func(a, b): return h[a] > h[b])
	var shown := 0
	for k in ks:
		print("hist%s\t%d\tvalue=%d (0x%x)" % [label, h[k], k, k])
		shown += 1
		if shown >= 10:
			break
