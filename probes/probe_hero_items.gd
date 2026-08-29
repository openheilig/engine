extends SceneTree
func _init() -> void:
	var install: String = Sacred.find_install()
	var out := FileAccess.open("/tmp/hero_items.txt", FileAccess.WRITE)
	var dir := install.path_join("templates")
	for i in range(0, 8):
		var path := dir.path_join("hero%02d.ptx" % (i + 1))
		if not FileAccess.file_exists(path):
			continue
		var hero := Sacred.Hero.new(path)
		var slot := hero.class_slot()
		out.store_line("hero%02d.ptx class_slot=%d items=%s" % [i + 1, slot, str(hero.items())])
		var arts := hero.combat_arts_list()
		var ids: Array = []
		for a in arts:
			ids.append(a.get("id", -1))
		out.store_line("  arts=%s" % str(ids))
	out.close()
	quit()
