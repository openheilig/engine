extends SceneTree
## Probe: is floor.pak +0x04's LOW 16 bits an items.pak record index, the same
## id space static.pak +0x04 uses? Read-only.
##   godot --headless --path godot-port --script res://floor_id_probe.gd

func _init() -> void:
	var install := Sacred.find_install()
	var fp := Sacred.Pak.new(install.path_join("world/floor.pak"))
	var items_pak := Sacred.Pak.new(install.path_join("pak/items.pak"))
	var items := Sacred.Items.new(items_pak)
	var mixed := Sacred.Mixed.new(Sacred.Pak.new(install.path_join("pak/mixed.pak")))

	var named := 0
	var art := 0
	var total := 0
	var in_range := 0
	var hi_vals: Dictionary = {}
	var names: Dictionary = {}
	for i in range(1, fp.count(), 977):
		var r := fp.blob(i)
		if r.size() < 16:
			continue
		total += 1
		var v := r.decode_u32(4)
		var lo := v & 0xffff
		var hi := (v >> 16) & 0xffff
		hi_vals[hi] = int(hi_vals.get(hi, 0)) + 1
		if lo < items_pak.count():
			in_range += 1
		var nm := items.name_of(lo)
		if nm != "":
			named += 1
			names[nm] = int(names.get(nm, 0)) + 1
			if not mixed.sprite(items.sprite_of(lo)).is_empty():
				art += 1
	print("lo16\tsampled=%d\tin_items_range=%d\tnamed=%d\twith_art=%d" % [
		total, in_range, named, art])
	var ns: Array = names.keys()
	ns.sort_custom(func(a, b): return names[a] > names[b])
	for nm: String in ns.slice(0, 20):
		print("lo16_name\t%s\t%d" % [nm, names[nm]])
	print("hi16\tdistinct=%d" % hi_vals.size())

	# Control: the same test on the FULL u32 and on the HIGH half, so a chance
	# hit rate is visible rather than assumed.
	var full_named := 0
	var hi_named := 0
	for i in range(1, fp.count(), 977):
		var r := fp.blob(i)
		if r.size() < 16:
			continue
		var v := r.decode_u32(4)
		if v < items_pak.count() and items.name_of(v) != "":
			full_named += 1
		if items.name_of((v >> 16) & 0xffff) != "":
			hi_named += 1
	print("control\tfull_u32_named=%d\thi16_named=%d\tof=%d" % [full_named, hi_named, total])
	quit()
