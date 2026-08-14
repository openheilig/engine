extends SceneTree
## Probe: what are world/floor.pak +0x04's TOP 15 BITS? Read-only.
##   godot --headless --path godot-port --script res://floor_hi_probe.gd
##
## Row 695 pinned the low 17 bits as a tiles.pak index and left the top 15
## undecoded: 417 distinct values, range 0..1535, 0 by far commonest, hundreds
## of distinct values inside one sector (so not a sector id), and its commonest
## adjacency delta pairs with the tile index's (+0x20001) (so not obviously a
## layer or draw order). Row 700 then drew the layer, which is what makes the
## structural questions below answerable.
##
## Nothing here concludes anything. It measures six things and prints them:
##   1. which BITS are ever set -- sub-field boundaries show up as dead bits
##   2. whether the value is CONSTANT WITHIN a cell's chain
##   3. whether NEIGHBOURING cells agree, against a shuffled baseline
##   4. how many distinct tile ORIENTATIONS one value co-occurs with
##   5. how many distinct TEXTURES one value co-occurs with
##   6. whether the value tracks the CHAIN POSITION (link 0, 1, 2 ...)
const LOW17 := 0x1ffff
const STRIDE := 977


func _init() -> void:
	var install := Sacred.find_install()
	var fp := Sacred.Pak.new(install.path_join("world/floor.pak"))
	var tiles := Sacred.Tiles.new(install.path_join("pak/tiles.pak"))
	var world := Sacred.World.new(install.path_join("world"))

	# 1. Bit occupancy over a global stride sample.
	var bits := PackedInt32Array()
	bits.resize(15)
	var n := 0
	var hist: Dictionary = {}
	for i in range(1, fp.count(), STRIDE):
		var r := fp.blob(i)
		if r.size() < 16:
			continue
		n += 1
		var hi := r.decode_u32(4) >> 17
		hist[hi] = int(hist.get(hi, 0)) + 1
		for b in 15:
			if hi & (1 << b):
				bits[b] += 1
	var parts: Array = []
	for b in 15:
		parts.append("b%d=%.3f" % [b, float(bits[b]) / float(n)])
	print("bits\tn=%d\t%s" % [n, " ".join(parts)])
	print("hist\tdistinct=%d\tzero=%.3f" % [hist.size(), float(hist.get(0, 0)) / float(n)])

	# 2/6. Chains: is the value constant along one cell's chain, and does it
	#      track the link index?
	var chains := 0
	var chains_const := 0
	var by_link: Dictionary = {}          ## link index -> {value -> count}
	var len_hist: Dictionary = {}
	# 3. Neighbour agreement, and the same statistic against a random pairing.
	var pairs := 0
	var pairs_eq := 0
	var shuf_pairs := 0
	var shuf_eq := 0
	# 4/5. What one value co-occurs with.
	var orient_of: Dictionary = {}        ## value -> {orientation -> true}
	var tex_of: Dictionary = {}           ## value -> {texture id -> true}
	var all_vals: Array[int] = []

	for s: Array in [[7, 7], [14, 14], [50, 39], [64, 39], [28, 14]]:
		var stream := world.sector(s[0], s[1])
		if stream.is_empty():
			continue
		var head: Dictionary[int, int] = {}   ## cell index -> first link's value
		for ci in Sacred.SECT * Sacred.SECT:
			var h := stream.decode_u32(Sacred.NAME + ci * Sacred.CELL + 0x0c)
			if h == 0:
				continue
			var vals: Array[int] = []
			var link := 0
			while h != 0 and link < 16:
				var r := fp.blob(h)
				if r.size() < 16:
					break
				var v := r.decode_u32(4)
				var hi := v >> 17
				var tid := v & LOW17
				vals.append(hi)
				all_vals.append(hi)
				if not by_link.has(link):
					by_link[link] = {}
				by_link[link][hi] = int(by_link[link].get(hi, 0)) + 1
				if not orient_of.has(hi):
					orient_of[hi] = {}
					tex_of[hi] = {}
				if tid < tiles.count():
					orient_of[hi][tiles.orientation(tid)] = true
					tex_of[hi][tiles.texture_id(tid)] = true
				var nxt := r.decode_u32(0x0c)
				h = nxt if nxt == h + 1 else 0
				link += 1
			if vals.is_empty():
				continue
			len_hist[vals.size()] = int(len_hist.get(vals.size(), 0)) + 1
			head[ci] = vals[0]
			if vals.size() > 1:
				chains += 1
				var same := true
				for v2 in vals:
					if v2 != vals[0]:
						same = false
				if same:
					chains_const += 1
		# Neighbour agreement inside this sector: E and S neighbours that also
		# carry a handle.
		for ci: int in head.keys():
			for d: int in [1, Sacred.SECT]:
				var nj := ci + d
				if d == 1 and ci % Sacred.SECT == Sacred.SECT - 1:
					continue
				if not head.has(nj):
					continue
				pairs += 1
				if head[ci] == head[nj]:
					pairs_eq += 1
		# Shuffled control: same value multiset, no spatial relation.
		var vs: Array = head.values()
		vs.shuffle()
		for k in range(1, vs.size()):
			shuf_pairs += 1
			if vs[k] == vs[k - 1]:
				shuf_eq += 1

	print("chain\tmulti=%d\tconstant_along_chain=%d (%.3f)\tlen_hist=%s" % [
		chains, chains_const,
		0.0 if chains == 0 else float(chains_const) / float(chains), len_hist])
	print("neighbour\tpairs=%d\teq=%.3f\tshuffled_pairs=%d\tshuffled_eq=%.3f" % [
		pairs, 0.0 if pairs == 0 else float(pairs_eq) / float(pairs),
		shuf_pairs, 0.0 if shuf_pairs == 0 else float(shuf_eq) / float(shuf_pairs)])

	var lk: Array = by_link.keys(); lk.sort()
	for l: int in lk.slice(0, 6):
		var d: Dictionary = by_link[l]
		var ks: Array = d.keys()
		ks.sort_custom(func(a, b): return d[a] > d[b])
		print("link%d\tn=%d\tdistinct=%d\ttop=%s" % [
			l, all_vals.size(), d.size(),
			", ".join(ks.slice(0, 5).map(func(k): return "%d x%d" % [k, d[k]]))])

	# 4/5 summary: if the value SELECTED the orientation or the texture, one
	# value would co-occur with exactly one of them.
	var o1 := 0
	var t1 := 0
	for v: int in orient_of.keys():
		if (orient_of[v] as Dictionary).size() == 1:
			o1 += 1
		if (tex_of[v] as Dictionary).size() == 1:
			t1 += 1
	print("cooccur\tvalues=%d\tsingle_orientation=%d\tsingle_texture=%d" % [
		orient_of.size(), o1, t1])
	quit()
