extends SceneTree
## Probe: WldxEntry +0x1e, the last undecoded byte. Read-only.
##   godot --headless --path godot-port --script res://cell1e_probe.gd
##
## Retail reads it UNSIGNED at 0x080e2983 and uses it as a BITMASK, testing two
## bits and using the whole value once:
##   0x080e350f  test bit 0x01 -- taken right after the +0x04 static handle is
##               loaded; the branch computes the cell's own world position
##               (index >> 6 as the row, index & 0x3f as the column, plus the
##               sector origin at +0x44/+0x48) and calls 0x080d7958 with it.
##   0x080e3402  test bit 0x10 -- and only then looks at the +0x1f class,
##               masking &0xF0 and accepting 0x10/0x20/0x90/0xA0, i.e.
##               WALL/FLOOR/DOOR/STEP.
##   0x080e47af  reads the whole byte.
##
## So: which bits are live at all, and what do bit 0 and bit 4 track? The two
## obvious candidates from the call sites are tested against, respectively, the
## presence of a static chain (+0x04) and the cell's class (+0x1f).


func _init() -> void:
	var install := Sacred.find_install()
	var world := Sacred.World.new(install.path_join("world"))

	var n := 0
	var bits := PackedInt32Array()
	bits.resize(8)
	var vals: Dictionary = {}
	# bit 0 vs a static chain being present
	var b0 := 0
	var b0_static := 0
	var static_n := 0
	var static_b0 := 0
	# bit 4 vs the class nibbles
	var b4 := 0
	var b4_hi: Dictionary = {}
	var hi_all: Dictionary = {}
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
				var v := s.decode_u8(off + 0x1e)
				var cls := s.decode_u8(off + 0x1f)
				var has_static := s.decode_u32(off + 0x04) != 0
				vals[v] = int(vals.get(v, 0)) + 1
				for b in 8:
					if v & (1 << b):
						bits[b] += 1
				hi_all[cls & 0xf0] = int(hi_all.get(cls & 0xf0, 0)) + 1
				if has_static:
					static_n += 1
				if v & 0x01:
					b0 += 1
					if has_static:
						b0_static += 1
				if has_static and (v & 0x01):
					static_b0 += 1
				if v & 0x10:
					b4 += 1
					b4_hi[cls & 0xf0] = int(b4_hi.get(cls & 0xf0, 0)) + 1
	print("cells\t%d" % n)
	var bs: Array = []
	for b in 8:
		bs.append("b%d=%.4f" % [b, float(bits[b]) / n])
	print("bits\t%s" % " ".join(bs))
	var ks: Array = vals.keys()
	ks.sort_custom(func(a, b): return vals[a] > vals[b])
	print("values\tdistinct=%d\ttop=%s" % [vals.size(), ", ".join(ks.slice(0, 10).map(
		func(k): return "0x%02x x%d" % [k, vals[k]]))])
	print("bit0\tset=%d (%.4f)\tP(static|bit0)=%.4f\tP(bit0|static)=%.4f\tbase P(static)=%.4f" % [
		b0, float(b0) / n,
		0.0 if b0 == 0 else float(b0_static) / b0,
		0.0 if static_n == 0 else float(static_b0) / static_n,
		float(static_n) / n])
	print("bit4\tset=%d (%.4f)" % [b4, float(b4) / n])
	var hk: Array = b4_hi.keys(); hk.sort()
	print("bit4_by_class\t%s" % ", ".join(hk.map(
		func(k): return "0x%02x: %d/%d" % [k, b4_hi[k], hi_all.get(k, 0)])))
	quit()
