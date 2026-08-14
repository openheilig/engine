extends SceneTree
## Probe 3: is floor.pak +0x04's top field DERIVED FROM THE TILE, rather than
## being independent per-cell data? Read-only.
##   godot --headless --path godot-port --script res://floor_hi3_probe.gd
##
## Two measurements from probe 2 point this way: sectors on opposite sides of
## the world share 310 of 311 distinct values (so it is a global enumeration,
## not a per-sector counter), and the commonest record-to-record deltas move
## hi and lo BY THE SAME AMOUNT (+2/+2, -1/-1, +1/+1, +6/+6). The clean test is
## functional dependency: if one tile index never appears with two different
## hi values, hi carries no per-cell information at all.
const LOW17 := 0x1ffff


func _init() -> void:
	var install := Sacred.find_install()
	var fp := Sacred.Pak.new(install.path_join("world/floor.pak"))
	var tiles := Sacred.Tiles.new(install.path_join("pak/tiles.pak"))

	var hi_of: Dictionary = {}       ## tile index -> first hi seen
	var conflicts := 0
	var seen := 0
	var n := 0
	## And the reverse: does one hi value pin one texture?
	var tex_of: Dictionary = {}
	var tex_conflicts := 0
	var samples: Array = []
	for i in range(1, fp.count(), 37):
		var r := fp.blob(i)
		if r.size() < 16:
			continue
		n += 1
		var v := r.decode_u32(4)
		var lo := v & LOW17
		var hi := v >> 17
		if hi_of.has(lo):
			seen += 1
			if hi_of[lo] != hi:
				conflicts += 1
		else:
			hi_of[lo] = hi
		if lo < tiles.count():
			var t := tiles.texture_id(lo)
			if tex_of.has(hi):
				if tex_of[hi] != t:
					tex_conflicts += 1
			else:
				tex_of[hi] = t
			if samples.size() < 12 and hi != 0:
				samples.append("tile=%d hi=%d tex=%d slot=%d" % [
					lo, hi, t, tiles.orientation(lo)])
	print("functional\tn=%d\tdistinct_tiles=%d\trepeat_tiles=%d\tconflicts=%d" % [
		n, hi_of.size(), seen, conflicts])
	print("hi_to_texture\tdistinct_hi=%d\tconflicts=%d" % [tex_of.size(), tex_conflicts])
	for s: String in samples:
		print("sample\t%s" % s)

	# If hi is derived from the tile, the obvious candidates are arithmetic on
	# the tile index or on its texture. Test each as an exact identity.
	var hits := {"tile/58": 0, "tile>>6": 0, "tex/16": 0, "tex>>4": 0, "tex%1536": 0, "tile%1536": 0}
	var tested := 0
	for lo: int in hi_of.keys():
		if lo >= tiles.count():
			continue
		var hi: int = hi_of[lo]
		if hi == 0:
			continue
		tested += 1
		var tex := tiles.texture_id(lo)
		if hi == lo / 58:
			hits["tile/58"] += 1
		if hi == lo >> 6:
			hits["tile>>6"] += 1
		if hi == tex / 16:
			hits["tex/16"] += 1
		if hi == tex >> 4:
			hits["tex>>4"] += 1
		if hi == tex % 1536:
			hits["tex%1536"] += 1
		if hi == lo % 1536:
			hits["tile%1536"] += 1
	print("identity\ttested=%d\t%s" % [tested, hits])
	quit()
