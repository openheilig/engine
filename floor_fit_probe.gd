extends SceneTree
## Probe: fit floor.pak +0x04 as a function of the referencing cell. Dumps
## (lx, ly, chain position) -> value in hex for one sector, then reports the
## deltas per +1 in lx, per +1 in ly, and per chain step. Read-only.
##   godot --headless --path godot-port --script res://floor_fit_probe.gd
const GX := 7
const GY := 7

func _f04(fp: Sacred.Pak, h: int) -> int:
	var r := fp.blob(h)
	return -1 if r.size() < 16 else r.decode_u32(4)


func _init() -> void:
	var install := Sacred.find_install()
	var world := Sacred.World.new(install.path_join("world"))
	var fp := Sacred.Pak.new(install.path_join("world/floor.pak"))
	var stream := world.sector(GX, GY)

	var head: Dictionary = {}      ## cell index -> handle
	for i in Sacred.SECT * Sacred.SECT:
		var h := stream.decode_u32(Sacred.NAME + i * Sacred.CELL + 0x0c)
		if h != 0:
			head[i] = h

	# A contiguous run in x, and a contiguous run in y, printed in hex.
	for ly in [0, 1, 2]:
		var row := ""
		for lx in range(28, 44):
			var i: int = ly * Sacred.SECT + lx
			row += ("%08x " % _f04(fp, head[i])) if head.has(i) else "-------- "
		print("row ly=%d  %s" % [ly, row])
	for lx in [32, 33]:
		var col := ""
		for ly in range(0, 10):
			var i: int = ly * Sacred.SECT + lx
			col += ("%08x " % _f04(fp, head[i])) if head.has(i) else "-------- "
		print("col lx=%d  %s" % [lx, col])

	# Deltas, measured over every adjacent pair that exists.
	var dx: Dictionary = {}
	var dy: Dictionary = {}
	for i: int in head:
		var lx: int = i % Sacred.SECT
		var ly: int = i / Sacred.SECT
		var v: int = _f04(fp, head[i])
		if lx + 1 < Sacred.SECT and head.has(i + 1):
			dx[_f04(fp, head[i + 1]) - v] = int(dx.get(_f04(fp, head[i + 1]) - v, 0)) + 1
		if ly + 1 < Sacred.SECT and head.has(i + Sacred.SECT):
			var d: int = _f04(fp, head[i + Sacred.SECT]) - v
			dy[d] = int(dy.get(d, 0)) + 1
	var ks: Array = dx.keys(); ks.sort_custom(func(a, b): return dx[a] > dx[b])
	for k: int in ks.slice(0, 6):
		print("delta_x\t%d\t0x%x\tcount=%d" % [k, k, dx[k]])
	ks = dy.keys(); ks.sort_custom(func(a, b): return dy[a] > dy[b])
	for k: int in ks.slice(0, 6):
		print("delta_y\t%d\t0x%x\tcount=%d" % [k, k, dy[k]])

	# Chain steps: what changes between a cell's first and second floor record?
	var dchain: Dictionary = {}
	for i: int in head:
		var h: int = head[i]
		var nxt: int = fp.blob(h).decode_u32(0x0c)
		if nxt > 0 and nxt < fp.count():
			var d: int = _f04(fp, nxt) - _f04(fp, h)
			dchain[d] = int(dchain.get(d, 0)) + 1
	ks = dchain.keys(); ks.sort_custom(func(a, b): return dchain[a] > dchain[b])
	for k: int in ks.slice(0, 8):
		print("delta_chain\t%d\t0x%x\tcount=%d" % [k, k, dchain[k]])
	quit()
