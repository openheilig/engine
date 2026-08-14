extends SceneTree
## Phase 2 UAT Test 2 extension: locate a roofed overhang in the PORT.
##
##   godot --headless --path godot-port --script res://probes/loggia_scan.gd
##
## The four-sector marker-cube sweep (TSV rows 375/376/380) never reached a
## roofed loggia; row 379 says so explicitly. This census finds candidate
## cells for one, so --sortcube= can be driven under overhead geometry.
##
## DUMP BEFORE HYPOTHESISE: this prints the placement census and nothing else.
## It forms no verdict about occlusion -- that is what the capture is for.
##
## A "roof over walkable ground" needs a building family with a level ABOVE
## level 0, i.e. max level >= 1. static.pak's type id indexes mixed.pak, and
## Items maps that sprite id to an authoring name / level bitmask, so a static
## placement can be attributed to a family and a storey without any guessing.

## static.pak ox/oy are absolute isometric screen coords: ox = 48*(cx-cy),
## oy = 24*(cx+cy). Inverting gives the cell back. Kept as floats because the
## stored values carry a sub-cell offset.
func _cell(ox: float, oy: float) -> Vector2:
	return Vector2(ox / 96.0 + oy / 48.0, oy / 48.0 - ox / 96.0)


func _init() -> void:
	var install := Sacred.find_install()
	if install == "":
		printerr("no install found; pass --install=/path/to/install")
		quit(1)
		return

	var static_pak := Sacred.Pak.new(install.path_join("world/static.pak"))
	var items_pak := Sacred.Pak.new(install.path_join("pak/items.pak"))
	if not (static_pak.is_open() and items_pak.is_open()):
		printerr("static.pak or items.pak did not open")
		quit(1)
		return
	var statics := Sacred.Statics.new(static_pak)
	var items := Sacred.Items.new(items_pak)

	# Pass 1: family -> highest level token seen, over NAMED sprites only.
	# Reuses the same "_<level>_<part>" convention Items already parses; the
	# family is the name up to the level token (sacred.gd Items header).
	var lv := RegEx.create_from_string("^(.*)_(\\d)(?:U(\\d))?_\\d+$")
	var fam_top: Dictionary[String, int] = {}
	var fam_of: Dictionary[int, String] = {}
	var lvl_of: Dictionary[int, int] = {}
	var named := 0
	for i in statics.count():
		var o := statics.get_object(i)
		if o.is_empty():
			continue
		var t: int = o["type"]
		if fam_of.has(t):
			continue
		var nm := items.name_of(t)
		if nm == "":
			continue
		var m := lv.search(nm)
		if m == null:
			continue
		named += 1
		var fam := m.get_string(1)
		var l := int(m.get_string(2))
		if m.get_string(3) != "":
			l = maxi(l, int(m.get_string(3)))
		fam_of[t] = fam
		lvl_of[t] = l
		fam_top[fam] = maxi(fam_top.get(fam, 0), l)

	print("census\tstatics=%d\tdistinct_named_types=%d\tfamilies=%d"
		% [statics.count(), named, fam_top.size()])

	# Pass 2: cluster ABOVE-GROUND parts (level >= 1) of multi-storey families
	# on a 16-cell grid. A dense cluster of upper-storey art is a building with
	# a roof; its own ground cells are the candidate walk-under targets.
	var clusters: Dictionary[String, Array] = {}
	for i in statics.count():
		var o := statics.get_object(i)
		if o.is_empty():
			continue
		var t: int = o["type"]
		if not fam_of.has(t):
			continue
		var fam: String = fam_of[t]
		if fam_top.get(fam, 0) < 1 or lvl_of[t] < 1:
			continue
		# pos.y was negated for Godot's up-axis; undo it to get screen oy back.
		var p: Vector2 = o["pos"]
		var c := _cell(p.x, -p.y)
		var key := "%s@%d,%d" % [fam, int(c.x) >> 4, int(c.y) >> 4]
		var e: Array = clusters.get(key, [fam, 0, 0.0, 0.0])
		e[1] = int(e[1]) + 1
		e[2] = float(e[2]) + c.x
		e[3] = float(e[3]) + c.y
		clusters[key] = e

	var rows: Array = []
	for k in clusters:
		var e: Array = clusters[k]
		var n: int = e[1]
		rows.append([n, e[0], float(e[2]) / n, float(e[3]) / n])
	rows.sort_custom(func(a, b): return a[0] > b[0])

	print("clusters\t%d\ttop 25 by upper-storey part count" % rows.size())
	print("parts\tfamily\ttop_lvl\tcell_cx\tcell_cy\tsector")
	for r in rows.slice(0, 25):
		var cx: float = r[2]
		var cy: float = r[3]
		print("%d\t%s\t%d\t%.0f\t%.0f\t%d,%d"
			% [r[0], r[1], fam_top[r[1]], cx, cy, int(cx) >> 6, int(cy) >> 6])
	quit()
