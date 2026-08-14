extends SceneTree
## Probe 4 on floor.pak +0x04's top field. Read-only.
##   godot --headless --path godot-port --script res://floor_hi4_probe.gd
##
## Established so far: the field is 0..1535 exactly (max 1535 over 69,208
## samples, bits 11..14 dead), 37% zero, 54% in 1024..1535; the same values
## recur across sectors on opposite sides of the world; and it is NOT a
## function of the tile it sits beside (103,770 conflicts). So it is real
## per-record data with a global vocabulary.
##
## 1536 = 3 x 512, so this probe first asks whether it is really TWO fields --
## a 2-bit value that is only ever 0, 1 or 2, over a 9-bit one -- then whether
## it behaves like a quantity (smooth, ordered along a chain, tracking light
## or height) or like a table index (lumpy, arbitrary).
const LOW17 := 0x1ffff


func _init() -> void:
	var install := Sacred.find_install()
	var fp := Sacred.Pak.new(install.path_join("world/floor.pak"))
	var world := Sacred.World.new(install.path_join("world"))

	# 1. The 3 x 512 split.
	var a_hist: Dictionary = {}
	var b_hist: Dictionary = {}
	var n := 0
	for i in range(1, fp.count(), 97):
		var r := fp.blob(i)
		if r.size() < 16:
			continue
		n += 1
		var hi := r.decode_u32(4) >> 17
		a_hist[hi >> 9] = int(a_hist.get(hi >> 9, 0)) + 1
		b_hist[hi & 511] = int(b_hist.get(hi & 511, 0)) + 1
	print("split\tn=%d\tA(bits9-10)=%s\tB_distinct=%d" % [n, a_hist, b_hist.size()])
	# Lumpiness of B: a table index is uneven, a quantity is smooth.
	var bk: Array = b_hist.keys()
	bk.sort_custom(func(x, y): return b_hist[x] > b_hist[y])
	print("B_top\t%s" % ", ".join(bk.slice(0, 8).map(func(k): return "%d x%d" % [k, b_hist[k]])))
	print("B_bottom\t%s" % ", ".join(bk.slice(maxi(0, bk.size() - 5)).map(
		func(k): return "%d x%d" % [k, b_hist[k]])))

	# 2. Along a cell's chain: ordered (a draw priority) or arbitrary?
	# 3. Against the cell's own light byte and height, which are the two
	#    per-cell quantities already decoded.
	var up := 0
	var down := 0
	var mixed := 0
	var flat := 0
	var by_link_sum: Dictionary = {}
	var by_link_n: Dictionary = {}
	var light_sum := 0.0
	var light_n := 0
	var light_sum0 := 0.0
	var light_n0 := 0
	var h_nonzero := 0
	var h_cells := 0
	var hi_when_h := 0
	var hi_when_flat := 0
	var cells_h := 0
	var cells_flat := 0
	for s: Array in [[7, 7], [14, 14], [50, 39], [64, 39], [28, 14], [35, 14]]:
		var stream := world.sector(s[0], s[1])
		if stream.is_empty():
			continue
		for ci in Sacred.SECT * Sacred.SECT:
			var off := Sacred.NAME + ci * Sacred.CELL
			var h := stream.decode_u32(off + 0x0c)
			if h == 0:
				continue
			var vals: Array[int] = []
			var link := 0
			while h != 0 and link < 16:
				var r := fp.blob(h)
				if r.size() < 16:
					break
				var hi := r.decode_u32(4) >> 17
				vals.append(hi)
				by_link_sum[link] = float(by_link_sum.get(link, 0.0)) + hi
				by_link_n[link] = int(by_link_n.get(link, 0)) + 1
				var nxt := r.decode_u32(0x0c)
				h = nxt if nxt == h + 1 else 0
				link += 1
			if vals.is_empty():
				continue
			# light of this cell (mean of the four corner bytes)
			var lsum := 0.0
			for c in 4:
				lsum += stream.decode_u8(off + 0x14 + c)
			# height: any non-zero corner
			var flat_cell := true
			for c in 4:
				if stream.decode_u8(off + 0x10 + c) != 0:
					flat_cell = false
			if vals[0] != 0:
				light_sum += lsum / 4.0
				light_n += 1
			else:
				light_sum0 += lsum / 4.0
				light_n0 += 1
			if flat_cell:
				cells_flat += 1
				if vals[0] != 0:
					hi_when_flat += 1
			else:
				cells_h += 1
				if vals[0] != 0:
					hi_when_h += 1
			if vals.size() > 1:
				var inc := true
				var dec := true
				for j in range(1, vals.size()):
					if vals[j] <= vals[j - 1]:
						inc = false
					if vals[j] >= vals[j - 1]:
						dec = false
				var same := true
				for v in vals:
					if v != vals[0]:
						same = false
				if same:
					flat += 1
				elif inc:
					up += 1
				elif dec:
					down += 1
				else:
					mixed += 1
	print("chain_order\tconstant=%d\tincreasing=%d\tdecreasing=%d\tmixed=%d" % [
		flat, up, down, mixed])
	var lk: Array = by_link_sum.keys(); lk.sort()
	print("mean_by_link\t%s" % ", ".join(lk.slice(0, 6).map(
		func(k): return "L%d=%.0f (n=%d)" % [k, by_link_sum[k] / by_link_n[k], by_link_n[k]])))
	print("light\tmean_when_hi_nonzero=%.1f (n=%d)\tmean_when_hi_zero=%.1f (n=%d)" % [
		0.0 if light_n == 0 else light_sum / light_n, light_n,
		0.0 if light_n0 == 0 else light_sum0 / light_n0, light_n0])
	print("height\tP(hi!=0 | sloped)=%.3f (n=%d)\tP(hi!=0 | flat)=%.3f (n=%d)" % [
		0.0 if cells_h == 0 else float(hi_when_h) / cells_h, cells_h,
		0.0 if cells_flat == 0 else float(hi_when_flat) / cells_flat, cells_flat])
	quit()
