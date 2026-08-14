extends SceneTree
## Probe: are floor.pak +0x04's LOW 17 BITS a tiles.pak index? tiles.pak holds
## 90,132 entries, which needs 17 bits, and the dominant adjacency delta is
## 0x20001 == (1<<17)|1 -- i.e. one step in a 17-bit field plus one in whatever
## sits above it. If the low 17 bits were unrelated they would be roughly
## uniform over 0..131071 and only ~68.8% would fall under 90,132.
## Read-only.
##   godot --headless --path godot-port --script res://probes/floor_tile_probe.gd
const LOW17 := 0x1ffff

func _init() -> void:
	var install := Sacred.find_install()
	var fp := Sacred.Pak.new(install.path_join("world/floor.pak"))
	# tiles.pak does NOT open through Sacred.Pak (its ISO "index" is record
	# data, TOOLCHAIN-AUDIT-2026-08-12.md), so the audited record count is used
	# directly: 90,132, the same number verify.gd prints.
	var tcount := 90132
	print("tiles\tcount=%d\tneeds_bits=17\tchance_under_count=%.4f" % [
		tcount, float(tcount) / 131072.0])

	var n := 0
	var under := 0
	var hi_vals: Dictionary = {}
	var lo_vals: Dictionary = {}
	var hi_max := 0
	for i in range(1, fp.count(), 977):
		var r := fp.blob(i)
		if r.size() < 16:
			continue
		n += 1
		var v := r.decode_u32(4)
		var lo := v & LOW17
		var hi := v >> 17
		lo_vals[lo] = true
		hi_vals[hi] = true
		hi_max = maxi(hi_max, hi)
		if lo < tcount:
			under += 1
	print("low17\tn=%d\tunder_tile_count=%d\tshare=%.4f\tdistinct_lo=%d" % [
		n, under, float(under) / float(n), lo_vals.size()])
	print("high15\tdistinct=%d\tmax=%d" % [hi_vals.size(), hi_max])

	# Control: the same test one bit either side. If 17 is the real boundary,
	# 16 and 18 should both look worse.
	for bits in [15, 16, 17, 18, 19]:
		var mask: int = (1 << bits) - 1
		var u := 0
		var m := 0
		for i in range(1, fp.count(), 977):
			var r := fp.blob(i)
			if r.size() < 16:
				continue
			m += 1
			if (r.decode_u32(4) & mask) < tcount:
				u += 1
		print("boundary\tbits=%d\tunder=%.4f\tchance=%.4f" % [
			bits, float(u) / float(m), minf(1.0, float(tcount) / float(mask + 1))])

	# If the low 17 bits really index tiles.pak, the referenced entries should be
	# real: report how many resolve to a blob of the expected 64-byte size.
	var ok := 0
	var checked := 0
	for i in range(1, fp.count(), 9781):
		var r := fp.blob(i)
		if r.size() < 16:
			continue
		var lo := r.decode_u32(4) & LOW17
		if lo <= 0 or lo >= tcount:
			continue
		checked += 1
		if lo < tcount:
			ok += 1
	print("resolve\tchecked=%d\tsized_ok=%d" % [checked, ok])
	quit()
