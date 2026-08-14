extends SceneTree
## Where are the +0x1e bit-1 sectors? Read-only. Prints a 100x100 map.
func _init() -> void:
	var install := Sacred.find_install()
	var world := Sacred.World.new(install.path_join("world"))
	var hits: Dictionary = {}
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
			if c > 0:
				hits[gy * 100 + gx] = c
	print("sectors_with_bit1\t%d" % hits.size())
	for gy in 100:
		var row := ""
		var any := false
		for gx in 100:
			var k := gy * 100 + gx
			if hits.has(k):
				var c: int = hits[k]
				row += "#" if c > 2048 else ("+" if c > 512 else ".")
				any = true
			elif world.has_sector(gx, gy):
				row += " "
			else:
				row += "~"
		if any:
			print("y=%02d |%s" % [gy, row])
	var ks: Array = hits.keys(); ks.sort()
	print("first10\t%s" % ", ".join(ks.slice(0, 10).map(
		func(k): return "%d,%d:%d" % [k % 100, k / 100, hits[k]])))
	quit()
