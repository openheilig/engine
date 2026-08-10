extends SceneTree
## 05-10 Task 2: the last unverified premise of the one-shared-skeleton
## design (05-06-SUMMARY.md's "Next Phase Readiness"; the plan's own
## second halt). Bone names now resolve (05-10 Task 1's bindname chain),
## so this measures something 05-06 could not reach: does a piece's
## same-named bone sit at the same WORLD BIND TRANSFORM as the base's?
##
## Bones are matched by NAME ONLY -- never by array index (findings row
## 582: bone counts differ per file, 68/75/76-78, and same-count pieces
## diverge from EACH OTHER position-by-position), never by
## parent_effective shape, never by the per-bone record's stored id.
## A name repeated within either side's own bone list is excluded from
## matching entirely (refuse rather than guess), consistent with the
## codebase's established posture (D-19, T-05-53).
##
## THE CONTROL IS WHAT MAKES THIS MEAN ANYTHING (mirrors
## goaltick_check.gd's own fix/control-pair discipline): BAT.GRN (entry 1,
## an unrelated model) matched against the same GLADIATOR.GRN base must
## match far FEWER names and diverge far MORE than either helmet does.
## A control that matches as well as a real piece would mean name-matching
## alone cannot tell "the same rig" from "an unrelated model" apart, and
## every conclusion drawn from the helmet pairs would be unfounded.
##
## Interpretation is NOT a tolerance chosen first and confirmed after:
## small measured divergence on the helmet pairs is evidence FOR one
## shared Skin (05-11's tolerance evidence); large divergence fires this
## plan's own second halt -- a REFUTED verdict here is a real result, not
## a failure to deliver. No epsilon/tolerance constant is added to
## sacred.gd by this script; bones(), bind_poses() and mesh_weights() are
## reused exactly as committed in 05-10 Task 1.
##
## Run: godot --headless --path godot-port --script res://bindagree_check.gd
## Lives at res:// root, like goaltick_check.gd, because verify.gd's
## LAYER_RULES scans only world/ and view/.

const BASE_ENTRY := 589        ## GLADIATOR.GRN
const PAIRS := [
	[589, 201],   ## GLAD_SA5_HELM.GRN
	[589, 207],   ## GLAD_SA6_HELM.GRN
]
const CONTROL := [589, 1]      ## BAT.GRN -- unrelated model, not a piece


func _init() -> void:
	var install := Sacred.find_install()
	if install == "":
		printerr("bindagree_check: no install found; pass --install=/path/to/install")
		quit(1)
		return
	var pak := Sacred.Pak.new(install.path_join("pak/models.pak"))
	if not pak.is_open():
		printerr("bindagree_check: cannot open models.pak")
		quit(1)
		return
	var models := Sacred.Models.new(pak)

	var helmet_results: Array[Dictionary] = []
	for pair in PAIRS:
		var r := _pair_check(models, pair[0], pair[1])
		if r.is_empty():
			printerr("bindagree_check: pair base=%d piece=%d could not be measured" % [pair[0], pair[1]])
			quit(1)
			return
		helmet_results.append(r)

	var control := _pair_check(models, CONTROL[0], CONTROL[1])
	if control.is_empty():
		printerr("bindagree_check: control pair base=%d piece=%d could not be measured" % [CONTROL[0], CONTROL[1]])
		quit(1)
		return

	# The control must discriminate: match STRICTLY FEWER names and diverge
	# STRICTLY MORE (both maxorigin and maxbasis) than EVERY helmet pair.
	# Anything less means name-matching alone cannot tell "the same rig"
	# from "an unrelated model" apart, and no verdict can be drawn from the
	# helmet numbers above.
	var discriminates := true
	for r in helmet_results:
		if not (control["matched"] < r["matched"]
				and control["maxorigin"] > r["maxorigin"]
				and control["maxbasis"] > r["maxbasis"]):
			discriminates = false
			break

	if not discriminates:
		print("bindagree\tverdict=REFUTED\treason=control-matches-as-well-as-piece")
		quit(1)
		return

	quit(0)


