extends SceneTree
func _init() -> void:
	var install: String = Sacred.find_install()
	var pak := Sacred.Pak.new(install.path_join("pak/models.pak"))
	var models := Sacred.Models.new(pak)
	var n := models.count()
	for i in n:
		var nm: String = models.entry_name(i)
		if "IDLE" in nm.to_upper() or "FIDLE" in nm.to_upper():
			print("entry %d = %s" % [i, nm])
	quit()
