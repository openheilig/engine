extends SceneTree
## Low-nibble cell class (+0x1f) per +0x1e bit. DOOR=9, STEP=0xa, WALL=1, FLOOR=2.
func _init() -> void:
	var install := Sacred.find_install()
	var world := Sacred.World.new(install.path_join("world"))
	var per := {1: {}, 2: {}, 4: {}}
	var base: Dictionary = {}
	var cnt := {1: 0, 2: 0, 4: 0}
	var n := 0
	for gy in 100:
		for gx in 100:
			if not world.has_sector(gx, gy):
				continue
			var s := world.sector(gx, gy)
			if s.is_empty():
				continue
			for i in Sacred.SECT * Sacred.SECT:
				var off := Sacred.NAME + i * Sacred.CELL
				var v := s.decode_u8(off + 0x1e)
				var lo := s.decode_u8(off + 0x1f) & 0x0f
				n += 1
				base[lo] = int(base.get(lo, 0)) + 1
				for b: int in [1, 2, 4]:
					if v & b:
						cnt[b] += 1
						var d: Dictionary = per[b]
						d[lo] = int(d.get(lo, 0)) + 1
	var bk: Array = base.keys(); bk.sort()
	print("base\t%s" % ", ".join(bk.map(func(k): return "%d:%.4f" % [k, float(base[k]) / n])))
	for b: int in [1, 2, 4]:
		var d: Dictionary = per[b]
		var ks: Array = d.keys(); ks.sort()
		print("bit 0x%02x\tn=%d\t%s" % [b, cnt[b], ", ".join(ks.map(
			func(k): return "%d:%.4f" % [k, float(d[k]) / cnt[b]]))])
	quit()