## Measures one (base, piece) pair, prints its `bindagree` fact line, and
## returns the measured facts. Returns an empty Dictionary on refusal
## (bones()/bind_poses()/bone_names() disagreed on size for either entry --
## should not happen post-05-10-Task-1, but this script does not assume it).
func _pair_check(models: Sacred.Models, base: int, piece: int) -> Dictionary:
	var base_bones := models.bones(base)
	var piece_bones := models.bones(piece)
	var base_binds := models.bind_poses(base)
	var piece_binds := models.bind_poses(piece)
	var base_names := models.bone_names(base)
	var piece_names := models.bone_names(piece)
	if base_bones.is_empty() or piece_bones.is_empty() \
			or base_binds.size() != base_bones.size() or piece_binds.size() != piece_bones.size() \
			or base_names.size() != base_bones.size() or piece_names.size() != piece_bones.size():
		return {}

	# Name -> index, restricted to names unique within that SIDE's own bone
	# list. A name either side repeats cannot be a join key -- matching
	# against one occurrence of a repeated name would be a guess, not a
	# resolution, so every repeated name is excluded rather than one
	# arbitrarily picked.
	var base_name_counts := {}
	for nm: String in base_names:
		if nm != "":
			base_name_counts[nm] = base_name_counts.get(nm, 0) + 1
	var base_index_by_name := {}
	for i in base_names.size():
		var nm: String = base_names[i]
		if nm != "" and base_name_counts.get(nm, 0) == 1:
			base_index_by_name[nm] = i

	var piece_name_counts := {}
	for nm: String in piece_names:
		if nm != "":
			piece_name_counts[nm] = piece_name_counts.get(nm, 0) + 1

	# Which of the piece's own bones are weighted to, in the piece's own
	# Granny file bone-index space -- resolved through mesh_weights()'s
	# bone_map, never guessed from parent/child shape.
	var weighted := {}
	for mw: Dictionary in models.mesh_weights(piece):
		var bone_map: PackedInt32Array = mw["bone_map"]
		for g in bone_map:
			weighted[g] = true

	var matched := 0
	var maxorigin := 0.0
	var maxbasis := 0.0
	var worstbone := ""
	var unmatched_weighted := 0
	for i in piece_names.size():
		var nm: String = piece_names[i]
		var is_matchable: bool = nm != "" and piece_name_counts.get(nm, 0) == 1 and base_index_by_name.has(nm)
		if not is_matchable:
			if weighted.has(i):
				unmatched_weighted += 1
			continue
		var bi: int = base_index_by_name[nm]
		matched += 1
		var pt: Transform3D = piece_binds[i]
		var bt: Transform3D = base_binds[bi]
		var origin_dist := pt.origin.distance_to(bt.origin)
		var basis_diff := 0.0
		for col: Vector3 in [pt.basis.x - bt.basis.x, pt.basis.y - bt.basis.y, pt.basis.z - bt.basis.z]:
			basis_diff = maxf(basis_diff, maxf(absf(col.x), maxf(absf(col.y), absf(col.z))))
		if origin_dist > maxorigin:
			maxorigin = origin_dist
			worstbone = nm
		maxbasis = maxf(maxbasis, basis_diff)

	var unmatched := piece_names.size() - matched
	print("bindagree\tbase=%d\tpiece=%d\tmatched=%d/%d\tunmatched=%d\tunmatched_weighted=%d\tmaxorigin=%.6f\tmaxbasis=%.6f\tworstbone=%s" % [
		base, piece, matched, piece_names.size(), unmatched, unmatched_weighted, maxorigin, maxbasis, worstbone])

	return {
		"matched": matched, "unmatched": unmatched, "unmatched_weighted": unmatched_weighted,
		"maxorigin": maxorigin, "maxbasis": maxbasis, "worstbone": worstbone,
	}
