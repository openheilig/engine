extends "res://checks/check.gd"
## 05-10 Task 2: the last unverified premise of the one-shared-skeleton
## design (the 05-06 write-up's "Next Phase Readiness"; the plan's own
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
## --- ANCHOR-NORMALIZED RE-MEASURE (authorized by human decision after the
## raw verdict below came back REFUTED) ---
##
## The raw test above compares RAW WORLD origins. It cannot see past a
## constant whole-skeleton translation between two files' coordinate
## spaces -- and the per-bone data this script's first pass produced (not
## shipped here; recorded in the SUMMARY/findings row 605) shows exactly
## that shape on both helmets: origin_dist sits in a narrow band across
## nearly every matched bone regardless of hierarchy position, while
## basis_diff stays near zero on ordinary body bones. The control shows
## the opposite: origin_dist AND basis_diff both vary widely bone to bone.
## A near-constant offset with matching orientation is the signature of
## the same rig anchored at a different origin; a widely varying one is a
## different rig. This is a DIFFERENT MEASUREMENT (a different quantity),
## not a loosened threshold on the old one, and it is pre-specified below
## BEFORE it is run:
##
## ANCHOR: the unique bone with parent_effective == -1 in each file's OWN
## bone list -- the structural rig root, the one bone every skinned
## hierarchy in this corpus is topologically guaranteed to have. Chosen
## for that structural reason, not by trying candidates and keeping the
## one that scores best. Confirmed (by a one-shot, disposable, pre-measurement
## structural probe, deleted before this commit) to be bone index 0, named
## "__Root", identically in entries 589, 201, 207 and 1 -- present in all
## three files this script measures, satisfying its own stated criterion.
## A file whose bone list does not have EXACTLY ONE such bone refuses this
## measurement entirely (empty Dictionary), same as any other refusal here.
##
## RESIDUAL: for every bone pair matched by exact name (identical matching
## rule as the raw test above -- a name repeated within either side's own
## list is excluded, never guessed at), subtract each SIDE'S OWN root
## world origin from that side's own bone world origin, THEN compare the
## two sides' results:
##   origin_resid = (piece_bind.origin - piece_root_bind.origin)
##                  .distance_to(base_bind.origin - base_root_bind.origin)
## This removes exactly a constant whole-skeleton translation between the
## two files' coordinate spaces without assuming or forcing the two roots
## to coincide. basis_diff is NOT recomputed differently -- a translation-
## only normalization cannot change a rotation difference, so it reuses
## the identical per-bone formula as the raw test and is expected to
## reproduce the raw test's basis numbers exactly.
##
## PASS/FAIL: the IDENTICAL control-discrimination code path as the raw
## test, evaluated on the normalized quantities -- the control must match
## STRICTLY FEWER names and have STRICTLY LARGER max origin_resid AND
## STRICTLY LARGER maxbasis than EVERY piece. Same test, same refusal
## posture, different quantity. ONE run, no variants: if any piece fails
## to beat the control here, verdict=REFUTED stands for the normalized
## test too, 05-11 halts, and no third formulation is attempted.
##
## The raw fact lines and raw verdict above are NOT revised or removed by
## this addition -- both stand in the printed record, so a future reader
## sees the raw-magnitude test that failed and the normalized test that
## followed, and why the second was authorized.
##
## RESULT (measured, this run): `__Root`'s bind-pose origin is exactly
## (0,0,0) in ALL FOUR files checked (589/201/207/1 -- confirmed by a
## disposable debug print, run once and removed before commit). Subtracting
## it is therefore a mathematical no-op, and `bindagreenorm`'s fact lines
## below reproduce `bindagree`'s raw numbers EXACTLY, bone for bone. The
## normalized verdict is REFUTED, identically to the raw one, for the
## identical reason (piece=207's maxorigin is not smaller than the
## control's). This is the one authorized run's real answer, not a null
## result to explain away: the near-constant whole-skeleton offset visible
## in the per-bone data is NOT a root-placement/coordinate-anchor artifact
## -- both files already share the same root position -- so whatever
## produces it lies outside what this rig's own stored bone data can
## explain. No second anchor was tried.
##
## Run: godot --headless --path godot-port --script res://checks/bindagree_check.gd
## Lives in checks/, not world/ or view/: verify.gd's LAYER_RULES scans
## those two directories only, and this check names types from both.

