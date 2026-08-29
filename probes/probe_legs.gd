extends SceneTree
func _init() -> void:
	var install: String = Sacred.find_install()
	var tp := Sacred.Pak.new(install.path_join("pak/texture.pak"))
	var out := FileAccess.open("/tmp/sera_legs.txt", FileAccess.WRITE)
	for stem in ["Sera_legs", "Sera_boots", "Sera_body"]:
		var id := Sacred.TextureFormat.find_model_texture(tp, stem + ".tga")
		out.store_line("%s id=%d" % [stem, id])
		if id >= 0:
			var img := Sacred.TextureFormat.decode_texture(tp, id)
			if img != null:
				img.save_png("/tmp/sera_" + stem + ".png")
				out.store_line("  decoded %dx%d -> /tmp/sera_%s.png" % [img.get_width(), img.get_height(), stem])
			else:
				out.store_line("  DECODE FAILED")
	out.close()
	quit()
