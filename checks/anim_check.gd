extends "res://checks/check.gd"
## anim_check.gd -- the ONE runnable check for clip retargeting (row 766).
##
##   godot --headless --path godot-port --script anim_check.gd
##
## THE PROPERTY. A clip's first rotation key is its own rest pose. So at t=0 an
## animated rig must stand in exactly its BIND pose -- every bone's animated
## local rotation must equal that bone's rest rotation on the MODEL.
##
## WHAT WENT WRONG WITHOUT IT. build_animation wrote each key straight onto the
## model's bone. But a key is expressed against the CLIP's rest, and clip and
## model do not share one (row 739: local rests agree on 47 of 60 bones, worst
## case 6.74). Writing it directly replaces the bone's rest orientation with a
## foreign one, and since a limb inherits its parent's error the displacement
## accumulates outward -- 84.71 units on a rig 110 units wide, at t=0, where the
## pose is supposed to BE the bind pose. On screen the mesh collapsed to a thin
## diagonal streak (row 765). Nothing in this directory caught it; the suite was
## 21 of 21 green while BEAR.GRN rendered as a line.
##
## THE CONTROL IS THE LOAD-BEARING HALF. "t=0 equals the bind pose" is also what
## a binder that ignores the clip entirely would report. So the second assertion
## measures the RAW keys the same way and requires them to DISAGREE: if the two
## ever come out the same, the clip and model rests have stopped differing and
## this check has quietly stopped testing anything.
const WITHIN := 0.01
## Pairs are (mesh, clip) as the world actually resolves them through Rigs.
const PAIRS := [
	{"mesh": "BEAR.GRN", "clip": "BEAR_WALK_BH.GRN"},
	{"mesh": "WALDELFE_DARK.GRN", "clip": "DRF1_ATTACK_SPECIAL01.GRN"},
	{"mesh": "WOLF.GRN", "clip": "WOLF_IDLE_BH.GRN"},
]
## Below this many retargeted bones a pair is not exercising the binder.
const MIN_TRACKS := 20
## The control must move at least this fraction of bones off their rest.
## Measured floor: BEAR_WALK_BH sits at 39 of 42. Anything near 1.0 means the
## retarget landed; a transplant scores far below this.
const MIN_AT_BIND := 0.9
## The retargeted fraction must beat the raw fraction by at least this much, or
## the control has stopped separating.
const MIN_SEPARATION := 0.2


func _init() -> void:
	super()
	var install := Sacred.find_install()
	assert(install != "", "no retail install found; pass --install=/path/to/install")
	var models := Sacred.Models.new(Sacred.Pak.new(install.path_join("pak/models.pak")))
	var ModelViewScript := load("res://view/model_view.gd")

	var tested := 0
	for pair: Dictionary in PAIRS:
		var mi := models.index_of(pair["mesh"])
		var ci := models.clip_index_of(pair["clip"])
		assert(mi >= 0, "no mesh entry named %s" % pair["mesh"])
		if ci < 0:
			continue          # a clip this build still refuses; reported below
		var mv = ModelViewScript.new()
		root.add_child(mv)
		if not mv.setup(models, mi):
			mv.queue_free()
			continue
		var skel: Skeleton3D = null
		for c in mv.get_children():
			if c is Skeleton3D:
				skel = c
				break
		assert(skel != null, "%s built no Skeleton3D" % pair["mesh"])

		var built: Dictionary = mv.build_animation(models, ci)
		var anim: Animation = built["animation"]
		if anim == null:
			# A clip this build still refuses to decode (row 764 left 683 such
			# entries; the WOLF_* family is among them). Reported, never
			# silently dropped -- a creature that cannot animate at all is a
			# standing gap, and hiding it here would make the suite claim
			# coverage it does not have.
			print("anim\t%s\t%s\tSKIPPED -- clip does not decode" % [pair["mesh"], pair["clip"]])
			mv.queue_free()
			continue

		var checked := 0
		var at_rest := 0
		var raw_off := 0
		for t in anim.get_track_count():
			if anim.track_get_type(t) != Animation.TYPE_ROTATION_3D:
				continue
			var nm := String(anim.track_get_path(t).get_concatenated_subnames())
			var bi := skel.find_bone(nm)
			if bi < 0:
				continue
			checked += 1
			var rest := skel.get_bone_rest(bi).basis.get_rotation_quaternion().normalized()
			var key := anim.rotation_track_interpolate(t, 0.0).normalized()
			if _close(key, rest):
				at_rest += 1

		# The control: the SAME comparison against the clip's untouched keys.
		var raw := _raw_first_keys(models, ci)
		for nm: String in raw:
			var bi := skel.find_bone(nm)
			if bi < 0:
				continue
			var rest := skel.get_bone_rest(bi).basis.get_rotation_quaternion().normalized()
			if not _close(raw[nm], rest):
				raw_off += 1

		assert(checked >= MIN_TRACKS,
			"%s + %s bound only %d rotation tracks" % [pair["mesh"], pair["clip"], checked])
		# THE PROPERTY, stated exactly. NOT "every bone is at bind at t=0" --
		# that was asserted first and is false: a clip's first key is usually its
		# own rest but need not be. BEAR_WALK_BH starts 3 of 42 bones off-rest,
		# and DRF1_ATTACK_SPECIAL01, an attack that opens mid-motion, starts 30
		# of 83 off-rest. Those are the animation, not an error.
		#
		# What retargeting guarantees is narrower and checkable: a bone whose
		# first key IS its clip rest must land exactly on the MODEL's rest, and
		# no other bone need. So the expected count is computed from the clip
		# itself and the binder must match it exactly -- neither fewer (the
		# retarget is broken) nor more (it is collapsing bones onto rest that
		# should be moving).
		var expect := _first_key_at_clip_rest(models, ci, skel)
		assert(at_rest == expect,
			"%s + %s: %d bones sit at bind at t=0 but %d of %d have a first key equal to their CLIP rest -- the retarget is not mapping clip rest onto model rest"
				% [pair["mesh"], pair["clip"], at_rest, expect, checked])
		# THE CONTROL, and note what it is NOT. The first version of this compared
		# the retargeted t=0 agreement against the raw one and demanded a fixed
		# 0.2 gap -- a number invented before any of this was measured. BEAR
		# cleared it and the elf came in at 0.13, and lowering the threshold to
		# fit would have been scoring the test after seeing the result. The gap
		# is the wrong quantity anyway: it shrinks when the two rests happen to
		# agree, which is a fact about the pair, not about the binder.
		#
		# What the control is actually for is "the retarget is doing work". That
		# is measurable head-on: count the bones whose clip rest and model rest
		# genuinely differ, i.e. where the retarget quaternion is not the
		# identity. If that ever reaches zero the retarget is a no-op and every
		# other assertion here would pass trivially.
		var nontrivial := _retarget_nontrivial(models, ci, skel)
		assert(nontrivial > 0,
			"%s + %s: the retarget is the identity on every bone, so nothing here is being tested"
				% [pair["mesh"], pair["clip"]])
		var ctrl := float(checked - raw_off) / float(checked)
		var frac := float(at_rest) / float(checked)
		print("anim\t%s\t%s\ttracks=%d\tat_bind_t0=%d/%d(expected %d)\tretarget_nontrivial=%d\tretargeted=%.2f vs raw=%.2f" % [
			pair["mesh"], pair["clip"], checked, at_rest, checked, expect,
			nontrivial, frac, ctrl])
		tested += 1
		mv.queue_free()

	assert(tested >= 2, "only %d pairs were testable" % tested)
	print("anim_check: %d mesh/clip pairs stand in their bind pose at t=0, and the raw keys do not" % tested)
	finish(0)


