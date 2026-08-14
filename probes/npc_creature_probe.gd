extends SceneTree
## Probe: do world-placed dynamic statics (+0x08 == 0x10, non-zero triggerId)
## name a CREATURE, now that creature id is known to be an items.pak record
## index? Read-only.
##   godot --headless --path godot-port --script res://probes/npc_creature_probe.gd
const DATA := 256
const REC := 86
const PRIESTESS_STATIC := 758529

func _init() -> void:
	var install := Sacred.find_install()
	var cb := FileAccess.get_file_as_bytes(install.path_join("pak/creature.pak"))
	var by_id: Dictionary = {}
	for i in cb.decode_u32(4):
		by_id[cb.decode_u32(DATA + i * REC)] = i
	var items := Sacred.Items.new(Sacred.Pak.new(install.path_join("pak/items.pak")))
	var static_pak := Sacred.Pak.new(install.path_join("world/static.pak"))
	var tb := FileAccess.get_file_as_bytes(install.path_join("world/triggers.pak"))

	var hit := 0
	var miss := 0
	var miss_names: Dictionary = {}
	var hit_classes: Dictionary = {}
	for i in tb.decode_u32(4):
		var o := 0x10c + i * 16
		if tb.decode_u16(o + 4) != 16:
			continue
		var itype := static_pak.blob(tb.decode_u32(o + 6)).decode_u32(4)
		if by_id.has(itype):
			hit += 1
			var cls := cb.decode_u16(DATA + int(by_id[itype]) * REC + 4)
			hit_classes[cls] = int(hit_classes.get(cls, 0)) + 1
		else:
			miss += 1
			var nm := items.name_of(itype)
			miss_names[nm if nm != "" else "<unnamed>"] = int(miss_names.get(nm if nm != "" else "<unnamed>", 0)) + 1
	print("targets\tcreature=%d\tnot_creature=%d" % [hit, miss])
	var ks: Array = hit_classes.keys(); ks.sort()
	for k: int in ks:
		print("hit_class\t%d\t%d" % [k, hit_classes[k]])
	var ms: Array = miss_names.keys(); ms.sort()
	var shown := 0
	for m: String in ms:
		if miss_names[m] >= 5 and shown < 25:
			shown += 1
			print("miss_name\t%s\t%d" % [m, miss_names[m]])

	# The chapel priestess specifically.
	var pt := static_pak.blob(PRIESTESS_STATIC).decode_u32(4)
	print("priestess\titems_type=%d\tname=%s\tis_creature=%s" % [
		pt, items.name_of(pt), by_id.has(pt)])
	if by_id.has(pt):
		var o := DATA + int(by_id[pt]) * REC
		print("priestess\tclass=%d\tflags=%d\txpA=%d\txpB=%d\twalk=%d\trun=%d" % [
			cb.decode_u16(o + 4), cb[o + 6], cb.decode_u16(o + 8), cb.decode_u16(o + 0x0a),
			cb.decode_u16(o + 0x26), cb.decode_u16(o + 0x28)])
	quit()
