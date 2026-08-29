extends SceneTree
func _init() -> void:
	var install: String = Sacred.find_install()
	var items := Sacred.Items.new(Sacred.Pak.new(install.path_join("pak/items.pak")))
	var sets := Sacred.Sets.new(install)
	print("items count=", items.count(), "sets=", sets.set_indices())
	for id in items.count():
		var nm: String = items.name_of(id)
		if nm.to_lower().contains("stiefel"):
			var s := sets.set_of_item(id)
			print("item %d '%s' set=%d" % [id, nm, s])
	quit()
