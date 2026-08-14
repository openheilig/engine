extends SceneTree
## Probe: settle the KLOSTER_KAPELLE01 contradiction. Read-only.
## Uses the port's OWN Items + SectorView._classify_object -- nothing is
## reimplemented -- to answer: are the level-2 chapel pieces loaded, what does
## the port's Items say about them, and which bucket do they land in?
##   godot --headless --path godot-port --script res://probes/kapelle_class_probe.gd
const GX := 50
const GY := 39
const RECT := Rect2i(3213, 2502, 34, 30)

func _init() -> void:
	var install := Sacred.find_install()
	var world := Sacred.World.new(install.path_join("world"))
	var static_pak := Sacred.Pak.new(install.path_join("world/static.pak"))
	var items_pak := Sacred.Pak.new(install.path_join("pak/items.pak"))
	var statics := Sacred.Statics.new(static_pak)
	var items := Sacred.Items.new(items_pak)
	var footprints := Sacred.Footprints.new(statics, items)

	# ---- 1. items.pak census of KLOSTER_KAPELLE01* through the PORT'S parse.
	# Re-read the pak only to enumerate names; every level/family answer below
	# comes from `items` itself.
	var fam_levels: Dictionary = {}     ## family -> {level -> count}
	var kap_names := 0
	for i in items_pak.count():
		var r := items_pak.blob(i)
		if r.size() < Sacred.Items.REC_MIN:
			continue
		var nm := r.slice(Sacred.Items.NAME_OFF).get_string_from_ascii()
		if not nm.begins_with("KLOSTER_KAPELLE01"):
			continue
		kap_names += 1
		var sid := r.decode_u32(Sacred.Items.SPRITE_OFF)
		var f := items.family_of(sid)
		var lv := items.levels(sid)
		var key := f if f != "" else "<UNPARSED:%s>" % nm
		if not fam_levels.has(key):
			fam_levels[key] = {}
		fam_levels[key][lv] = int(fam_levels[key].get(lv, 0)) + 1
	print("itemspak\tnames_beginning_KLOSTER_KAPELLE01=%d" % kap_names)
	var fams: Array = fam_levels.keys()
	fams.sort()
	for f: String in fams:
		var per: Dictionary = fam_levels[f]
		var ks: Array = per.keys()
		ks.sort()
		var parts: Array = []
		for k: int in ks:
			parts.append("mask%d=%d" % [k, per[k]])
		print("family\t%s\t%s" % [f, ", ".join(parts)])

	# What does the port think the TOP level of each such family is? Probe it
	# through the public accessor by finding, per family, the highest level a
	# sprite reports and whether is_top_level agrees.
	var fam_top_observed: Dictionary = {}
	for i in items_pak.count():
		var r := items_pak.blob(i)
		if r.size() < Sacred.Items.REC_MIN:
			continue
		var nm := r.slice(Sacred.Items.NAME_OFF).get_string_from_ascii()
		if not nm.begins_with("KLOSTER_KAPELLE01"):
			continue
		var sid := r.decode_u32(Sacred.Items.SPRITE_OFF)
		var f := items.family_of(sid)
		if f == "":
			continue
		if items.is_top_level(sid):
			var lv := items.levels(sid)
			fam_top_observed[f] = "%s topmask=%d" % [str(fam_top_observed.get(f, "")), lv]
	for f: String in fam_top_observed:
		print("famtop\t%s\t%s" % [f, fam_top_observed[f]])

	# ---- 2. The port's objs[] for this sector: exactly the +0x04 read from
	# sector_view.gd:420, no filters (default opts: no --exterior/--hidelevel).
	var cells := world.entries(GX, GY)
	if cells.is_empty():
		printerr("no entries for %d,%d" % [GX, GY]); quit(1); return
	var view := SectorView.new()
	view._items = items
	view._world = world
	view._statics = statics
	view._footprints = footprints
	var regions := Sacred.Regions.new(world.sector(GX, GY), GX, GY)
	var resolved := footprints.resolve(world.sector(GX, GY), GX, GY)
	print("regions\tcount=%d" % regions.list.size())
	for ri in regions.list.size():
		var r: Dictionary = regions.list[ri]
		print("region\t%d\tcell=%s\tsize=%s\tfamily=%s" % [ri, r["cell"], r["size"], resolved[ri]["family"]])

	var objs: Array[Dictionary] = []
	for i in Sacred.SECT * Sacred.SECT:
		var o := statics.get_object(cells.decode_u32(i * Sacred.CELL + 4))
		if o.is_empty():
			continue
		objs.append(o)
	print("objs\tloaded=%d" % objs.size())

	var cls_counts: Dictionary = {}
	var kap_in_rect := 0
	var lvl2_in_rect := 0
	var rows := 0
	var per_class_lvl2: Dictionary = {}
	for o: Dictionary in objs:
		var sid: int = o["type"]
		var nm := items.name_of(sid)
		var p: Vector2 = o["pos"]
		var cell := Sacred.Footprints._object_cell(p)
		var in_rect := RECT.has_point(cell)
		var res := view._classify_object(o, p, GX, GY, regions, footprints)
		var c: String = res["class"]
		cls_counts[c] = int(cls_counts.get(c, 0)) + 1
		if not nm.begins_with("KLOSTER_KAPELLE01"):
			continue
		if in_rect:
			kap_in_rect += 1
		var lv := items.levels(sid)
		var top := items.is_top_level(sid)
		if in_rect and (lv & 4) != 0:
			lvl2_in_rect += 1
			per_class_lvl2[c] = int(per_class_lvl2.get(c, 0)) + 1
		var rk: int = int(res["region_key"])
		var bucket := -1 if rk < 0 else rk * 2 + (1 if c == "INTERIOR" else 0)
		if rows < 250:
			rows += 1
			print("kap\tcell=%s\tin_rect=%s\tsid=%d\tname=%s\tlevels=%d\ttop=%s\tfam=%s\tclass=%s\trk=%d\tbucket=%d" % [
				cell, in_rect, sid, nm, lv, top, res["family"], c, rk, bucket])

	print("classes\t%s" % cls_counts)
	print("kap_in_rect=%d\tlevel2_in_rect=%d\tlevel2_by_class=%s" % [kap_in_rect, lvl2_in_rect, per_class_lvl2])
	view.free()
	quit()
