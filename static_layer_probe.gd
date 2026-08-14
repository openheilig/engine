extends SceneTree
## Probe: read the UNDECODED tail of static.pak's 64-byte record against known
## placements. Field offsets from Resacred-old rs_file.h:322-350 (PakStatic,
## #pragma pack(1), static_assert sizeof == 64):
##   +0x00 i32 id          +0x04 i32 itemTypeId   +0x08 i32 field_8
##   +0x0c i16 field_C     +0x0e i32 worldX       +0x12 i32 worldY
##   +0x16 u8  unk_0       +0x17 i32 parentId     +0x1b i32 anotherParentId
##   +0x1f i32 nextStaticId  +0x23 i16 parentOffsetTx  +0x25 i16 parentOffsetTy
##   +0x27 i32 triggerId   +0x2b i8  field_2B     +0x2c i8  field_2C
##   +0x2d u8  LAYER       +0x2e i8  smthX        +0x2f i8  smthY
##   +0x30 i8  smthZ       +0x31.. unknown
## Read-only.
##   godot --headless --path godot-port --script res://static_layer_probe.gd
const GX := 50
const GY := 39
const LAYER := 0x2d

func _init() -> void:
	var install := Sacred.find_install()
	var world := Sacred.World.new(install.path_join("world"))
	var static_pak := Sacred.Pak.new(install.path_join("world/static.pak"))
	var items := Sacred.Items.new(Sacred.Pak.new(install.path_join("pak/items.pak")))
	var stream := world.sector(GX, GY)

	# Per-name layer census over this sector, plus a raw-tail dump for a few
	# named samples so the field can be checked by eye against the record.
	var by_layer: Dictionary = {}          ## layer -> count
	var name_layers: Dictionary = {}       ## name prefix -> {layer -> count}
	var samples: Array = []
	for i in Sacred.SECT * Sacred.SECT:
		var idx := stream.decode_u32(Sacred.NAME + i * Sacred.CELL + 4)
		if idx <= 0 or idx >= static_pak.count():
			continue
		var r := static_pak.blob(idx)
		if r.size() < 64:
			continue
		var layer := r[LAYER]
		by_layer[layer] = int(by_layer.get(layer, 0)) + 1
		var nm := items.name_of(r.decode_u32(4))
		var key := nm.split("_")[0] if nm.contains("_") else nm.split(" ")[0]
		if not name_layers.has(key):
			name_layers[key] = {}
		name_layers[key][layer] = int(name_layers[key].get(layer, 0)) + 1
		if samples.size() < 8 and nm != "":
			var hex := ""
			for b in range(0x1f, 0x38):
				hex += "%02x " % r[b]
			samples.append("sample\tname=%s\tlayer=%d\tfield_8=%d\tnext=%d\ttrigger=%d\ttail[0x1f..0x37]=%s" % [
				nm, layer, r.decode_u32(8), r.decode_u32(0x1f), r.decode_u32(0x27), hex])
	for s: String in samples:
		print(s)
	var ls: Array = by_layer.keys(); ls.sort()
	for l: int in ls:
		print("sector_layer\t%d\t%d" % [l, by_layer[l]])
	var ns: Array = name_layers.keys(); ns.sort()
	for nkey: String in ns:
		var per: Dictionary = name_layers[nkey]
		var ks: Array = per.keys(); ks.sort()
		var parts: Array = []
		for k: int in ks:
			parts.append("L%d=%d" % [k, per[k]])
		print("byname\t%s\t%s" % [nkey, ", ".join(parts)])

	# nextStaticId (+0x1f): does the sector's cell array reference only the HEAD
	# of a chain? Walk each head and count what the port never draws.
	var heads := 0
	var extra := 0
	var maxlen := 0
	var layer_seq: Dictionary = {}     ## chain position -> set of layer values seen
	var extra_names: Dictionary = {}
	for i in Sacred.SECT * Sacred.SECT:
		var idx := stream.decode_u32(Sacred.NAME + i * Sacred.CELL + 4)
		if idx <= 0 or idx >= static_pak.count():
			continue
		heads += 1
		var seen: Dictionary = {idx: true}
		var cur := idx
		var pos := 0
		while true:
			var r := static_pak.blob(cur)
			if r.size() < 64:
				break
			var nxt := r.decode_u32(0x1f)
			if not layer_seq.has(pos):
				layer_seq[pos] = {}
			layer_seq[pos][r[LAYER]] = true
			if nxt <= 0 or nxt >= static_pak.count() or seen.has(nxt):
				break
			seen[nxt] = true
			cur = nxt
			pos += 1
			extra += 1
			var rn := static_pak.blob(cur)
			if rn.size() >= 64:
				var nm2 := items.name_of(rn.decode_u32(4))
				extra_names[nm2] = int(extra_names.get(nm2, 0)) + 1
		maxlen = maxi(maxlen, pos + 1)
	print("chains\theads=%d\textra_statics=%d\tmax_chain=%d" % [heads, extra, maxlen])
	var ps: Array = layer_seq.keys(); ps.sort()
	for p: int in ps:
		var vals: Array = layer_seq[p].keys(); vals.sort()
		if p < 6:
			print("chainpos\t%d\tlayers=%s" % [p, vals])
	var en: Array = extra_names.keys(); en.sort()
	for nm3: String in en:
		print("extra_name\t%s\t%d" % [nm3, extra_names[nm3]])

	# World-wide histogram over every static.pak record, not just this sector.
	var world_hist: Dictionary = {}
	for i in static_pak.count():
		var r := static_pak.blob(i)
		if r.size() < 64:
			continue
		world_hist[r[LAYER]] = int(world_hist.get(r[LAYER], 0)) + 1
	var ws: Array = world_hist.keys(); ws.sort()
	for l: int in ws:
		print("world_layer\t%d\t%d" % [l, world_hist[l]])
	quit()
