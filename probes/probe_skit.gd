extends SceneTree
func _init() -> void:
	var install: String = Sacred.find_install()
	var items := Sacred.Items.new(Sacred.Pak.new(install.path_join("pak/items.pak")))
	var out := FileAccess.open("/tmp/skit.txt", FileAccess.WRITE)
	for mesh in ["SERAPHIM_S_BOOTS", "SERA_S_BOOTS", "BOOTS_S", "SERAPHIM_BOOTS"]:
		var recs: PackedInt32Array = items.records_naming(mesh)
		out.store_line("mesh %s -> %d records" % [mesh, recs.size()])
		for r in recs:
			out.store_line("  rec %d name='%s' tex=%d cat=%d" % [r, items.name_of(r), items.texture_of(r), items.category_of(r)])
	# boots-category records: which carry the white look
	var boots: Array = []
	for r in items.count():
		if items.category_of(r) == 18:
			boots.append(r)
	out.store_line("category-18 (boots) records: %d" % boots.size())
	for r in boots:
		out.store_line("  rec %d name='%s' tex=%d" % [r, items.name_of(r), items.texture_of(r)])
	out.close()
	quit()
