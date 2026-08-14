extends SceneTree
## Is +0x1e bit 1 the "this cell is covered by a region sub-grid" marker?
## Read-only.
func _init() -> void:
	var install := Sacred.find_install()
	var world := Sacred.World.new(install.path_join("world"))
	var b1_in := 0; var b1 := 0; var in_n := 0; var in_b1 := 0
	var sect_b1 := 0; var sect_reg := 0; var sect_both := 0
	for gy in 100:
		for gx in 100:
			if not world.has_sector(gx, gy):
				continue
			var s := world.sector(gx, gy)
			if s.is_empty():
				continue
			var regs := Sacred.Regions.new(s, gx, gy)
			var lo := Vector2i(gx, gy) * Sacred.SECT
			var has_b1 := false
			for i in Sacred.SECT * Sacred.SECT:
				var v := s.decode_u8(Sacred.NAME + i * Sacred.CELL + 0x1e)
				var c := lo + Vector2i(i % Sacred.SECT, i / Sacred.SECT)
				var inside := false
				for r: Dictionary in regs.list:
					if Rect2i(r["cell"], r["size"]).has_point(c):
						inside = true
						break
				if inside:
					in_n += 1
				if v & 2:
					b1 += 1
					has_b1 = true
					if inside:
						b1_in += 1
				if inside and (v & 2):
					in_b1 += 1
			if has_b1:
				sect_b1 += 1
			if not regs.list.is_empty():
				sect_reg += 1
			if has_b1 and not regs.list.is_empty():
				sect_both += 1
	print("bit1\tn=%d\tP(inside a region rect | bit1)=%.4f" % [b1, 0.0 if b1 == 0 else float(b1_in) / b1])
	print("region\tcells=%d\tP(bit1 | inside)=%.4f" % [in_n, 0.0 if in_n == 0 else float(in_b1) / in_n])
	print("sectors\twith_bit1=%d\twith_regions=%d\twith_both=%d" % [sect_b1, sect_reg, sect_both])
	quit()
