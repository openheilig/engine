extends SceneTree
## Does retail's data contain overhead art that is NOT cullable?
##   godot --headless --path godot-port --script res://probes/overhead_census.gd
## DUMP BEFORE HYPOTHESISE: counts only, no verdict.
## Cull predicate mirrors sector_view.gd:416 exactly -- Items.is_top_level().

func _init() -> void:
	var install := Sacred.find_install()
	var sp := Sacred.Pak.new(install.path_join("world/static.pak"))
	var ip := Sacred.Pak.new(install.path_join("pak/items.pak"))
	if not (sp.is_open() and ip.is_open()):
		printerr("pak open failed"); quit(1); return
	var st := Sacred.Statics.new(sp)
	var it := Sacred.Items.new(ip)

	var unnamed := 0            # no name at all -> no level info -> never culled
	var ground := 0             # level 0 only
	var above_cullable := 0     # level >=1 AND is_top_level -> --exterior drops it
	var above_stuck := 0        # level >=1 AND NOT top_level -> stays drawn
	var stuck_fams: Dictionary[String, int] = {}
	var lv := RegEx.create_from_string("^(.*)_(\\d)(?:U(\\d))?_\\d+$")

	for i in st.count():
		var o := st.get_object(i)
		if o.is_empty(): continue
		var t: int = o["type"]
		var nm := it.name_of(t)
		var m := lv.search(nm) if nm != "" else null
		if m == null:
			unnamed += 1
			continue
		var l := int(m.get_string(2))
		if m.get_string(3) != "":
			l = maxi(l, int(m.get_string(3)))
		if l < 1:
			ground += 1
		elif it.is_top_level(t):
			above_cullable += 1
		else:
			above_stuck += 1
			var f := m.get_string(1)
			stuck_fams[f] = stuck_fams.get(f, 0) + 1

	var tot := st.count()
	print("total\t%d" % tot)
	print("unnamed_no_level\t%d\t%.1f%%" % [unnamed, 100.0*unnamed/tot])
	print("ground_lvl0\t%d\t%.1f%%" % [ground, 100.0*ground/tot])
	print("above_cullable\t%d\t%.1f%%" % [above_cullable, 100.0*above_cullable/tot])
	print("above_NOT_cullable\t%d\t%.1f%%" % [above_stuck, 100.0*above_stuck/tot])
	var rows: Array = []
	for k in stuck_fams: rows.append([stuck_fams[k], k])
	rows.sort_custom(func(a,b): return a[0] > b[0])
	print("stuck_families\t%d\ttop 15" % rows.size())
	for r in rows.slice(0, 15):
		print("%d\t%s\tlevels=%d" % [r[0], r[1], 0])
	quit()
