extends SceneTree
## Why does a body resolve NO clip for an action it plainly has one for?
##
##   godot --headless --path . --script res://probes/action_gap_probe.gd
##
## checks/hero_anim_check.gd found SERAPHIM.GRN resolving only ATTACK, DYING,
## FIDLE, IDLE and SPECIAL, while `SERA_WALK_1H.GRN` and `SERA_RUN_1H.GRN` sit
## in models.pak under exactly the naming the action vocabulary reads. Rigs
## drops a clip below MIN_SCORE, so the missing actions are either a NEAR MISS
## (the threshold is wrong for this body) or a genuinely different rig (the
## threshold is right and the clip belongs to someone else).
##
## This prints the best score per action WITHOUT the threshold, so the two
## regimes are distinguishable instead of both reading as "absent".
const MIN_MATCHED := 20
const WITHIN := 0.01

func _init() -> void:
	var install := Sacred.find_install()
	var pak := Sacred.Pak.new(install.path_join("pak/models.pak"))
	var models := Sacred.Models.new(pak)
	for mesh_name in ["SERAPHIM.GRN", "GLADIATOR.GRN"]:
		var me := models.index_of(mesh_name)
		if me < 0:
			print("%s\tnot in pak" % mesh_name)
			continue
		var d: Dictionary = {}
		for b in models.bones(me):
			var nm: String = (b["name"] as PackedByteArray).get_string_from_utf8()
			if nm != "" and not d.has(nm):
				d[nm] = (b["rest"] as Transform3D).origin
		# action -> [best score, best clip, best matched, best clip bones]
		var best: Dictionary = {}
		for ci in models.count():
			if models.kind_of(ci) != Sacred.Models.KIND_MOTION or not models.is_animation(ci):
				continue
			var cn := models.clip_bone_names(ci)
			if cn.size() < MIN_MATCHED:
				continue
			var cb := models.clip_bones(ci)
			if cb.size() != cn.size():
				continue
			var act := Sacred.Rigs.action_of(models.entry_name(ci))
			if act == "":
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
			var f := float(within) / float(matched)
			if f > float((best.get(act, [-1.0]) as Array)[0]):
				best[act] = [f, ci, matched, cn.size()]
		var acts := best.keys()
		acts.sort()
		for a in acts:
			var r: Array = best[a]
			print("%s\t%s\tbest=%.3f\tclip=%s\tmatched=%d/%d\tmeshbones=%d" % [
				mesh_name, a, r[0], models.entry_name(r[1]), r[2], r[3], d.size()])
	quit()