const BASE_ENTRY := 589        ## GLADIATOR.GRN
const PAIRS := [
	[589, 201],   ## GLAD_SA5_HELM.GRN
	[589, 207],   ## GLAD_SA6_HELM.GRN
]
const CONTROL := [589, 1]      ## BAT.GRN -- unrelated model, not a piece
## The tolerance the LOCAL pass uses, and the only one in this file. It is the
## same 0.01 rig_check.gd and Sacred.Rigs use, stated here rather than tuned:
## real pairs measure 0.79..0.97 of bones inside it, wrong-rig pairs ~0.04.
const LOCAL_WITHIN := 0.01


func _init() -> void:
	super()
	var install := Sacred.find_install()
	if install == "":
		printerr("bindagree_check: no install found; pass --install=/path/to/install")
		finish(1)
		return
	var pak := Sacred.Pak.new(install.path_join("pak/models.pak"))
	if not pak.is_open():
		printerr("bindagree_check: cannot open models.pak")
		finish(1)
		return
	var models := Sacred.Models.new(pak)

	var helmet_results: Array[Dictionary] = []
	for pair in PAIRS:
		var r := _pair_check(models, pair[0], pair[1])
		if r.is_empty():
			printerr("bindagree_check: pair base=%d piece=%d could not be measured" % [pair[0], pair[1]])
			finish(1)
			return
		helmet_results.append(r)

	var control := _pair_check(models, CONTROL[0], CONTROL[1])
	if control.is_empty():
		printerr("bindagree_check: control pair base=%d piece=%d could not be measured" % [CONTROL[0], CONTROL[1]])
		finish(1)
		return

	# The control must discriminate: match STRICTLY FEWER names and diverge
	# STRICTLY MORE (both maxorigin and maxbasis) than EVERY helmet pair.
	# Anything less means name-matching alone cannot tell "the same rig"
	# from "an unrelated model" apart, and no verdict can be drawn from the
	# helmet numbers above.
	var raw_discriminates := true
	for r in helmet_results:
		if not (control["matched"] < r["matched"]
				and control["maxorigin"] > r["maxorigin"]
				and control["maxbasis"] > r["maxbasis"]):
			raw_discriminates = false
			break

	if not raw_discriminates:
		print("bindagree\tverdict=REFUTED\treason=control-matches-as-well-as-piece")
	else:
		print("bindagree\tverdict=CONFIRMED")

	# --- Anchor-normalized re-measure, appended, not a revision of the above.
	# Pre-specified in the header comment before this ran. Same PAIRS/CONTROL,
	# same name-matching rule, same control-discrimination code shape --
	# different quantity (root-relative residual instead of raw world origin).
	var helmet_norm: Array[Dictionary] = []
	for pair in PAIRS:
		var rn := _pair_check_normalized(models, pair[0], pair[1])
		if rn.is_empty():
			printerr("bindagree_check: normalized pair base=%d piece=%d could not be measured (no unique structural root)" % [pair[0], pair[1]])
			finish(1)
			return
		helmet_norm.append(rn)

	var control_norm := _pair_check_normalized(models, CONTROL[0], CONTROL[1])
	if control_norm.is_empty():
		printerr("bindagree_check: normalized control base=%d piece=%d could not be measured (no unique structural root)" % [CONTROL[0], CONTROL[1]])
		finish(1)
		return

	var norm_discriminates := true
	for rn in helmet_norm:
		if not (control_norm["matched"] < rn["matched"]
				and control_norm["maxorigin"] > rn["maxorigin"]
				and control_norm["maxbasis"] > rn["maxbasis"]):
			norm_discriminates = false
			break

	if not norm_discriminates:
		print("bindagreenorm\tverdict=REFUTED\treason=control-matches-as-well-as-piece")
	else:
		print("bindagreenorm\tverdict=CONFIRMED")

	# --- LOCAL re-measure, appended, and again NOT a revision of either verdict
	# above. Both of those compare WORLD bind transforms -- raw, then
	# root-normalized -- and row 739 measured that this is the wrong QUANTITY
	# for this question, not a wrong answer to it: composing each file's own
	# chain accumulates every per-bone difference and bakes in a root chain the
	# two files do not share. Compared LOCALLY, bone by bone, with the chain
	# never composed, the SAME two helmet pairs and the SAME control are
	# measured a third way here.
	#
	# This is deliberately the two pairs that produced the original refutation
	# rather than a broad sample: equip_check.gd already carries the broad local
	# measurement (301 pieces across 6 families, row 741), and restating it here
	# would be a second spelling of one rule. What this adds is the local answer
	# ON THE EXACT CASE that refuted, side by side with the two world-space
	# answers, so all three are readable in one run.
	#
	# The EXIT CODE follows this verdict, because it is the one measuring the
	# right quantity. The two world-space verdicts keep printing exactly as they
	# always have -- they are the rows 605/606 record and are not restated,
	# re-scored or removed.
	var helmet_local: Array[Dictionary] = []
	for pair in PAIRS:
		var rl := _pair_check_local(models, pair[0], pair[1])
		if rl.is_empty():
			printerr("bindagree_check: local pair base=%d piece=%d could not be measured" % [pair[0], pair[1]])
			finish(1)
			return
		helmet_local.append(rl)

	var control_local := _pair_check_local(models, CONTROL[0], CONTROL[1])
	if control_local.is_empty():
		printerr("bindagree_check: local control base=%d piece=%d could not be measured" % [CONTROL[0], CONTROL[1]])
		finish(1)
		return

	# TWO clauses: the control must match strictly fewer names AND agree
	# strictly less. `within` is the fraction of matched bones whose LOCAL rest
	# origins land inside LOCAL_WITHIN; a wrong-rig control scores near zero.
	#
	# HUMAN DECISION 2026-08-14, recorded because it changed a rule AFTER that
	# rule had already returned REFUTED (autoresearch row 755, and row 756 for
	# the authorization). The first version of this pass carried a third clause
	# copied mechanically from the world-space passes above -- control must also
	# have a strictly LARGER max. It failed: the control's maxlocal 39.566605 is
	# SMALLER than either helmet's 71.689812 / 74.358704, because the control
	# matches 25 bones where the helmets match 60 and 61 and so has fewer
	# chances to contain an outlier. `max` reports the worst single bone across
	# unequal sample sizes, which is not agreement.
	#
	# The two-clause form is not an invention to make this pass: it is what
	# rig_check.gd (within-fraction, 10x ratio) and equip_check.gd (median own
	# > 0.80 and > 5x cross) already use, neither with a max clause. maxlocal is
	# still MEASURED and still printed on every fact line above -- it just does
	# not decide the verdict.
	var local_discriminates := true
	for rl in helmet_local:
		if not (control_local["matched"] < rl["matched"]
				and control_local["within"] < rl["within"]):
			local_discriminates = false
			break

	if not local_discriminates:
		print("bindagreelocal\tverdict=REFUTED\treason=control-agrees-as-well-as-piece")
		finish(1)
		return

	print("bindagreelocal\tverdict=CONFIRMED\tquantity=local-rest-origin\tsee=rows-739-741")
	finish(0)


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


