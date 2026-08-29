extends SceneTree
func _init() -> void:
	var install: String = Sacred.find_install()
	var pak := Sacred.Pak.new(install.path_join("pak/models.pak"))
	var models := Sacred.Models.new(pak)
	var n := models.count()
	for i in n:
		var nm: String = models.entry_name(i)
		if "STIEFEL" in nm or "SERA_" in nm or nm == "SERAPHIM.GRN":
			print("entry %d = %s" % [i, nm])
	quit()
