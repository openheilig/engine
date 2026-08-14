extends SceneTree
## Probe 6: if floor.pak +0x04's top field is a SECOND tiles.pak index, it must
## resolve like one. Read-only.
##   godot --headless --path godot-port --script res://floor_hi6_probe.gd
##
## The retail reader at 0x080e4ca5 splits the payload exactly as row 695 said
## (ecx = v & 0x1ffff, esi = v >> 0x11) and then treats BOTH halves the same
## way: each is divided by 18 for its diamond slot, each is pushed into the
## same tile lookup against cWorld+0x254, and the two results are written into
## ONE vertex struct as two UV pairs (+0x00/+0x04 from the low field,
## +0x08/+0x0c from the top). A zero top field takes a single-texture path.
##
## So the prediction is specific: the top field's values must be valid tile
## ids whose textures resolve, and -- because they occupy a narrow low band --
## they should draw from a much smaller texture set than the tiles they are
## blended with.
const LOW17 := 0x1ffff


func _init() -> void:
	var install := Sacred.find_install()
	var fp := Sacred.Pak.new(install.path_join("world/floor.pak"))
	var tiles := Sacred.Tiles.new(install.path_join("pak/tiles.pak"))

	var n := 0
	var hi_ok := 0
	var hi_tex: Dictionary = {}
	var lo_tex: Dictionary = {}
	var hi_slot: Dictionary = {}
	var slot_agree := 0
	var pairs := 0
	var samples: Array = []
	for i in range(1, fp.count(), 31):
		var r := fp.blob(i)
		if r.size() < 16:
			continue
		var v := r.decode_u32(4)
		var lo := v & LOW17
		var hi := v >> 17
		if lo < tiles.count():
			lo_tex[tiles.texture_id(lo)] = true
		if hi == 0:
			continue
		n += 1
		if hi < tiles.count():
			hi_ok += 1
			var t := tiles.texture_id(hi)
			hi_tex[t] = true
			hi_slot[tiles.orientation(hi)] = true
			# The engine derives the slot as index % 18 for BOTH fields; if the
			# tiles.pak record's own +0x24 agrees, the two decodes are the same.
			if tiles.orientation(hi) == hi % 18:
				slot_agree += 1
			pairs += 1
			if samples.size() < 10:
				samples.append("hi=%d -> tex=%d slot=%d (%%18=%d) | lo=%d -> tex=%d" % [
					hi, t, tiles.orientation(hi), hi % 18, lo,
					tiles.texture_id(lo) if lo < tiles.count() else -1])
	print("hi_as_tile\tnonzero=%d\tvalid_index=%d\tdistinct_textures=%d\tdistinct_slots=%d" % [
		n, hi_ok, hi_tex.size(), hi_slot.size()])
	print("lo_as_tile\tdistinct_textures=%d" % lo_tex.size())
	print("slot_rule\tagree_with_mod18=%d/%d" % [slot_agree, pairs])
	var shared := 0
	for t: int in hi_tex.keys():
		if lo_tex.has(t):
			shared += 1
	print("texture_overlap\thi_textures_also_used_as_ground=%d of %d" % [shared, hi_tex.size()])
	var tk: Array = hi_tex.keys(); tk.sort()
	print("hi_textures\t%s" % ", ".join(tk.slice(0, 20).map(func(k): return str(k))))
	for s: String in samples:
		print("sample\t%s" % s)
	quit()
