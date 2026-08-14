extends SceneTree
## chest_npc_probe.gd -- READ-ONLY census of sector 50,39 (and its 3x3 ring).
##
##   godot --headless --path godot-port --script res://probes/chest_npc_probe.gd
##
## 1. every static reachable by chain(), with items name / sprite / tile count
## 2. chest-like name search (DE + EN)
## 3. triggerId (+0x27) and flags (+0x08) distributions
## 4. the zero-art marker population, bucketed by name

const CHAPEL := Rect2i(3213, 2502, 34, 30)

var install: String
var world: Sacred.World
var static_pak: Sacred.Pak
var statics: Sacred.Statics
var items: Sacred.Items
var mixed: Sacred.Mixed

func _init() -> void:
	install = Sacred.find_install()
	world = Sacred.World.new(install.path_join("world"))
	static_pak = Sacred.Pak.new(install.path_join("world/static.pak"))
	statics = Sacred.Statics.new(static_pak)
	items = Sacred.Items.new(Sacred.Pak.new(install.path_join("pak/items.pak")))
	mixed = Sacred.Mixed.new(Sacred.Pak.new(install.path_join("pak/mixed.pak")))

	print("=== SECTOR 50,39 ===")
	var recs := gather(50, 39)
	report(recs, true)

	print("\n=== RING 49..51 x 38..40 (chest search only) ===")
	for gy in range(38, 41):
		for gx in range(49, 52):
			if gx == 50 and gy == 39:
				continue
			var r := gather(gx, gy)
			var hits := chestlike(r)
			print("sector %d,%d\tstatics=%d\tchestlike=%d" % [gx, gy, r.size(), hits.size()])
			for h in hits:
				print("   %s" % fmt(h))
	quit(0)


func gather(gx: int, gy: int) -> Array:
	var out: Array = []
	var stream := world.sector(gx, gy)
	if stream.is_empty():
		return out
	var seen := {}
	for i in Sacred.SECT * Sacred.SECT:
		var head := stream.decode_u32(Sacred.NAME + i * Sacred.CELL + 4)
		var cur := head
		var guard := {}
		while cur > 0 and cur < static_pak.count() and not guard.has(cur):
			guard[cur] = true
			if seen.has(cur):
				cur = static_pak.blob(cur).decode_u32(0x1f)
				continue
			seen[cur] = true
			var r := static_pak.blob(cur)
			if r.size() < 64:
				break
			var typ := r.decode_u32(4)
			var sid := items.sprite_of(typ)
			var spr := mixed.sprite(sid)
			var pos := Vector2(r.decode_s32(0x0e), -r.decode_s32(0x12))
			out.append({
				"rec": cur,
				"type": typ,
				"name": items.name_of(typ),
				"sprite": sid,
				"tiles": 0 if spr.is_empty() else (spr["tiles"] as Array).size(),
				"size": Vector2i.ZERO if spr.is_empty() else spr["size"],
				"f8": r.decode_u32(8),
				"fC": r.decode_s16(0x0c),
				"u16": r.decode_u8(0x16),
				"parent": r.decode_u32(0x17),
				"parent2": r.decode_u32(0x1b),
				"next": r.decode_u32(0x1f),
				"poff": Vector2i(r.decode_s16(0x23), r.decode_s16(0x25)),
				"trig": r.decode_u32(0x27),
				"b2b": r.decode_s8(0x2b),
				"b2c": r.decode_s8(0x2c),
				"layer": r.decode_u8(0x2d),
				"cell": Sacred.Footprints._object_cell(pos),
				"gridcell": Vector2i(i % Sacred.SECT, i / Sacred.SECT),
			})
			cur = r.decode_u32(0x1f)
	return out


const KEYS := ["truhe", "kiste", "chest", "box", "coffer", "schatz", "crate",
	"kasten", "sarg", "fass", "barrel", "container", "loot", "beute"]

func chestlike(recs: Array) -> Array:
	var out: Array = []
	for d in recs:
		var n: String = String(d["name"]).to_lower()
		if n == "":
			continue
		for k in KEYS:
			if n.contains(k):
				out.append(d)
				break
	return out


