extends SceneTree
## Probe: WldxEntry +0x18..0x1b against the known +0x10 height field. Read-only.
##   godot --headless --path godot-port --script res://corner3_height_probe.gd
##
## The retail reader is now known (row 705 pending): 0x080ef688 reads all four
## +0x18 bytes SIGNED, scales each by 2.5, averages them (x0.25) to test
## against zero, and bilinearly interpolates them across the cell to return a
## float -- and its caller at 0x080ef5e6 ADDS that to a per-object term, so the
## result is a HEIGHT at a position. The terrain quad builder at 0x080e2706
## never reads it; it reads +0x10..0x13 for the vertex heights instead.
##
## So the question is what this second height means. Measured here:
##   1. do +0x18 and +0x10 co-occur, or are they independent?
##   2. is +0x18 a rescaling of +0x10 (row 218: +0x10 is always a multiple of 5)?
##   3. per corner, or only per cell?


func _init() -> void:
	var install := Sacred.find_install()
	var world := Sacred.World.new(install.path_join("world"))

	var n := 0
	var h_nz := 0            ## +0x10 non-zero on some corner
	var f_nz := 0            ## +0x18 non-zero on some corner
	var both := 0
	var ratio: Dictionary = {}       ## +0x10 / +0x18 per corner, where both non-zero
	var exact5 := 0
	var pairs := 0
	var f_vals: Dictionary = {}
	for gy in range(0, 100, 11):
		for gx in range(0, 100, 11):
			if not world.has_sector(gx, gy):
				continue
			var s := world.sector(gx, gy)
			if s.is_empty():
				continue
			for i in Sacred.SECT * Sacred.SECT:
				var off := Sacred.NAME + i * Sacred.CELL
				n += 1
				var any_h := false
				var any_f := false
				for c in 4:
					var hb := s.decode_u8(off + 0x10 + c)
					var fb := s.decode_u8(off + 0x18 + c)
					var h := hb - 256 if hb > 127 else hb
					var f := fb - 256 if fb > 127 else fb
					if h != 0:
						any_h = true
					if f != 0:
						any_f = true
						f_vals[f] = int(f_vals.get(f, 0)) + 1
					if h != 0 and f != 0:
						pairs += 1
						# Is one a rescaling of the other? +0x10 is always a
						# multiple of 5 (row 218), so h/5 is the natural guess.
						if h == f * 5:
							exact5 += 1
						var k := "%d:%d" % [h, f]
						ratio[k] = int(ratio.get(k, 0)) + 1
				if any_h:
					h_nz += 1
				if any_f:
					f_nz += 1
				if any_h and any_f:
					both += 1
	print("cells\t%d" % n)
	print("rates\tP(+0x10)=%.4f\tP(+0x18)=%.4f\tP(both)=%.4f\texpected_if_independent=%.4f" % [
		float(h_nz) / n, float(f_nz) / n, float(both) / n,
		(float(h_nz) / n) * (float(f_nz) / n)])
	print("lift\t%.2f" % ((float(both) / n) / maxf(1e-9, (float(h_nz) / n) * (float(f_nz) / n))))
	print("per_corner\tboth_nonzero=%d\th==f*5 exactly=%d (%.3f)" % [
		pairs, exact5, 0.0 if pairs == 0 else float(exact5) / pairs])
	# Sign agreement and the h/f ratio, over ALL pairs rather than the top ten.
	var same_sign := 0
	var ratio_hist: Dictionary = {}
	for k: String in ratio.keys():
		var p := k.split(":")
		var h := int(p[0])
		var f := int(p[1])
		var cnt: int = ratio[k]
		if (h > 0) == (f > 0):
			same_sign += cnt
		ratio_hist[roundi(float(h) / float(f))] = int(ratio_hist.get(roundi(float(h) / float(f)), 0)) + cnt
	print("sign_agree\t%d/%d (%.4f)" % [same_sign, pairs, float(same_sign) / pairs])
	var rk: Array = ratio_hist.keys()
	rk.sort_custom(func(a, b): return ratio_hist[a] > ratio_hist[b])
	print("h_over_f\t%s" % ", ".join(rk.slice(0, 8).map(
		func(k): return "%d x%d" % [k, ratio_hist[k]])))
	var ks: Array = ratio.keys()
	ks.sort_custom(func(a, b): return ratio[a] > ratio[b])
	print("top_h:f_pairs\t%s" % ", ".join(ks.slice(0, 10).map(
		func(k): return "%s x%d" % [k, ratio[k]])))
	var fk: Array = f_vals.keys()
	fk.sort()
	print("f_values\t%s" % ", ".join(fk.map(func(k): return "%d x%d" % [k, f_vals[k]])))
	quit()
