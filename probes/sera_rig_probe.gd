extends SceneTree
## WHY does SERAPHIM.GRN's walk sit on a different skeleton from its idle?
##
##   godot --headless --path . --script res://probes/sera_rig_probe.gd
##
## Row 1053: scored without Rigs.MIN_SCORE, her actions split into two clean
## groups -- 0.891..0.915 (IDLE, FIDLE, DYING, ATTACK, SPECIAL) against
## 0.255..0.273 (WALK, RUN, CAST, DEFEND, HIT, TALK, ACTIVATE) -- and the low
## group shares only 55 of her 72 mesh bone names where the high group shares
## 68..71. `SERA_WALK_1H.GRN` is hers by NAME and scores 0.255.
##
## Three questions, in the order that makes the next one cheap:
##
##   (1) WHICH NAMES differ. A missing set that reads like a body part is a
##       different rig; one that reads like weapon or wing bones is the same
##       rig plus attachments.
##   (2) WHAT SHAPE the disagreement has over the names they DO share. A
##       constant offset, a uniform scale and noise are three different
##       causes, and the residual after removing each says which.
##   (3) WHICH MESH the walk actually matches, scanning every mesh in the pak.
##       This is the decisive one: a clip that scores 0.9 against some other
##       body names that body, and settles it without inference.
const WITHIN := 0.01
const MIN_MATCHED := 20

func _init() -> void:
	var install := Sacred.find_install()
	var pak := Sacred.Pak.new(install.path_join("pak/models.pak"))
	var models := Sacred.Models.new(pak)

	var me := models.index_of("SERAPHIM.GRN")
	var mesh: Dictionary = {}
	for b in models.bones(me):
		var nm: String = (b["name"] as PackedByteArray).get_string_from_utf8()
		if nm != "" and not mesh.has(nm):
			mesh[nm] = (b["rest"] as Transform3D).origin
	print("mesh\tSERAPHIM.GRN\tentry=%d\tbones=%d" % [me, mesh.size()])

	# (1) and (2), on the two clips that bracket the split.
	for cname in ["SERA_IDLE_1H.GRN", "SERA_WALK_1H.GRN", "SERA_RUN_1H.GRN", "SERA_FIDLE_1H.GRN"]:
		var ci := models.index_of(cname)
		if ci < 0:
			print("clip\t%s\tnot in pak" % cname)
			continue
		var cn := models.clip_bone_names(ci)
		var cb := models.clip_bones(ci)
		var shared: PackedStringArray = []
		var missing: PackedStringArray = []   # clip has it, mesh does not
		var deltas: Array[Vector3] = []
		for j in cn.size():
			if mesh.has(cn[j]):
				shared.append(cn[j])
				deltas.append((cb[j]["rest"] as Transform3D).origin - (mesh[cn[j]] as Vector3))
			else:
				missing.append(cn[j])
		var absent: PackedStringArray = []    # mesh has it, clip does not
		for k: String in mesh:
			if not (k in cn):
				absent.append(k)
		var within := 0
		for d in deltas:
			if d.length() <= WITHIN:
				within += 1
		# (2) THE SHAPE. A constant offset shows as a residual far below the
		# raw distance; a uniform scale shows as a tight ratio of lengths.
		var mean := Vector3.ZERO
		for d in deltas:
			mean += d
		if not deltas.is_empty():
			mean /= float(deltas.size())
		var raw := 0.0
		var resid := 0.0
		for d in deltas:
			raw += d.length()
			resid += (d - mean).length()
		var n := maxf(1.0, float(deltas.size()))
		# Scale: |clip origin| / |mesh origin| over bones far enough from the
		# root that the ratio means anything.
		var ratios: Array[float] = []
		for j in cn.size():
			if not mesh.has(cn[j]):
				continue
			var mo: Vector3 = mesh[cn[j]]
			if mo.length() < 1.0:
				continue
			ratios.append((cb[j]["rest"] as Transform3D).origin.length() / mo.length())
		ratios.sort()
		var med := ratios[ratios.size() / 2] if not ratios.is_empty() else NAN
		print("clip\t%s\tbones=%d\tshared=%d\twithin=%d (%.3f)\tmean|d|=%.4f\tresid|d-mean|=%.4f\tmean=(%.3f,%.3f,%.3f)\tscale_med=%.4f" % [
			cname, cn.size(), shared.size(), within, float(within) / maxf(1.0, float(shared.size())),
			raw / n, resid / n, mean.x, mean.y, mean.z, med])
		print("  clip_only(%d)\t%s" % [missing.size(), missing])
		print("  mesh_only(%d)\t%s" % [absent.size(), absent])

	# (3) WHOSE skeleton is the walk on? Every mesh in the pak, scored.
	for cname in ["SERA_WALK_1H.GRN", "SERA_RUN_1H.GRN"]:
		var ci := models.index_of(cname)
		var cn := models.clip_bone_names(ci)
		var cb := models.clip_bones(ci)
		var rows: Array = []
		for e in models.count():
			if models.kind_of(e) != Sacred.Models.KIND_MESH:
				continue
			var d: Dictionary = {}
			for b in models.bones(e):
				var nm: String = (b["name"] as PackedByteArray).get_string_from_utf8()
				if nm != "" and not d.has(nm):
					d[nm] = (b["rest"] as Transform3D).origin
			if d.size() < MIN_MATCHED:
				continue
			var matched := 0
			var within := 0
			for j in cn.size():
				var o: Variant = d.get(cn[j])
				if o == null:
					continue
				matched += 1
				if (cb[j]["rest"] as Transform3D).origin.distance_to(o) <= WITHIN:
					within += 1
			if matched < MIN_MATCHED:
				continue
			rows.append([float(within) / float(matched), models.entry_name(e), matched, d.size()])
		rows.sort_custom(func(a, b): return a[0] > b[0])
		for i in mini(8, rows.size()):
			print("owner\t%s\t%.3f\t%s\tmatched=%d\tmeshbones=%d" % [
				cname, rows[i][0], rows[i][1], rows[i][2], rows[i][3]])
	quit()
