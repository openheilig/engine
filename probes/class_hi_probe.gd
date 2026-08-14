extends SceneTree
## Does the +0x1f HIGH nibble follow the ground tile's texture? If it is a
## surface material (footstep sounds, etc.) one texture should nearly always
## carry one nibble value. Read-only.
func _init() -> void:
	var install := Sacred.find_install()
	var world := Sacred.World.new(install.path_join("world"))
	var tiles := Sacred.Tiles.new(install.path_join("pak/tiles.pak"))
	var by_tex: Dictionary = {}      ## texture id -> {nibble -> count}
	var n := 0
	for gy in range(0, 100, 5):
		for gx in range(0, 100, 5):
			if not world.has_sector(gx, gy):
				continue
			var s := world.sector(gx, gy)
			if s.is_empty():
				continue
			for i in Sacred.SECT * Sacred.SECT:
				var off := Sacred.NAME + i * Sacred.CELL
				var tid := s.decode_u32(off)
				if tid >= tiles.count():
					continue
				var tex := tiles.texture_id(tid)
				var h := s.decode_u8(off + 0x1f) >> 4
				n += 1
				if not by_tex.has(tex):
					by_tex[tex] = {}
				var d: Dictionary = by_tex[tex]
				d[h] = int(d.get(h, 0)) + 1
	# purity: fraction of each texture's cells that take its modal nibble
	var tot := 0
	var modal := 0
	var pure := 0
	var texn := 0
	for tex: int in by_tex:
		var d: Dictionary = by_tex[tex]
		var sum := 0
		var best := 0
		for k: int in d:
			sum += d[k]
			best = maxi(best, d[k])
		if sum < 20:
			continue
		texn += 1
		tot += sum
		modal += best
		if best == sum:
			pure += 1
	print("cells=%d\ttextures(>=20 cells)=%d" % [n, texn])
	print("purity\tP(cell takes its texture's modal nibble)=%.4f" % [float(modal) / tot])
	print("perfect\ttextures with a SINGLE nibble=%d/%d (%.3f)" % [
		pure, texn, float(pure) / texn])
	quit()
