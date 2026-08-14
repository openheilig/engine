extends SceneTree
## Probe: what is world/floor.pak's +0x04? Record is 16 bytes:
##   +0x00 self index   +0x04 ???   +0x08 zero   +0x0c next index (self+1 or 0)
## Read-only.
##   godot --headless --path godot-port --script res://probes/floor_field_probe.gd
const GX := 7
const GY := 7

func _init() -> void:
	var install := Sacred.find_install()
	var world := Sacred.World.new(install.path_join("world"))
	var fp := Sacred.Pak.new(install.path_join("world/floor.pak"))

	# 1. Shape of +0x04 over a spread of the table: cardinality and range.
	var vals: Dictionary = {}
	var lo := 1 << 62
	var hi := -1
	var zero := 0
	var n := 0
	for i in range(1, fp.count(), 977):        # coprime-ish stride, ~6871 samples
		var r := fp.blob(i)
		if r.size() < 16:
			continue
		n += 1
		var v := r.decode_u32(4)
		vals[v] = int(vals.get(v, 0)) + 1
		if v == 0:
			zero += 1
		lo = mini(lo, v)
		hi = maxi(hi, v)
	print("field04\tsampled=%d\tdistinct=%d\tzero=%d\tmin=%d\tmax=%d" % [n, vals.size(), zero, lo, hi])
	# top repeats, if any
	var top: Array = []
	for k: int in vals:
		if vals[k] > 1:
			top.append([vals[k], k])
	top.sort_custom(func(a, b): return a[0] > b[0])
	for t in top.slice(0, 8):
		print("repeat\tvalue=%d\tcount=%d" % [t[1], t[0]])

	# 2. Reinterpretations of one handful of values, so the shape is visible.
	for i in [1, 2, 3, 100, 1000, 500000, 3000000, 6713135]:
		var r := fp.blob(i)
		if r.size() < 16:
			continue
		var v := r.decode_u32(4)
		print("reinterp\ti=%d\tu32=%d\thex=0x%08x\thi16=%d\tlo16=%d\tf32=%.6g\tbytes=%d,%d,%d,%d" % [
			i, v, v, (v >> 16) & 0xffff, v & 0xffff, r.decode_float(4),
			r[4], r[5], r[6], r[7]])

	# 3. In ONE sector, tie each cell's handle to the cell and its terrain tile,
	#    so any positional or tile correlation shows up directly.
	var stream := world.sector(GX, GY)
	var shown := 0
	var handles: Dictionary = {}
	var chain_lens: Dictionary = {}
	for i in Sacred.SECT * Sacred.SECT:
		var base := Sacred.NAME + i * Sacred.CELL
		var h := stream.decode_u32(base + 0x0c)
		if h == 0:
			continue
		handles[h] = int(handles.get(h, 0)) + 1
		# chain length behind this handle
		var cur := h
		var len := 0
		var seen: Dictionary = {}
		while cur > 0 and cur < fp.count() and not seen.has(cur) and len < 64:
			seen[cur] = true
			len += 1
			cur = fp.blob(cur).decode_u32(0x0c)
		chain_lens[len] = int(chain_lens.get(len, 0)) + 1
		if shown < 16:
			shown += 1
			var r := fp.blob(h)
			print("cell\tlx=%d\tly=%d\ttile=%d\thandle=%d\tf04=%d\tnext=%d\tchain=%d" % [
				i % Sacred.SECT, i / Sacred.SECT, stream.decode_u32(base) & 0xffff,
				h, r.decode_u32(4), r.decode_u32(0x0c), len])
	print("sector\t%d,%d\tcells_with_handle=%d\tdistinct_handles=%d" % [
		GX, GY, handles.values().reduce(func(a, b): return a + b, 0), handles.size()])
	var cl: Array = chain_lens.keys(); cl.sort()
	for k: int in cl:
		print("chain_len\t%d\t%d" % [k, chain_lens[k]])
	quit()
