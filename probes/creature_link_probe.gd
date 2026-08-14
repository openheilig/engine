extends SceneTree
## Probe: are the items-record indices used by trigger-carrying statics the same
## id space as creature.pak's per-record id? creature.pak is a FLAT CIF table:
## 474 records of 86 bytes from offset 256 (verified: 256 + 474*86 == 41020).
## The 490 "unnamed" live triggers point at items records that are entirely
## zero, so for those the record INDEX is the only identifier that survives --
## if it appears in creature.pak's id column, that is the missing link.
## Read-only.
##   godot --headless --path godot-port --script res://probes/creature_link_probe.gd
const DATA := 256
const REC := 86

func _init() -> void:
	var install := Sacred.find_install()
	var cre := FileAccess.get_file_as_bytes(install.path_join("pak/creature.pak"))
	var n := cre.decode_u32(4)
	var ids: Dictionary = {}
	var lo := 1 << 30
	var hi := -1
	for i in n:
		var id := cre.decode_u32(DATA + i * REC)
		ids[id] = i
		lo = mini(lo, id)
		hi = maxi(hi, id)
	print("creature\tcount=%d\tdistinct_ids=%d\tid_range=%d..%d" % [n, ids.size(), lo, hi])

	var items_pak := Sacred.Pak.new(install.path_join("pak/items.pak"))
	var items := Sacred.Items.new(items_pak)
	var static_pak := Sacred.Pak.new(install.path_join("world/static.pak"))
	var tb := FileAccess.get_file_as_bytes(install.path_join("world/triggers.pak"))

	var named_hit := 0
	var named_total := 0
	var unnamed_hit := 0
	var unnamed_total := 0
	var unnamed_types: Dictionary = {}
	for i in tb.decode_u32(4):
		var o := 0x10c + i * 16
		if tb.decode_u16(o + 4) != 16:
			continue
		var itype := static_pak.blob(tb.decode_u32(o + 6)).decode_u32(4)
		if items.name_of(itype) == "":
			unnamed_total += 1
			unnamed_types[itype] = true
			if ids.has(itype):
				unnamed_hit += 1
		else:
			named_total += 1
			if ids.has(itype):
				named_hit += 1
	print("link\tunnamed=%d\tunnamed_in_creature_ids=%d\tdistinct_unnamed_types=%d" % [
		unnamed_total, unnamed_hit, unnamed_types.size()])
	print("link\tnamed=%d\tnamed_in_creature_ids=%d" % [named_total, named_hit])

	# Control: how often would a random items index in the same range hit?
	var in_range := 0
	for t: int in unnamed_types:
		if t >= lo and t <= hi:
			in_range += 1
	print("control\tunnamed_types_inside_creature_id_range=%d of %d" % [in_range, unnamed_types.size()])
	quit()
