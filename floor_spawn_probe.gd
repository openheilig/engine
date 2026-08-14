extends SceneTree
## Probe: is floor.pak +0x04's low 16 bits a CREATURE id? Creature ids are
## items.pak record indices (row 693), so this is a clean set-membership test
## with a control. Read-only.
##   godot --headless --path godot-port --script res://floor_spawn_probe.gd
const CDATA := 256
const CREC := 86

func _init() -> void:
	var install := Sacred.find_install()
	var fp := Sacred.Pak.new(install.path_join("world/floor.pak"))
	var items_pak := Sacred.Pak.new(install.path_join("pak/items.pak"))
	var items := Sacred.Items.new(items_pak)
	var cb := FileAccess.get_file_as_bytes(install.path_join("pak/creature.pak"))
	var by_id: Dictionary = {}
	for i in cb.decode_u32(4):
		by_id[cb.decode_u32(CDATA + i * CREC)] = i

	var total := 0
	var lo_creature := 0
	var lo_grn := 0
	var lo_named := 0
	var hi_creature := 0        ## control
	var cls_hist: Dictionary = {}
	for i in range(1, fp.count(), 977):
		var r := fp.blob(i)
		if r.size() < 16:
			continue
		total += 1
		var v := r.decode_u32(4)
		var lo := v & 0xffff
		var hi := (v >> 16) & 0xffff
		var nm := items.name_of(lo)
		if nm != "":
			lo_named += 1
			if nm.to_lower().ends_with(".grn"):
				lo_grn += 1
		if by_id.has(lo):
			lo_creature += 1
			var cls := cb.decode_u16(CDATA + int(by_id[lo]) * CREC + 4)
			cls_hist[cls] = int(cls_hist.get(cls, 0)) + 1
		if by_id.has(hi):
			hi_creature += 1
	print("spawn\tsampled=%d\tlo_named=%d\tlo_grn=%d\tlo_is_creature=%d\tHI_is_creature_CONTROL=%d" % [
		total, lo_named, lo_grn, lo_creature, hi_creature])
	var ks: Array = cls_hist.keys(); ks.sort()
	for k: int in ks:
		print("spawn_class\t%d\t%d" % [k, cls_hist[k]])

	# Baseline: what fraction of ALL items records name a .grn at all? Without
	# this the lo_grn number means nothing.
	var all_named := 0
	var all_grn := 0
	for rec in items_pak.count():
		var nm := items.name_of(rec)
		if nm != "":
			all_named += 1
			if nm.to_lower().ends_with(".grn"):
				all_grn += 1
	print("baseline\titems_named=%d\titems_grn=%d\tgrn_share=%.4f" % [
		all_named, all_grn, float(all_grn) / float(maxi(all_named, 1))])
	quit()
