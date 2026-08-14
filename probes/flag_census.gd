extends SceneTree
## static.pak +0x08 flags: 9 distinct values. Do they encode "this is overhead
## art / cull me"? Cross-tab flags against named-level class.
## DUMP BEFORE HYPOTHESISE: a table, no verdict.
func _init() -> void:
	var install := Sacred.find_install()
	var sp := Sacred.Pak.new(install.path_join("world/static.pak"))
	var ip := Sacred.Pak.new(install.path_join("pak/items.pak"))
	var st := Sacred.Statics.new(sp)
	var it := Sacred.Items.new(ip)
	var lv := RegEx.create_from_string("^(.*)_(\\d)(?:U(\\d))?_\\d+$")
	# tab[flag] = [total, unnamed, lvl0, above]
	var tab: Dictionary[int, Array] = {}
	for i in st.count():
		var o := st.get_object(i)
		if o.is_empty(): continue
		var fl: int = o["flags"]
		var e: Array = tab.get(fl, [0,0,0,0])
		e[0] += 1
		var nm := it.name_of(o["type"])
		var m := lv.search(nm) if nm != "" else null
		if m == null:
			e[1] += 1
		else:
			var l := int(m.get_string(2))
			if m.get_string(3) != "": l = maxi(l, int(m.get_string(3)))
			if l < 1: e[2] += 1
			else: e[3] += 1
		tab[fl] = e
	var keys: Array = tab.keys(); keys.sort()
	print("flag\thex\ttotal\tunnamed\tlvl0\tabove")
	for k in keys:
		var e: Array = tab[k]
		print("%d\t0x%x\t%d\t%d\t%d\t%d" % [k, k, e[0], e[1], e[2], e[3]])
	quit()
