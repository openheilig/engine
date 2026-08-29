extends SceneTree
func _init() -> void:
	var install: String = Sacred.find_install()
	var pak := Sacred.Pak.new(install.path_join("pak/models.pak"))
	var models := Sacred.Models.new(pak)
	var e := models.index_of("SERAPHIM.GRN")
	var out := FileAccess.open("/tmp/sera_tex.txt", FileAccess.WRITE)
	out.store_line("SERAPHIM.GRN entry=%d" % e)
	out.store_line("textures: " + str(models.texture_names(e)))
	var mv := ModelView.new()
	mv.set_texture_pak(Sacred.Pak.new(install.path_join("pak/texture.pak")))
	root.add_child(mv)
	var ok := mv.setup(models, e, false)
	print("setup=", ok, " surfaces=", (mv._mesh.get_surface_count() if ok else 0))
	for i in ((mv._mesh.get_surface_count() if ok else 0)):
		var mat: Material = mv._mesh.surface_get_material(i)
		var albedo := "?"
		var tex := "none"
		if mat is StandardMaterial3D:
			var sm: StandardMaterial3D = mat
			albedo = str(sm.albedo_color)
			tex = "yes" if sm.albedo_texture != null else "NO-TEX"
		out.store_line("surface %d: mat=%s albedo=%s tex=%s" % [i, mat.get_class(), albedo, tex])
		out.flush()
	out.close()
	quit()
