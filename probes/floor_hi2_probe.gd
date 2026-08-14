extends SceneTree
## Probe 2 on world/floor.pak +0x04's top bits. Read-only.
##   godot --headless --path godot-port --script res://probes/floor_hi2_probe.gd
##
## floor_hi_probe measured bits 11..14 DEAD (so the field is at most 11 bits,
## not 15) and the nonzero values piled into 1024..1535 -- bit10 set in 87% of
## them, bit9 in 13% -- with visibly CONSECUTIVE values on neighbouring cells
## (1073, 1072, 1071 / 1458, 1457, 1456, 1455). Consecutive values are what an
## INDEX looks like, so this probe asks what it indexes and whether it is data
## at all or merely a function of the record's own position in the file.
const LOW17 := 0x1ffff


func _init() -> void:
	var install := Sacred.find_install()
	var fp := Sacred.Pak.new(install.path_join("world/floor.pak"))
	var world := Sacred.World.new(install.path_join("world"))

	# 1. Range buckets and the true maximum over a much larger sample than the
	#    977-stride one (which could easily have missed a wider value).
	var n := 0
	var zero := 0
	var lo1023 := 0
	var band := 0          ## 1024..1535
	var above := 0         ## >= 1536, which nothing has yet shown
	var vmax := 0
	for i in range(1, fp.count(), 97):
		var r := fp.blob(i)
		if r.size() < 16:
			continue
		n += 1
		var hi := r.decode_u32(4) >> 17
		vmax = maxi(vmax, hi)
		if hi == 0:
			zero += 1
		elif hi < 1024:
			lo1023 += 1
		elif hi < 1536:
			band += 1
		else:
			above += 1
	print("range\tn=%d\tmax=%d\tzero=%.3f\t1..1023=%.3f\t1024..1535=%.3f\t>=1536=%d" % [
		n, vmax, float(zero) / n, float(lo1023) / n, float(band) / n, above])

	# 2. Is it a function of the RECORD INDEX rather than of the world? Walk a
	#    contiguous run of records and look at the joint delta.
	var dj: Dictionary = {}
	var prev_hi := -1
	var prev_lo := -1
	for i in range(1000000, 1040000):
		var r := fp.blob(i)
		if r.size() < 16:
			continue
		var v := r.decode_u32(4)
		var hi := v >> 17
		var lo := v & LOW17
		if prev_hi >= 0:
			var k := "%+d/%+d" % [hi - prev_hi, lo - prev_lo]
			dj[k] = int(dj.get(k, 0)) + 1
		prev_hi = hi
		prev_lo = lo
	var ks: Array = dj.keys()
	ks.sort_custom(func(a, b): return dj[a] > dj[b])
	print("delta_hi/lo\t%s" % ", ".join(ks.slice(0, 8).map(func(k): return "%s x%d" % [k, dj[k]])))

	# 3. Per-sector: are the values a contiguous RUN (a sequence number) or a
	#    scattered set (a reference)? Also how far the sector's own values
	#    spread, and whether two different sectors reuse the same values.
	var per_sector: Array[Dictionary] = []
	for s: Array in [[7, 7], [14, 14], [50, 39], [64, 39]]:
		var stream := world.sector(s[0], s[1])
		if stream.is_empty():
			continue
		var vals: Dictionary = {}
		var cells := 0
		for ci in Sacred.SECT * Sacred.SECT:
			var h := stream.decode_u32(Sacred.NAME + ci * Sacred.CELL + 0x0c)
			while h != 0:
				var r := fp.blob(h)
				if r.size() < 16:
					break
				cells += 1
				var hi := r.decode_u32(4) >> 17
				vals[hi] = int(vals.get(hi, 0)) + 1
				var nxt := r.decode_u32(0x0c)
				h = nxt if nxt == h + 1 else 0
		var kk: Array = vals.keys()
		kk.sort()
		var nz: Array = kk.filter(func(k): return k != 0)
		var runs := 0
		for j in range(1, nz.size()):
			if nz[j] != nz[j - 1] + 1:
				runs += 1
		print("sector\t%d,%d\tlinks=%d\tdistinct=%d\tnonzero_min=%s\tnonzero_max=%s\tgaps=%d" % [
			s[0], s[1], cells, vals.size(),
			"-" if nz.is_empty() else str(nz[0]), "-" if nz.is_empty() else str(nz[nz.size() - 1]),
			runs])
		per_sector.append(vals)
	# Overlap between sectors: a per-sector sequence number would barely
	# overlap; a global reference table would overlap heavily.
	for a in per_sector.size():
		for b in range(a + 1, per_sector.size()):
			var shared := 0
			for k: int in per_sector[a].keys():
				if k != 0 and per_sector[b].has(k):
					shared += 1
			print("overlap\t%d vs %d\tshared=%d\tof=%d/%d" % [
				a, b, shared, per_sector[a].size(), per_sector[b].size()])
	quit()