const NPCKEYS = ["npc", "monster", "creature", "spawn", "priest", "pfarr", "nonne",
	"nun", "mensch", "person", "figur", "frau", "mann", "held", "hero", "seraphim",
	"gladiator", "magician", "darkelve", "dryade", "vampir", "tier", "animal",
	"grn", "trigger", "sound", "start", "pos", "punkt", "point", "marker", "mark"]

func report(recs: Array, verbose: bool) -> void:
	print("statics=%d" % recs.size())

	# --- chest-like ---
	var ch := chestlike(recs)
	print("\n-- chest-like names: %d --" % ch.size())
	for d in ch:
		print("  %s" % fmt(d))

	# --- trigger distribution ---
	var trig := {}
	for d in recs:
		trig[d["trig"]] = int(trig.get(d["trig"], 0)) + 1
	var tk: Array = trig.keys(); tk.sort()
	print("\n-- triggerId(+0x27) distribution over %d statics --" % recs.size())
	for k in tk:
		print("  trig=%d\tcount=%d" % [k, trig[k]])
	print("  nonzero statics:")
	for d in recs:
		if d["trig"] != 0:
			print("   %s" % fmt(d))

	# --- flags +0x08 ---
	var fl := {}
	for d in recs:
		fl[d["f8"]] = int(fl.get(d["f8"], 0)) + 1
	var fk: Array = fl.keys(); fk.sort()
	print("\n-- flags(+0x08) distribution --")
	for k in fk:
		print("  f8=0x%x (%d)\tcount=%d" % [k, k, fl[k]])

	# --- layer ---
	var ly := {}
	for d in recs:
		ly[d["layer"]] = int(ly.get(d["layer"], 0)) + 1
	var lk: Array = ly.keys(); lk.sort()
	print("\n-- layer(+0x2d) distribution --")
	for k in lk:
		print("  layer=%d\tcount=%d" % [k, ly[k]])

	# --- zero-art markers ---
	var zero: Array = []
	for d in recs:
		if d["tiles"] == 0:
			zero.append(d)
	print("\n-- zero-art (no mixed tiles): %d of %d --" % [zero.size(), recs.size()])
	var byname := {}
	for d in zero:
		var key: String = "%s | type=%d sprite=%d" % [d["name"] if d["name"] != "" else "<unnamed>", d["type"], d["sprite"]]
		if not byname.has(key):
			byname[key] = []
		byname[key].append(d)
	var nk: Array = byname.keys(); nk.sort()
	for k in nk:
		var arr: Array = byname[k]
		var f8s := {}
		var tgs := {}
		var inchap := 0
		for d in arr:
			f8s[d["f8"]] = true
			tgs[d["trig"]] = true
			if CHAPEL.has_point(d["cell"]):
				inchap += 1
		print("  n=%-4d in_chapel=%-4d f8=%s trig=%s  %s" % [arr.size(), inchap, str(f8s.keys()), str(tgs.keys()), k])

	# --- what's inside the chapel rect ---
	print("\n-- statics whose cell is inside CHAPEL %s --" % str(CHAPEL))
	var inch: Array = []
	for d in recs:
		if CHAPEL.has_point(d["cell"]):
			inch.append(d)
	print("  count=%d" % inch.size())
	var chn := {}
	for d in inch:
		var k: String = d["name"] if d["name"] != "" else "<unnamed t%d>" % d["type"]
		chn[k] = int(chn.get(k, 0)) + 1
	var ck: Array = chn.keys(); ck.sort()
	for k in ck:
		print("   %-40s x%d" % [k, chn[k]])


func fmt(d: Dictionary) -> String:
	return "rec=%d type=%d name='%s' sprite=%d tiles=%d size=%s cell=%s f8=%d trig=%d layer=%d" % [
		d["rec"], d["type"], d["name"], d["sprite"], d["tiles"], str(d["size"]),
		str(d["cell"]), d["f8"], d["trig"], d["layer"]]
