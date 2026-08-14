extends SceneTree
## bit-1 sectors that contain NO region sub-grids at all. Read-only.
func _init() -> void:
	var install := Sacred.find_install()
	var world := Sacred.World.new(install.path_join("world"))
	var out: Array = []
	for gy in 100:
		for gx in 100:
			if not world.has_sector(gx, gy):
				continue
			var s := world.sector(gx, gy)
			if s.is_empty():
				continue
			var c := 0
			for i in Sacred.SECT * Sacred.SECT:
				if s.decode_u8(Sacred.NAME + i * Sacred.CELL + 0x1e) & 2:
					c += 1
			if c == 0:
				continue
			if Sacred.Regions.new(s, gx, gy).list.is_empty():
				out.append("%d,%d:%d" % [gx, gy, c])
	print("bit1_sectors_without_regions\t%d" % out.size())
	print(", ".join(out.slice(0, 25)))
	quit()
