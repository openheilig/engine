extends SceneTree
func _init() -> void:
	var install: String = Sacred.find_install()
	var items := Sacred.Items.new(Sacred.Pak.new(install.path_join("pak/items.pak")))
	var sets := Sacred.Sets.new(install)
	var models := Sacred.Models.new(Sacred.Pak.new(install.path_join("pak/models.pak")))
	var out := FileAccess.open("/tmp/item_mesh.txt", FileAccess.WRITE)
	for id in [5171, 5633, 4007, 7901]:
		var nm: String = items.name_of(id)
		var e := models.index_of(nm)
		out.store_line("item %d name='%s' models_entry=%d set=%d" % [
			id, nm, e, sets.set_of_item(id)])
	out.close()
	quit()
