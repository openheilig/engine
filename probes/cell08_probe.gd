extends SceneTree
## Probe: what is WldxEntry +0x08 in the FILE? Read-only.
##   godot --headless --path godot-port --script res://probes/cell08_probe.gd
##
## +0x04 is already decoded and used by the port -- it heads the static.pak
## chain (sacred.gd:549, row 686). +0x08 is not read by anything here.
##
## The retail terrain builder loads it at 0x080e296c and walks it at 0x080e4455
## as a CIRCULAR LINKED LIST: id -> record via a lookup against the global at
## ds:0x8b8d0c0, next at record+0x30, stopping when the next id comes back to
## the head. Each record's +0x1c/+0x20 are turned into screen coordinates
## (minus the view origin, plus 512/384 = half of 1024x768).
##
## A per-cell circular list of objects that MOVE would be built at runtime, not
## shipped -- so the prediction is that the file's +0x08 is empty. If instead it
## holds real ids, it is authored data and needs decoding on its own terms.
## Also compared against +0x04, whose meaning is known, as a control.


func _init() -> void:
	var install := Sacred.find_install()
	var world := Sacred.World.new(install.path_join("world"))

	var n := 0
	var zero := 0
	var nonzero_vals: Dictionary = {}
	var vmax := 0
	# Control: the same census for +0x04, which is known to be a real handle.
	var s4_zero := 0
	var s4_max := 0
	for gy in range(0, 100, 1):
		for gx in range(0, 100, 1):
			if not world.has_sector(gx, gy):
				continue
			var s := world.sector(gx, gy)
			if s.is_empty():
				continue
			for i in Sacred.SECT * Sacred.SECT:
				var off := Sacred.NAME + i * Sacred.CELL
				n += 1
				var v := s.decode_u32(off + 0x08)
				if v == 0:
					zero += 1
				else:
					vmax = maxi(vmax, v)
					if nonzero_vals.size() < 40:
						nonzero_vals[v] = int(nonzero_vals.get(v, 0)) + 1
				var v4 := s.decode_u32(off + 0x04)
				if v4 == 0:
					s4_zero += 1
				else:
					s4_max = maxi(s4_max, v4)
	print("cells\t%d" % n)
	print("+0x08\tzero=%d (%.5f)\tnonzero=%d\tmax=%d" % [
		zero, float(zero) / n, n - zero, vmax])
	print("+0x04\tzero=%d (%.5f)\tnonzero=%d\tmax=%d   (control: known static.pak handle)" % [
		s4_zero, float(s4_zero) / n, n - s4_zero, s4_max])
	if not nonzero_vals.is_empty():
		var ks: Array = nonzero_vals.keys()
		ks.sort()
		print("+0x08_values\t%s" % ", ".join(ks.slice(0, 20).map(
			func(k): return "%d x%d" % [k, nonzero_vals[k]])))
	quit()
