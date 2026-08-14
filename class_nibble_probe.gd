extends SceneTree
## Joint distribution of the +0x1f nibbles. Read-only.
## sacred.gd calls the high nibble "an undecoded family split (0xd/0xe)", but
## the builder at 0x080e3415 masks &0xF0 and compares against 0x10/0x20/0x90/
## 0xA0 -- the SAME WALL/FLOOR/DOOR/STEP enum, shifted. So: is +0x1f two class
## nibbles?
func _init() -> void:
	var install := Sacred.find_install()
	var world := Sacred.World.new(install.path_join("world"))
	var joint: Dictionary = {}
	var hi: Dictionary = {}
	var lo: Dictionary = {}
	var n := 0
	for gy in 100:
		for gx in 100:
			if not world.has_sector(gx, gy):
				continue
			var s := world.sector(gx, gy)
			if s.is_empty():
				continue
			for i in Sacred.SECT * Sacred.SECT:
				var b := s.decode_u8(Sacred.NAME + i * Sacred.CELL + 0x1f)
				n += 1
				var h := b >> 4
				var l := b & 0xf
				hi[h] = int(hi.get(h, 0)) + 1
				lo[l] = int(lo.get(l, 0)) + 1
				joint[b] = int(joint.get(b, 0)) + 1
	print("cells\t%d" % n)
	var hk: Array = hi.keys(); hk.sort()
	print("high\t%s" % ", ".join(hk.map(func(k): return "%x:%.4f" % [k, float(hi[k]) / n])))
	var lk: Array = lo.keys(); lk.sort()
	print("low\t%s" % ", ".join(lk.map(func(k): return "%x:%.4f" % [k, float(lo[k]) / n])))
	var jk: Array = joint.keys()
	jk.sort_custom(func(a, b): return joint[a] > joint[b])
	print("joint_distinct\t%d" % jk.size())
	print("joint_top\t%s" % ", ".join(jk.slice(0, 16).map(
		func(k): return "0x%02x:%.4f" % [k, float(joint[k]) / n])))
	quit()
