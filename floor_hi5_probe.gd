extends SceneTree
## Probe 5: the exact SHAPE of floor.pak +0x04's top field. Read-only.
##   godot --headless --path godot-port --script res://floor_hi5_probe.gd
##
## Probe 4 turned up two things worth pinning exactly. The A=0 bucket (25,782)
## is almost exactly the zero count and the B=0 bucket is 25,886, which implies
## values 1..511 are essentially ABSENT -- i.e. the domain is {0} u [512..1535],
## a 1024-wide band, not 0..1535. And the mean falls steeply with chain depth
## (971, 845, 586, 287, 184, 139), which is either an ordering or an artefact
## of long chains being different.
##
## A smooth unimodal histogram over the band says QUANTITY. A lumpy one with
## repeated exact values says TABLE INDEX. Those need different next steps, so
## measure before rendering anything.


func _init() -> void:
	var install := Sacred.find_install()
	var fp := Sacred.Pak.new(install.path_join("world/floor.pak"))

	var n := 0
	var zero := 0
	var below512 := 0
	var min_nonzero := 1 << 30
	var exact: Dictionary = {}          ## suspicious round values
	var bucket := PackedInt32Array()
	bucket.resize(32)                   ## 48 wide each, over 0..1535
	for i in range(1, fp.count(), 31):
		var r := fp.blob(i)
		if r.size() < 16:
			continue
		n += 1
		var hi := r.decode_u32(4) >> 17
		if hi == 0:
			zero += 1
			continue
		if hi < 512:
			below512 += 1
		min_nonzero = mini(min_nonzero, hi)
		bucket[mini(hi / 48, 31)] += 1
		if hi == 512 or hi == 1024 or hi == 1535 or hi == 1280 or hi == 768:
			exact[hi] = int(exact.get(hi, 0)) + 1
	print("shape\tn=%d\tzero=%d (%.3f)\tnonzero_min=%d\tbelow_512=%d" % [
		n, zero, float(zero) / n, min_nonzero, below512])
	var out: Array = []
	for b in 32:
		if bucket[b] > 0:
			out.append("%d..%d:%d" % [b * 48, b * 48 + 47, bucket[b]])
	print("hist48\t%s" % " ".join(out))
	print("round_values\t%s" % exact)
	quit()
