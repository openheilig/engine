extends SkeletonModifier3D
## NO class_name on purpose: a newly added global class is not in Godot's
## script-class cache for a `--path` run until the project is reimported, and
## the first attempt at this file failed to compile its consumer with
## `Identifier "RigPlacement" not declared in the current scope` -- which
## silently cascaded into a capture that never settled. player_view.gd
## preloads this by PATH instead, the same way the check scripts extend
## "res://checks/check.gd".
## Re-applies a rig's world placement AFTER the AnimationMixer has written its
## bone poses for the frame.
##
## WHY THIS EXISTS (autoresearch row 758). PlayerView places a rig by baking
## scale and position into the skeleton's parentless bones, because
## SectorView's depth sort reads each MeshInstance3D's GLOBAL POSITION as its
## sort-key baseline -- so the node itself has to stay at identity and the
## placement has nowhere else to go. That was fine while the world only ever
## posed STATIC skeletons: the player has never had a clip (row 610 parked that
## wiring). The moment --creatures started animating one, the AnimationMixer
## and the placement began writing the same bones in the same frame and the
## meshes came out splayed and stretched -- measured as a controlled pair, same
## rigs and cells, animation the only variable.
##
## A SkeletonModifier3D is Godot's sanctioned hook for exactly this ordering:
## the skeleton runs its modifiers after the mixer has finished, so the last
## write of the frame is this one. Nothing here fights the animation for the
## rest of the skeleton -- only the parentless bones are touched, which are the
## ones that carry placement and which build_animation does not bind a track to
## anyway.
##
## ponytail: placement only. This does not know about cells, sorting or the
## camera; PlayerView computes where the rig goes and this makes it stick.

## The rig's parentless bones and their untouched rest origins, captured once
## by the owner before any pose is written. Kept as plain arrays rather than
## re-derived per frame: the skeleton does not change shape at runtime.
var root_bones: PackedInt32Array = PackedInt32Array()
var root_rest_origins: Array[Vector3] = []
## The same bones' untouched rest ROTATIONS. Needed because yaw is applied on
## top of the rest, not instead of it: a parentless bone carries the rig's whole
## coordinate convention in its rest, and replacing it would re-introduce the
## exact class of error row 792 traced.
var root_rest_rotations: Array[Quaternion] = []
## Uniform scale the owner sized the rig to, and the placement offset already
## expressed in the rig's own local space.
var rig_scale := 1.0
var local_offset := Vector3.ZERO
## Rotation about the rig's own vertical, in radians.
##
## WHY IT LIVES HERE (row 793). SectorView depth-sorts on each MeshInstance3D's
## GLOBAL POSITION, so the node has to stay at identity and facing cannot go on
## the node's transform any more than placement could (row 758). Applied to the
## parentless bones it rotates mesh and skeleton TOGETHER -- which is the
## property row 792 established a coordinate change must have, and precisely
## what neutralising a mid-chain bone failed to provide.
##
## These rigs are Z-up (a humanoid's rest bbox is ~107 on Z against ~10-19
## horizontally), so the vertical is Vector3.BACK.
var yaw := 0.0


## Runs inside the skeleton's modification phase, i.e. after the mixer. Godot
## calls this only when `active` is true and the node has a Skeleton3D parent.
func _process_modification() -> void:
	# get_skeleton() is only bound while the skeleton is actually running its
	# modification phase, so it is null outside a rendered frame. The parent IS
	# the Skeleton3D by construction (PlayerView adds this as its child), and
	# falling back to it is what lets a check drive this directly and read the
	# bones back -- which is the only way to assert that a yaw REACHES the
	# skeleton rather than merely being stored.
	var skel := get_skeleton()
	if skel == null:
		skel = get_parent() as Skeleton3D
	if skel == null:
		return
	for k in root_bones.size():
		var i: int = root_bones[k]
		if i < 0 or i >= skel.get_bone_count():
			continue
		skel.set_bone_pose_scale(i, Vector3.ONE * rig_scale)
		if is_zero_approx(yaw):
			# Untouched path for every caller that never sets a yaw, so a rig
			# that renders correctly today takes exactly the code it took before
			# facing existed.
			skel.set_bone_pose_position(i, root_rest_origins[k] * rig_scale + local_offset)
			continue
		var spin := Quaternion(Vector3.BACK, yaw)
		if k < root_rest_rotations.size():
			skel.set_bone_pose_rotation(i, spin * root_rest_rotations[k])
		# The rig spins about its own origin, so the rest offset turns with it;
		# local_offset is world placement and must NOT.
		skel.set_bone_pose_position(i, spin * (root_rest_origins[k] * rig_scale) + local_offset)
