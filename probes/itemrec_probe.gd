extends SceneTree
## Probe: for each static type id given in SIDS, read items.pak RECORD[id] and
## report its name plus its own sprite field, and whether that sprite has art.
## Tests whether static.pak +0x04 is an items.pak record index (Resacred's
## PakStatic.itemTypeId -> PakItemType.mixedId chain) rather than a mixed.pak
## index directly. Read-only.
##   SIDS=9223,9224 godot --headless --path godot-port --script res://probes/itemrec_probe.gd

func _init() -> void:
	var install := Sacred.find_install()
	var items_pak := Sacred.Pak.new(install.path_join("pak/items.pak"))
	var mixed := Sacred.Mixed.new(Sacred.Pak.new(install.path_join("pak/mixed.pak")))
	print("items_pak_count=%d\tmixed_count=%d" % [items_pak.count(), mixed.count()])
	if OS.get_environment("CENSUS") == "1":
		var same := 0
		var diverge := 0
		var gained := 0     ## was blank under the old direct rule, has art now
		var lost := 0       ## drew art under the old rule, draws nothing now
		var items := Sacred.Items.new(items_pak)
		for i in items_pak.count():
			var spr_id := items.sprite_of(i)
			if spr_id == i:
				same += 1
				continue
			diverge += 1
			var had := not mixed.sprite(i).is_empty()
			var has := not mixed.sprite(spr_id).is_empty()
			if has and not had:
				gained += 1
				if gained <= 12:
					print("gained\trec=%d\tname=%s\tsprite=%d" % [i, items.name_of(i), spr_id])
			elif had and not has:
				lost += 1
				if lost <= 12:
					print("lost\trec=%d\tname=%s\tsprite=%d" % [i, items.name_of(i), spr_id])
		print("census\tsame=%d\tdiverge=%d\tgained_art=%d\tlost_art=%d" % [same, diverge, gained, lost])
	for s in OS.get_environment("SIDS").split(","):
		if s == "":
			continue
		var id := int(s)
		var direct := mixed.sprite(id)
		var r := items_pak.blob(id)
		if r.size() < Sacred.Items.REC_MIN:
			print("id=%d\tNO_ITEM_RECORD\tdirect_tiles=%d" % [
				id, 0 if direct.is_empty() else direct["tiles"].size()])
			continue
		var nm := r.slice(Sacred.Items.NAME_OFF).get_string_from_ascii()
		var spr_id := r.decode_u32(Sacred.Items.SPRITE_OFF)
		var via := mixed.sprite(spr_id)
		print("id=%d\tname=%s\tsprite_field=%d\tdirect_tiles=%d\tvia_tiles=%d" % [
			id, nm, spr_id,
			0 if direct.is_empty() else direct["tiles"].size(),
			0 if via.is_empty() else via["tiles"].size()])
	quit()
