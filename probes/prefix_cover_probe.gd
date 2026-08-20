extends SceneTree
## Would a prefix-admitted clip actually ANIMATE the mesh it is given to?
##
##   godot --headless --path . --script res://probes/prefix_cover_probe.gd
##
## prefix_probe measured what the rule would ADD (+8 actions for the Seraphim,
## +1..3 for five others, nothing for the other 121 meshes) and that 26 of 85
## claimed prefixes are claimed by more than one mesh. Neither number says
## whether the admitted clip is USABLE, and a name-based argument about whether
## a Troll and a Baumbart are "the same creature" cannot answer it either.
##
## THE CRITERION THAT CAN. view/model_view.gd sets BIND_POSITION_TRACKS false,
## so a clip contributes ROTATIONS ONLY, bound by bone NAME. A clip is usable
## on a mesh exactly when it names that mesh's bones -- the rest positions Rigs
## scores on are discarded before playback. So this measures NAME COVERAGE of
## the deforming skeleton, and separately of the Bip01 chain, which is the part
## whose absence would show on screen.
##
## Also fixes prefix_probe's empty-prefix bucket: a clip whose name begins with
## an underscore yields prefix "", which pooled 29 unrelated clips and handed
## CROW.GRN three actions off the back of it. "" is not a prefix.
const MIN_MATCHED := 20
const TARGETS := ["SERAPHIM.GRN", "GLADIATOR.GRN", "THIEF2_MAL.GRN", "THIEF2_FEM.GRN",
	"NOBLE_FEM.GRN", "CROW.GRN", "MAGICIAN.GRN", "DRYAD_SCOUT.GRN", "TROLL.GRN", "BAUMBART.GRN"]
const CACHE := "user://rigmap.tsv"

func _init() -> void:
	var install := Sacred.find_install()
	var pak := Sacred.Pak.new(install.path_join("pak/models.pak"))
	var models := Sacred.Models.new(pak)
	var f := FileAccess.open(CACHE, FileAccess.READ)
	if f == null:
		print("no cache")
		return
	f.get_line()
	var best: Dictionary = {}
	var acts: Dictionary = {}
	while not f.eof_reached():
		var parts := f.get_line().split("\t")
		if parts.size() == 3:
			best[int(parts[0])] = int(parts[1])
		elif parts.size() == 4 and parts[0] == "a":
			var e := int(parts[1])
			if not acts.has(e):
				acts[e] = {}
			(acts[e] as Dictionary)[parts[2]] = int(parts[3])
	var by_prefix: Dictionary = {}
	for ci in models.count():
		if models.kind_of(ci) != Sacred.Models.KIND_MOTION or not models.is_animation(ci):
			continue
		var nm := models.entry_name(ci)
		var p := nm.split("_")[0]
		if p == nm or p == "":
			continue
		if not by_prefix.has(p):
			by_prefix[p] = []
		(by_prefix[p] as Array).append(ci)

	for mesh_name in TARGETS:
		var me := models.index_of(mesh_name)
		if me < 0 or not best.has(me) or int(best[me]) < 0:
			print("%s\tunresolved" % mesh_name)
			continue
		var mesh: Dictionary = {}
		var bip: Dictionary = {}
		for b in models.bones(me):
			var nm: String = (b["name"] as PackedByteArray).get_string_from_utf8()
			if nm == "" or mesh.has(nm):
				continue
			mesh[nm] = true
			if nm.begins_with("Bip01"):
				bip[nm] = true
		var p: String = models.entry_name(int(best[me])).split("_")[0]
		var have: Dictionary = acts.get(me, {})
		# One representative per NEWLY gained action -- the best-covering clip,
		# since that is the one the rule would actually hand over.
		var gained: Dictionary = {}
		for ci in (by_prefix.get(p, []) as Array):
			var a := Sacred.Rigs.action_of(models.entry_name(ci))
			if a == "" or have.has(a):
				continue
			var cn := models.clip_bone_names(ci)
			var m := 0
			var mb := 0
			for j in cn.size():
				if mesh.has(cn[j]):
					m += 1
				if bip.has(cn[j]):
					mb += 1
			if m > int((gained.get(a, [0, 0, -1]) as Array)[0]):
				gained[a] = [m, mb, ci]
		var ks := gained.keys()
		ks.sort()
		if ks.is_empty():
			print("%s\tprefix=%s\tgains nothing" % [mesh_name, p])
			continue
		for a in ks:
			var r: Array = gained[a]
			print("%s\tprefix=%s\t%-9s\t%s\tnames %d/%d mesh bones (%.3f)\tBip01 %d/%d (%.3f)\t%s" % [
				mesh_name, p, a, "OK " if r[0] >= MIN_MATCHED else "THIN",
				r[0], mesh.size(), float(r[0]) / float(mesh.size()),
				r[1], bip.size(), float(r[1]) / maxf(1.0, float(bip.size())),
				models.entry_name(r[2])])
	quit()