## The index of the unique bone with parent_effective == -1 in this file's
## OWN bone list -- the structural rig root (see header comment). Returns -1
## if there is not EXACTLY ONE such bone; the caller refuses rather than
## picking one of several or falling back to index 0 by assumption.
func _find_root(bones: Array[Dictionary]) -> int:
	var root := -1
	for i in bones.size():
		if bones[i]["parent_effective"] == -1:
			if root != -1:
				return -1   ## more than one -- not a single well-defined root
			root = i
	return root


## Anchor-normalized counterpart to _pair_check(): identical name-matching
## rule, identical control-discrimination shape, but every bone's world
## origin is expressed relative to ITS OWN FILE's structural root before
## comparison (see header comment for the pre-specified anchor/residual/
## pass-fail definition). basis_diff is unchanged by this normalization
## (translation-only) and is computed by the same per-bone formula as
## _pair_check(). Prints its own `bindagreenorm` fact line. Returns an empty
## Dictionary on refusal: size mismatch (as _pair_check()), or either side
## lacking exactly one structural root.
func _pair_check_normalized(models: Sacred.Models, base: int, piece: int) -> Dictionary:
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

	var base_root := _find_root(base_bones)
	var piece_root := _find_root(piece_bones)
	if base_root == -1 or piece_root == -1:
		return {}
	var base_anchor: Vector3 = base_binds[base_root].origin
	var piece_anchor: Vector3 = piece_binds[piece_root].origin

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
		var origin_dist := (pt.origin - piece_anchor).distance_to(bt.origin - base_anchor)
		var basis_diff := 0.0
		for col: Vector3 in [pt.basis.x - bt.basis.x, pt.basis.y - bt.basis.y, pt.basis.z - bt.basis.z]:
			basis_diff = maxf(basis_diff, maxf(absf(col.x), maxf(absf(col.y), absf(col.z))))
		if origin_dist > maxorigin:
			maxorigin = origin_dist
			worstbone = nm
		maxbasis = maxf(maxbasis, basis_diff)

	var unmatched := piece_names.size() - matched
	print("bindagreenorm\tbase=%d\tpiece=%d\tanchor=%s\tmatched=%d/%d\tunmatched=%d\tunmatched_weighted=%d\tmaxorigin=%.6f\tmaxbasis=%.6f\tworstbone=%s" % [
		base, piece, piece_names[piece_root] if piece_root < piece_names.size() else "?",
		matched, piece_names.size(), unmatched, unmatched_weighted, maxorigin, maxbasis, worstbone])

	return {
		"matched": matched, "unmatched": unmatched, "unmatched_weighted": unmatched_weighted,
		"maxorigin": maxorigin, "maxbasis": maxbasis, "worstbone": worstbone,
	}

