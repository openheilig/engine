extends SceneTree
## Probe 7: are the 39 textures the floor.pak TOP field draws from alpha masks
## or ordinary colour? Read-only. Writes nothing but PNGs under /tmp.
##   godot --headless --path godot-port --script res://floor_mask_probe.gd
func _init() -> void:
	var install := Sacred.find_install()
	var tex := Sacred.Pak.new(install.path_join("pak/texture.pak"))
	for t in [6248, 6325, 6094, 5610, 4152, 4150]:   ## last two are ground, as control
		var img := Sacred.decode_texture(tex, t, true)
		if img == null:
			print("tex\t%d\tdecode failed" % t)
			continue
		var w := img.get_width()
		var h := img.get_height()
		var a_hist := {0: 0, 255: 0, "mid": 0}
		var grey := 0
		var n := 0
		for y in range(0, h, 4):
			for x in range(0, w, 4):
				var c := img.get_pixel(x, y)
				n += 1
				var a := int(round(c.a * 255.0))
				if a == 0:
					a_hist[0] += 1
				elif a == 255:
					a_hist[255] += 1
				else:
					a_hist["mid"] += 1
				if absf(c.r - c.g) < 0.02 and absf(c.g - c.b) < 0.02:
					grey += 1
		print("tex\t%d\t%dx%d\tsampled=%d\talpha0=%.3f\talpha255=%.3f\talpha_mid=%.3f\tgreyscale=%.3f" % [
			t, w, h, n, float(a_hist[0]) / n, float(a_hist[255]) / n,
			float(a_hist["mid"]) / n, float(grey) / n])
		img.save_png("/tmp/floormask-%d.png" % t)
	quit()
