extends SceneTree
## Probe: what do +0x1e bits 1 and 2 track? Read-only.
##   godot --headless --path godot-port --script res://probes/cell1e_bits_probe.gd
##
## Bit 0 is traced (row 707). Bit 2's reader is 0x080eeec4: it takes the cell,
## requires bit 2, then feeds the cell's +0x04 STATIC handle to the object
## lookup 0x080ef1ac -- the same lookup whose record +0x33 is the height level.
## Bit 1 has NO reader anywhere in the world/cell accessor family (0x080eea62
## .. 0x080eff00 contains tests of bits 0, 2 and 3 only), and the builder's own
## uses are bit 0, bit 4 and bit 7 -- the last two never set in shipped data.
##
## So bit 1 gets attacked from the data instead: what does it co-occur with?
## Every decoded neighbour field is a candidate, plus spatial clustering.


func _init() -> void:
	var install := Sacred.find_install()
	var world := Sacred.World.new(install.path_join("world"))

	var n := 0
	var counts := {1: 0, 2: 0, 4: 0}
	# per-bit conditional rates against every decoded field
	var stat := {1: 0, 2: 0, 4: 0}      ## +0x04 static chain present
	var floor_h := {1: 0, 2: 0, 4: 0}   ## +0x0c overlay chain present
	var hgt := {1: 0, 2: 0, 4: 0}       ## +0x10 any non-zero
	var h2 := {1: 0, 2: 0, 4: 0}        ## +0x18 any non-zero
	var parent := {1: 0, 2: 0, 4: 0}    ## +0x1c/+0x1d non-zero
	var cls_of := {1: {}, 2: {}, 4: {}}
	var cls_all: Dictionary = {}
	var base_stat := 0
	var base_floor := 0
	var base_h := 0
	var base_h2 := 0
	var base_parent := 0
	# spatial: for bit 1, how many of its 4-neighbours also carry it
	var b1_cells := 0
	var b1_nbr := 0
	var sectors_with_b1 := 0
	var sectors := 0
	for gy in 100:
		for gx in 100:
			if not world.has_sector(gx, gy):
				continue
			var s := world.sector(gx, gy)
			if s.is_empty():
				continue
			sectors += 1
			var here := false
			var flags := PackedByteArray()
			flags.resize(Sacred.SECT * Sacred.SECT)
			for i in Sacred.SECT * Sacred.SECT:
				flags[i] = s.decode_u8(Sacred.NAME + i * Sacred.CELL + 0x1e)
			for i in Sacred.SECT * Sacred.SECT:
				var off := Sacred.NAME + i * Sacred.CELL
				n += 1
				var v := flags[i]
				var cls := s.decode_u8(off + 0x1f)
				var has_stat := s.decode_u32(off + 0x04) != 0
				var has_floor := s.decode_u32(off + 0x0c) != 0
				var has_h := false
				var has_h2 := false
				for c in 4:
					if s.decode_u8(off + 0x10 + c) != 0:
						has_h = true
					if s.decode_u8(off + 0x18 + c) != 0:
						has_h2 = true
				var has_parent := s.decode_u8(off + 0x1c) != 0 or s.decode_u8(off + 0x1d) != 0
				cls_all[cls & 0xf0] = int(cls_all.get(cls & 0xf0, 0)) + 1
				if has_stat:
					base_stat += 1
				if has_floor:
					base_floor += 1
				if has_h:
					base_h += 1
				if has_h2:
					base_h2 += 1
				if has_parent:
					base_parent += 1
				for b: int in [1, 2, 4]:
					if v & b == 0:
						continue
					counts[b] += 1
					if has_stat:
						stat[b] += 1
					if has_floor:
						floor_h[b] += 1
					if has_h:
						hgt[b] += 1
					if has_h2:
						h2[b] += 1
					if has_parent:
						parent[b] += 1
					var cd: Dictionary = cls_of[b]
					cd[cls & 0xf0] = int(cd.get(cls & 0xf0, 0)) + 1
				if v & 2:
					here = true
					b1_cells += 1
					for d: int in [1, -1, Sacred.SECT, -Sacred.SECT]:
						var j := i + d
						if j >= 0 and j < Sacred.SECT * Sacred.SECT and (flags[j] & 2):
							b1_nbr += 1
			if here:
				sectors_with_b1 += 1
	print("cells\t%d\tsectors=%d" % [n, sectors])
	print("base\tstatic=%.4f\tfloor=%.4f\theight=%.4f\th2=%.4f\tparent=%.4f" % [
		float(base_stat) / n, float(base_floor) / n, float(base_h) / n,
		float(base_h2) / n, float(base_parent) / n])
	for b: int in [1, 2, 4]:
		var c: int = counts[b]
		if c == 0:
			continue
		print("bit 0x%02x\tn=%d\tP(static)=%.4f\tP(floor)=%.4f\tP(height)=%.4f\tP(h2)=%.4f\tP(parent)=%.4f" % [
			b, c, float(stat[b]) / c, float(floor_h[b]) / c, float(hgt[b]) / c,
			float(h2[b]) / c, float(parent[b]) / c])
		var cd: Dictionary = cls_of[b]
		var ks: Array = cd.keys()
		ks.sort_custom(func(x, y): return cd[x] > cd[y])
		print("  class\t%s" % ", ".join(ks.slice(0, 6).map(
			func(k): return "0x%02x: %.3f (base %.3f)" % [
				k, float(cd[k]) / c, float(cls_all.get(k, 0)) / n])))
	print("bit1_spatial\tcells=%d\tmean_bit1_neighbours=%.2f\tsectors_with_bit1=%d/%d" % [
		b1_cells, 0.0 if b1_cells == 0 else float(b1_nbr) / b1_cells,
		sectors_with_b1, sectors])
	quit()