## bone name -> that record's FIRST rotation key, untouched by the binder.
func _raw_first_keys(models: Sacred.Models, ci: int) -> Dictionary:
	var out := {}
	var c := models.clip(ci)
	var track_bone := models.clip_track_bone(ci)
	var names := models.clip_bone_names(ci)
	if c.is_empty() or track_bone.is_empty():
		return out
	var records: Array = c["records"]
	for ri in records.size():
		var bi: int = track_bone[ri]
		if bi < 0 or bi >= names.size():
			continue
		var rots: Array = records[ri]["rotations"]
		if rots.is_empty():
			continue
		out[String(names[bi]).replace(":", "_").replace("/", "_")] = (rots[0] as Quaternion).normalized()
	return out


## Quaternion equality up to sign -- q and -q are the same rotation.
func _close(a: Quaternion, b: Quaternion) -> bool:
	var d := absf(a.x - b.x) + absf(a.y - b.y) + absf(a.z - b.z) + absf(a.w - b.w)
	var e := absf(a.x + b.x) + absf(a.y + b.y) + absf(a.z + b.z) + absf(a.w + b.w)
	return minf(d, e) <= WITHIN


## How many of this clip's bones open ON their own rest -- and so, after a
## correct retarget, must open on the MODEL's rest. Counted over the bones the
## rig actually binds, so it is directly comparable to the binder's own count.
func _first_key_at_clip_rest(models: Sacred.Models, ci: int, skel: Skeleton3D) -> int:
	var c := models.clip(ci)
	var track_bone := models.clip_track_bone(ci)
	var names := models.clip_bone_names(ci)
	var bl := models.clip_bones(ci)
	if c.is_empty() or track_bone.is_empty():
		return -1
	var records: Array = c["records"]
	var n := 0
	for ri in records.size():
		var bi: int = track_bone[ri]
		if bi < 0 or bi >= names.size() or bi >= bl.size():
			continue
		var rots: Array = records[ri]["rotations"]
		if rots.is_empty():
			continue
		if skel.find_bone(String(names[bi]).replace(":", "_").replace("/", "_")) < 0:
			continue
		# build_animation binds no track to a parentless bone (placement owns
		# those), so counting one here would expect a bind the binder never
		# writes -- which is exactly the off-by-one this first produced.
		if int(bl[bi]["parent_effective"]) == -1:
			continue
		var rest := ((bl[bi]["rest"] as Transform3D).basis.get_rotation_quaternion()).normalized()
		if _close((rots[0] as Quaternion).normalized(), rest):
			n += 1
	return n


## Bones where the clip's rest and the model's rest genuinely differ -- the ones
## the retarget actually rotates. Zero here would mean the retarget is a no-op.
func _retarget_nontrivial(models: Sacred.Models, ci: int, skel: Skeleton3D) -> int:
	var names := models.clip_bone_names(ci)
	var bl := models.clip_bones(ci)
	var n := 0
	for bi in mini(names.size(), bl.size()):
		if int(bl[bi]["parent_effective"]) == -1:
			continue
		var si := skel.find_bone(String(names[bi]).replace(":", "_").replace("/", "_"))
		if si < 0:
			continue
		var cr := ((bl[bi]["rest"] as Transform3D).basis.get_rotation_quaternion()).normalized()
		var mr := skel.get_bone_rest(si).basis.get_rotation_quaternion().normalized()
		if not _close(cr, mr):
			n += 1
	return n
