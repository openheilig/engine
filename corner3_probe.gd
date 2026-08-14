extends SceneTree
## Probe: what are WldxEntry +0x18..0x1b, the third per-corner byte array?
## Row 218 measured the shape (91% zero, 99 distinct) but not the meaning.
##
## HYPOTHESIS UNDER TEST: they are the per-corner blend/alpha of the OVERLAY
## TILE that floor.pak supplies for that cell (row 695). Prediction, stated
## before measuring: a cell with a floor handle should carry non-zero corner
## bytes far more often than a cell without one. If the two are independent the
## rates will match and the hypothesis is dead.
## Read-only.
##   godot --headless --path godot-port --script res://corner3_probe.gd
const C3 := 0x18

func _init() -> void:
	var world := Sacred.World.new(Sacred.find_install().path_join("world"))
	var cells := 0
	var with_floor := 0
	var c3_nonzero := 0
	var floor_and_c3 := 0
	var floor_no_c3 := 0
	var nofloor_and_c3 := 0
	var vals: Dictionary = {}
	for gy in range(0, 100, 11):
		for gx in range(0, 100, 11):
			if not world.has_sector(gx, gy):
				continue
			var st := world.sector(gx, gy)
			if st.size() < Sacred.NAME + Sacred.SECT * Sacred.SECT * Sacred.CELL:
				continue
			for i in Sacred.SECT * Sacred.SECT:
				var base := Sacred.NAME + i * Sacred.CELL
				cells += 1
				var f := st.decode_u32(base + 0x0c) != 0
				var nz := false
				for c in 4:
					var v := st[base + C3 + c]
					if v != 0:
						nz = true
						vals[v] = int(vals.get(v, 0)) + 1
				if f:
					with_floor += 1
				if nz:
					c3_nonzero += 1
				if f and nz:
					floor_and_c3 += 1
				elif f and not nz:
					floor_no_c3 += 1
				elif nz and not f:
					nofloor_and_c3 += 1
	print("cells\t%d\twith_floor=%d (%.3f)\tc3_nonzero=%d (%.3f)" % [
		cells, with_floor, float(with_floor) / float(cells),
		c3_nonzero, float(c3_nonzero) / float(cells)])
	print("joint\tfloor_and_c3=%d\tfloor_no_c3=%d\tnofloor_and_c3=%d" % [
		floor_and_c3, floor_no_c3, nofloor_and_c3])
	# P(c3 | floor) vs P(c3 | no floor) -- the whole test.
	var p_given := float(floor_and_c3) / maxf(float(with_floor), 1.0)
	var p_not := float(nofloor_and_c3) / maxf(float(cells - with_floor), 1.0)
	print("test\tP(c3|floor)=%.4f\tP(c3|no_floor)=%.4f\tlift=%.2f" % [
		p_given, p_not, p_given / maxf(p_not, 0.0001)])
	var ks: Array = vals.keys()
	ks.sort_custom(func(a, b): return vals[a] > vals[b])
	var top: Array = []
	for k: int in ks.slice(0, 10):
		top.append("%d x%d" % [k, vals[k]])
	print("top_values\t%s\tdistinct=%d" % [", ".join(top), vals.size()])
	quit()
