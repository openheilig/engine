extends SceneTree
func _init() -> void:
	var i := Sacred.find_install()
	for f in ["pak/sndprofiles.pak", "pak/weapon.pak", "pak/motions.pak"]:
		var p := Sacred.Pak.new(i.path_join(f))
		print("%s\t%s" % [f, str(p.count()) if p.is_open() else "not open"])
	quit()
