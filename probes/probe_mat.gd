extends SceneTree
func _init() -> void:
	var install: String = Sacred.find_install()
	var pak := Sacred.Pak.new(install.path_join("pak/models.pak"))
	var models := Sacred.Models.new(pak)
	var e := models.index_of("SERAPHIM.GRN")
	var out := FileAccess.open("/tmp/sera_mat.txt", FileAccess.WRITE)
	out.store_line("entry=%d" % e)
	out.store_line("names=%s" % str(models.texture_names(e)))
	out.store_line("mat_textures=%s" % str(models.material_textures(e)))
	out.close()
	quit()