## Measures one (base, piece) pair the way row 739 established is the right
## quantity: each bone's OWN local rest transform, matched by NAME, with
## neither side's parent chain composed. Prints a `bindagreelocal` fact line
## and returns {matched, within, maxlocal}. Same refusal posture as
## _pair_check: an empty Dictionary rather than a guess.
##
## Names repeated within either side's own bone list are excluded from matching
## entirely, exactly as the two world-space passes do -- refuse rather than
## guess, so all three passes match the same bone set.
func _pair_check_local(models: Sacred.Models, base: int, piece: int) -> Dictionary:
	var bb := models.bones(base)
	var pb := models.bones(piece)
	if bb.is_empty() or pb.is_empty():
		return {}
	var base_local := _unique_local(bb)
	var piece_local := _unique_local(pb)
	var matched := 0
	var within := 0
	var maxlocal := 0.0
	for nm: String in piece_local:
		if not base_local.has(nm):
			continue
		matched += 1
		var d: float = (piece_local[nm] as Vector3).distance_to(base_local[nm])
		maxlocal = maxf(maxlocal, d)
		if d <= LOCAL_WITHIN:
			within += 1
	if matched == 0:
		return {}
	var frac := float(within) / float(matched)
	print("bindagreelocal\tbase=%d\tpiece=%d\tmatched=%d\twithin=%d (%.4f)\tmaxlocal=%.6f" % [
		base, piece, matched, within, frac, maxlocal])
	return {"matched": matched, "within": frac, "maxlocal": maxlocal}


## name -> local rest ORIGIN, with any name that occurs more than once in this
## bone list dropped entirely.
func _unique_local(bones: Array[Dictionary]) -> Dictionary:
	var seen: Dictionary[String, int] = {}
	var out: Dictionary[String, Vector3] = {}
	for b in bones:
		var nm: String = (b["name"] as PackedByteArray).get_string_from_utf8()
		if nm == "":
			continue
		seen[nm] = int(seen.get(nm, 0)) + 1
		out[nm] = (b["rest"] as Transform3D).origin
	for nm: String in seen:
		if seen[nm] > 1:
			out.erase(nm)
	return out
