extends "res://check.gd"
## rig_check.gd -- the ONE runnable check for the finding that unblocked GRN
## animation: a kind=65 clip's skeleton and its kind=64 mesh's skeleton ARE the
## same rig, and the earlier REFUTED verdicts measured the wrong quantity.
##
##   godot --headless --path godot-port --script rig_check.gd
##
## WHAT THIS PROTECTS. Rows 605/606/609 compared COMPOSED WORLD bind transforms
## and refuted agreement three times. That measurement is not wrong, it is the
## wrong quantity: composing each file's own chain accumulates every per-bone
## difference and bakes in a root chain the two files genuinely do not share
## (model 589 carries a 90-degree-Z alignment bone between __Root and Bip01
## that the clip has no node for at all). Compared LOCALLY, bone by bone, the
## same two files agree.
##
## The consequence for any future edit: bind a clip to a mesh BY NAME onto the
## MODEL's hierarchy and apply the clip's keys as LOCAL transforms. Never
## compose the clip's own chain, and never treat the clip's rest as a bind
## pose. If someone "fixes" the binder to compose clip world transforms, the
## local numbers below stop separating and this check fails.
##
## Every number here is a measurement, not a target. The control is a clip for
## a DIFFERENT character against the SAME model, so a reader that degrades into
## matching anything cannot pass: the control must keep disagreeing.
const MODEL := "GLADIATOR.GRN"
const CLIP := "GLAD_ATTACK_1H_A.GRN"
const CONTROL := "BATX_ATTACK_BH_A.GRN"
const WITHIN := 0.01
## Measured, and independently equal to the pre-stated expectation row 609
## recorded and could not reproduce with a world-space comparison.
const WANT_LOCAL_WITHIN := 47
const WANT_MATCHED := 60
const WANT_LOCAL_MAX := 6.737522
const WANT_CTRL_LOCAL_WITHIN := 1
const WANT_CTRL_MATCHED := 26


func _init() -> void:
	super()
	var install := Sacred.find_install()
	assert(install != "", "no retail install found; pass --install=/path/to/install")
	var pak := Sacred.Pak.new(install.path_join("pak/models.pak"))
	assert(pak.is_open(), "cannot open pak/models.pak under %s" % install)
	var models := Sacred.Models.new(pak)

	var midx := models.index_of(MODEL)
	assert(midx >= 0, "no model entry named %s" % MODEL)
	var clip := _measure(models, midx, CLIP)
	var ctrl := _measure(models, midx, CONTROL)

	assert(clip["matched"] == WANT_MATCHED,
		"name-matched bones moved: want %d, got %d" % [WANT_MATCHED, clip["matched"]])
	assert(ctrl["matched"] == WANT_CTRL_MATCHED,
		"control name-matched bones moved: want %d, got %d" % [WANT_CTRL_MATCHED, ctrl["matched"]])

	# 1. TOPOLOGY. The parent of every name-matched bone is the same NAMED bone
	#    on both sides -- this is what "same rig" actually means, and it is a
	#    string comparison, immune to any transform convention.
	var topo := float(clip["topo_ok"]) / float(clip["matched"])
	var ctrl_topo := float(ctrl["topo_ok"]) / float(ctrl["matched"])
	assert(topo >= 0.9, "clip topology agreement fell to %.4f" % topo)
	assert(topo > ctrl_topo, "topology no longer separates: clip %.4f vs control %.4f" % [topo, ctrl_topo])

	# 2. LOCAL REST. The load-bearing separation, and the one that fails first
	#    if a future edit composes the clip's chain instead of reading locals.
	assert(clip["local_within"] == WANT_LOCAL_WITHIN,
		"local-rest agreement moved: want %d of %d, got %d"
			% [WANT_LOCAL_WITHIN, WANT_MATCHED, clip["local_within"]])
	assert(absf(clip["local_max"] - WANT_LOCAL_MAX) < 0.0001,
		"local-rest max error moved: want %f, got %f" % [WANT_LOCAL_MAX, clip["local_max"]])
	assert(ctrl["local_within"] == WANT_CTRL_LOCAL_WITHIN,
		"control local-rest agreement moved: want %d, got %d"
			% [WANT_CTRL_LOCAL_WITHIN, ctrl["local_within"]])
	# The separation itself, as a ratio, so a drift that keeps both counts
	# plausible but collapses the gap still fails.
	var clip_frac := float(clip["local_within"]) / float(clip["matched"])
	var ctrl_frac := float(ctrl["local_within"]) / float(ctrl["matched"])
	assert(clip_frac > 10.0 * ctrl_frac,
		"local-rest separation collapsed: clip %.4f vs control %.4f" % [clip_frac, ctrl_frac])

	print("rig_check: %s vs %s -- topology %d/%d (control %d/%d), local rest %d/%d within %.2f (control %d/%d), local max %.6f (control %.6f)"
		% [CLIP, MODEL, clip["topo_ok"], clip["matched"], ctrl["topo_ok"], ctrl["matched"],
			clip["local_within"], clip["matched"], WITHIN, ctrl["local_within"], ctrl["matched"],
			clip["local_max"], ctrl["local_max"]])
	finish(0)


## Compares one clip's bones against one model's, matched by exact NAME, using
## each side's own LOCAL rest transform only -- no chain composition on either
## side, which is the whole point of the check.
func _measure(models: Sacred.Models, midx: int, clip_name: String) -> Dictionary:
	var cidx := models.clip_index_of(clip_name)
	assert(cidx >= 0, "no motion entry named %s" % clip_name)
	var mb := models.bones(midx)
	var cb := models.clip_bones(cidx)
	var cn := models.clip_bone_names(cidx)
	assert(not mb.is_empty() and not cb.is_empty(), "undecodable bones for %s" % clip_name)

	var parent_of := {}
	var local_of := {}
	for i in mb.size():
		var nm: String = (mb[i]["name"] as PackedByteArray).get_string_from_utf8()
		if nm == "" or parent_of.has(nm):
			continue
		var pe: int = mb[i]["parent_effective"]
		parent_of[nm] = ((mb[pe]["name"] as PackedByteArray).get_string_from_utf8()
			if pe >= 0 and pe < mb.size() else "")
		local_of[nm] = mb[i]["rest"]

	var matched := 0
	var topo_ok := 0
	var local_within := 0
	var local_max := 0.0
	for i in cn.size():
		var nm: String = cn[i]
		if nm == "" or not parent_of.has(nm):
			continue
		matched += 1
		var pe: int = cb[i]["parent_effective"]
		var pn := cn[pe] if pe >= 0 and pe < cn.size() else ""
		if pn == parent_of[nm]:
			topo_ok += 1
		var d: float = (cb[i]["rest"] as Transform3D).origin.distance_to(
			(local_of[nm] as Transform3D).origin)
		local_max = maxf(local_max, d)
		if d <= WITHIN:
			local_within += 1
	return {"matched": matched, "topo_ok": topo_ok,
		"local_within": local_within, "local_max": local_max}
