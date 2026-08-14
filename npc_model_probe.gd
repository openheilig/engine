extends SceneTree
## Probe: does a trigger-carrying static's items name resolve to a REAL model in
## models.pak, and is that model a whole body or one equipment piece? This is
## the prerequisite row 690 flagged before any NPC drawing is attempted.
## Read-only.
##   godot --headless --path godot-port --script res://npc_model_probe.gd

func _init() -> void:
	var install := Sacred.find_install()
	var models := Sacred.Models.new(Sacred.Pak.new(install.path_join("pak/models.pak")))
	var items := Sacred.Items.new(Sacred.Pak.new(install.path_join("pak/items.pak")))
	print("models_count=%d" % models.count())

	# 1. The chapel priestess's own name, plus the hero model as a known-good
	#    control, plus the other frequent trigger targets from the row-690 roster.
	for nm in ["mage_elements_cowl.grn", "mage_elements_legs.grn", "GLADIATOR.GRN",
			"SERAPHIM.GRN", "MUMMY.GRN", "RABBIT.GRN", "Hornisse02.grn", "W03.GRN"]:
		var idx := models.index_of(nm)
		var verts := 0
		var tris := 0
		if idx >= 0:
			var arr := models.mesh_arrays(idx)
			if not arr.is_empty():
				verts = (arr["vertex"] as PackedVector3Array).size() if arr.has("vertex") else 0
				tris = (arr["index"] as PackedInt32Array).size() / 3 if arr.has("index") else 0
		print("model\tname=%s\tindex=%d\tverts=%d\ttris=%d" % [nm, idx, verts, tris])

	# 2. Every models.pak entry whose name starts mage_elements -- if the NPC is
	#    assembled from pieces, the set of pieces is the evidence.
	var hits := 0
	for i in models.count():
		var nm := models.entry_name(i)
		if nm.to_lower().begins_with("mage_elements"):
			hits += 1
			if hits <= 30:
				print("piece\tindex=%d\tname=%s" % [i, nm])
	print("mage_elements_entries=%d" % hits)

	# 3. Does items.pak name any OTHER record with the same mage_elements stem?
	#    A static names one record; the rest of the outfit would be siblings.
	var stems: Dictionary = {}
	for rec in 40000:
		var nm := items.name_of(rec)
		if nm.to_lower().begins_with("mage_elements"):
			stems[nm] = rec
	var ks: Array = stems.keys(); ks.sort()
	for k: String in ks:
		print("itemrec\t%s\trec=%d\tsprite=%d" % [k, stems[k], items.sprite_of(stems[k])])
	quit()
