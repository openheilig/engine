extends SceneTree
## Probe: which sectors does world.pak actually carry, and how many statics
## land in each? Settles whether the UW_ROCK census cells (sectors 13-24,12-21)
## can ever render in the port.
##   godot --headless --path godot-port --script res://probes/sector_probe.gd
func _init() -> void:
	var install := Sacred.find_install()
	var sp := Sacred.Pak.new(install.path_join("world/static.pak"))
	if not sp.is_open():
		printerr("pak open failed"); quit(1); return
	var world := Sacred.World.new(install.path_join("world"))
	var statics := Sacred.Statics.new(sp)

	for s in [Vector2i(23, 14), Vector2i(36, 30), Vector2i(50, 50), Vector2i(20, 14), Vector2i(13, 16)]:
		print("world_sector\t%d,%d\tpresent=%s" % [s.x, s.y, world.has_sector(s.x, s.y)])

	# Statics per sector: static.pak ox/oy are absolute iso screen coords,
	# sector = cell >> 6, cell from the same inversion loggia_scan uses.
	var per_sector: Dictionary[Vector2i, int] = {}
	for i in statics.count():
		var o := statics.get_object(i)
		if o.is_empty(): continue
		var p: Vector2 = o["pos"]
		var cx := int(p.x / 96.0 + (-p.y) / 48.0)
		var cy := int((-p.y) / 48.0 - p.x / 96.0)
		var key := Vector2i(cx >> 6, cy >> 6)
		per_sector[key] = per_sector.get(key, 0) + 1
	print("statics\tsector 23,14 = %d" % per_sector.get(Vector2i(23, 14), 0))
	print("statics\tsector 36,30 = %d" % per_sector.get(Vector2i(36, 30), 0))
	print("statics\tsector 50,50 = %d" % per_sector.get(Vector2i(50, 50), 0))
	# Bounding box of all statics sectors, and of present world sectors.
	var mn := Vector2i(1 << 30, 1 << 30)
	var mx := Vector2i(-1, -1)
	for k in per_sector:
		mn.x = mini(mn.x, k.x); mn.y = mini(mn.y, k.y)
		mx.x = maxi(mx.x, k.x); mx.y = maxi(mx.y, k.y)
	print("statics\tsector bbox %d,%d .. %d,%d" % [mn.x, mn.y, mx.x, mx.y])

	# Terrain census: is sector 23,14 actual tiles or a void placeholder?
	for s in [Vector2i(23, 14), Vector2i(50, 50), Vector2i(36, 30)]:
		var ids := world.tile_ids(s.x, s.y)
		var nonzero := 0
		var distinct := {}
		for t in ids:
			if t != 0:
				nonzero += 1
				distinct[t] = true
		print("tiles\tsector %d,%d\tcells=%d\tnonzero=%d\tdistinct=%d" % [s.x, s.y, ids.size(), nonzero, distinct.size()])
		# Corner height deltas (+0x10..+0x13, one byte per corner): is this
		# floor raised above z=0? The hero's placement Z is the sort depth,
		# not the terrain height -- a raised floor would swallow the mesh.
		var e := world.entries(s.x, s.y)
		var max_h := 0
		var sum_h := 0
		for i in 4096:
			for c in 4:
				var h: int = e[i * Sacred.CELL + 0x10 + c]
				max_h = maxi(max_h, h)
				sum_h += h
		print("heights\tsector %d,%d\tmean=%.1f\tmax=%d" % [s.x, s.y, sum_h / float(4096 * 4), max_h])
	quit()
