extends SceneTree
## sector_tail_probe.gd -- READ-ONLY. Is there unaccounted data in a sector
## stream after the cell grid, the region table and the region grids?
##   godot --headless --path godot-port --script res://probes/sector_tail_probe.gd

func _init() -> void:
	var install := Sacred.find_install()
	var world := Sacred.World.new(install.path_join("world"))
	var CELLS := Sacred.NAME + 64 * 64 * 32
	for pair in [[50, 39], [50, 40], [49, 38], [64, 39]]:
		var gx: int = pair[0]
		var gy: int = pair[1]
		var s := world.sector(gx, gy)
		if s.is_empty():
			continue
		# walk the region table exactly as Sacred.Regions does
		var p := CELLS
		var nrec := 0
		var maxend := CELLS
		while p + 36 <= s.size() and s.decode_u32(p + 0x0c) == 6:
			nrec += 1
			var off := s.decode_u32(p + 0x10)
			var bytes := s.decode_u32(p + 0x14)
			if off + bytes <= s.size():
				maxend = maxi(maxend, off + bytes)
			p += 36
		var table_end := p
		print("sector %d,%d: stream=%d  cells_end=%d  region_recs=%d table_end=%d  last_grid_end=%d  TAIL=%d" % [
			gx, gy, s.size(), CELLS, nrec, table_end, maxend, s.size() - maxi(maxend, table_end)])
		var tail := maxi(maxend, table_end)
		if s.size() - tail > 0:
			var n := mini(160, s.size() - tail)
			print("   tail bytes @%d: %s" % [tail, _hex(s.slice(tail, tail + n))])
			var nz := 0
			for i in range(tail, s.size()):
				if s[i] != 0:
					nz += 1
			print("   nonzero tail bytes: %d of %d" % [nz, s.size() - tail])
		# gap between the region table end and the first grid
		var firstgrid := s.size()
		p = CELLS
		while p + 36 <= s.size() and s.decode_u32(p + 0x0c) == 6:
			var off := s.decode_u32(p + 0x10)
			if off > 0:
				firstgrid = mini(firstgrid, off)
			p += 36
		print("   first grid offset=%d, gap after table=%d" % [firstgrid, firstgrid - table_end])
		if firstgrid - table_end > 0 and firstgrid > table_end:
			print("   gap bytes: %s" % _hex(s.slice(table_end, mini(firstgrid, table_end + 128))))
	quit(0)

func _hex(b: PackedByteArray) -> String:
	var s := ""
	for i in b.size():
		s += "%02x" % b[i]
		if i % 4 == 3:
			s += " "
	return s
