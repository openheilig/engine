extends SceneTree
## Probe: does PakItemType.spawnInfoId (+0x18, rs_file.h:358-386) link a
## trigger-carrying static's items record to creature.pak? creature.pak is a
## FLAT table (CIF, 474 records, 86-byte stride from offset 256) -- NOT a
## generic Pak container, so it is read here as raw bytes. Read-only.
##   godot --headless --path godot-port --script res://spawninfo_probe.gd
const SPAWNINFO_OFF := 0x18
const CREATURE_DATA := 256
const CREATURE_REC := 86

func _init() -> void:
	var install := Sacred.find_install()
	var items_pak := Sacred.Pak.new(install.path_join("pak/items.pak"))
	var items := Sacred.Items.new(items_pak)
	var static_pak := Sacred.Pak.new(install.path_join("world/static.pak"))
	var cre := FileAccess.get_file_as_bytes(install.path_join("pak/creature.pak"))
	var cre_count := cre.decode_u32(4)
	print("creature\tcount=%d\tsize=%d\tstride_fits=%s" % [
		cre_count, cre.size(), CREATURE_DATA + cre_count * CREATURE_REC == cre.size()])

	# Every live trigger's target static -> its items record -> +0x18.
	var tb := FileAccess.get_file_as_bytes(install.path_join("world/triggers.pak"))
	var tcount := tb.decode_u32(4)
	var in_range := 0
	var live := 0
	var zero := 0
	var vals: Dictionary = {}
	var shown := 0
	for i in tcount:
		var o := 0x10c + i * 16
		if tb.decode_u16(o + 4) != 16:
			continue
		live += 1
		var srec := tb.decode_u32(o + 6)
		var itype := static_pak.blob(srec).decode_u32(4)
		var r := items_pak.blob(itype)
		if r.size() < Sacred.Items.REC_MIN:
			continue
		var spawn := r.decode_u32(SPAWNINFO_OFF)
		vals[spawn] = int(vals.get(spawn, 0)) + 1
		if spawn == 0:
			zero += 1
		elif spawn < cre_count:
			in_range += 1
		if shown < 14:
			shown += 1
			print("trig\tid=%d\tstatic=%d\titems=%d\tname=%s\tspawnInfoId=%d" % [
				i, srec, itype, items.name_of(itype), spawn])
	print("summary\tlive=%d\tspawn_zero=%d\tspawn_in_creature_range=%d\tdistinct=%d" % [
		live, zero, in_range, vals.size()])
	quit()
