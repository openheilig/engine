extends SceneTree
## Probe: do floor.pak's low-17-bit tile indices resolve to REAL tiles.pak
## records, and what is the high 15 bits? Read-only.
##   godot --headless --path godot-port --script res://probes/floor_resolve_probe.gd
const LOW17 := 0x1ffff

func _init() -> void:
	var install := Sacred.find_install()
	var fp := Sacred.Pak.new(install.path_join("world/floor.pak"))
	var tiles := Sacred.Tiles.new(install.path_join("pak/tiles.pak"))
	var world := Sacred.World.new(install.path_join("world"))
	print("tiles\tcount=%d" % tiles.count())

	# 1. Resolve: every referenced tile must have a texture id inside
	#    texture.pak's own range, exactly like a terrain tile does.
	var n := 0
	var tex_ok := 0
	var slot_ok := 0
	var texs: Dictionary = {}
	for i in range(1, fp.count(), 977):
		var r := fp.blob(i)
		if r.size() < 16:
			continue
		var t := r.decode_u32(4) & LOW17
		if t >= tiles.count():
			continue
		n += 1
		var tex := tiles.texture_id(t)
		var slot := tiles.orientation(t)
		texs[tex] = true
		if tex >= 0 and tex < 25535:
			tex_ok += 1
		if slot >= 0 and slot <= 17:
			slot_ok += 1
	print("resolve\tn=%d\ttexture_in_range=%d\tslot_0_17=%d\tdistinct_textures=%d" % [
		n, tex_ok, slot_ok, texs.size()])

	# 2. The high 15 bits: distribution, and whether it ever exceeds a plausible
	#    small enumeration.
	var hi: Dictionary = {}
	for i in range(1, fp.count(), 977):
		var r := fp.blob(i)
		if r.size() < 16:
			continue
		hi[r.decode_u32(4) >> 17] = int(hi.get(r.decode_u32(4) >> 17, 0)) + 1
	var ks: Array = hi.keys(); ks.sort()
	print("high15\tdistinct=%d\tmin=%d\tmax=%d" % [hi.size(), ks[0], ks[ks.size() - 1]])
	ks.sort_custom(func(a, b): return hi[a] > hi[b])
	var top: Array = []
	for k: int in ks.slice(0, 10):
		top.append("%d x%d" % [k, hi[k]])
	print("high15_top\t%s" % ", ".join(top))

	# 3. Does the high 15 bits track the SECTOR? Compare its value against the
	#    referencing cell's sector for one sector's worth of handles.
	for s in [[7, 7], [14, 14], [50, 39]]:
		var stream := world.sector(s[0], s[1])
		if stream.is_empty():
			continue
		var vals: Dictionary = {}
		var cells := 0
		for i in Sacred.SECT * Sacred.SECT:
			var h := stream.decode_u32(Sacred.NAME + i * Sacred.CELL + 0x0c)
			if h == 0:
				continue
			cells += 1
			var r := fp.blob(h)
			if r.size() >= 16:
				vals[r.decode_u32(4) >> 17] = true
		print("sector_high15\t%d,%d\tcells=%d\tdistinct_high15=%d" % [s[0], s[1], cells, vals.size()])
	quit()
