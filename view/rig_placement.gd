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
## The real body. A PUBLIC method rather than the engine virtual, so a headless
## check can drive the production path instead of a parallel one -- see
## PlayerView.pose_now.
func apply(skel: Skeleton3D) -> void:
	if skel == null:
		return
	# THE ARRAYS MUST AGREE. A short root_rest_rotations used to skip the
	# rotation while still applying the ROTATED position, which leaves skeleton
	# and vertices disagreeing -- the exact splay class row 758 traced, turned
	# from a loud index error into a quiet wrong picture. Refuse instead.
	assert(root_rest_rotations.size() == root_bones.size()
		and root_rest_origins.size() == root_bones.size(),
		"RigPlacement: %d bones but %d origins and %d rotations" % [
			root_bones.size(), root_rest_origins.size(), root_rest_rotations.size()])
	if root_rest_rotations.size() != root_bones.size():
		return
	# Loop-invariant, so it is built once rather than per root bone.
	var spin := Quaternion(Vector3.BACK, yaw)
	var scaled := Vector3.ONE * rig_scale
	for k in root_bones.size():
		var i: int = root_bones[k]
		if i < 0 or i >= skel.get_bone_count():
			continue
		skel.set_bone_pose_scale(i, scaled)
		# THE ROTATION IS ALWAYS WRITTEN, including when yaw is zero. There used
		# to be a fast path here that wrote only the position on a zero yaw, on
		# the reasoning that a caller which never sets a yaw should take exactly
		# the code it took before facing existed. That guard tests the VALUE and
		# not the HISTORY: nothing else writes these bones -- build_animation
		# binds no track to them -- so once a rig had turned, any later frame
		# whose yaw fell inside is_zero_approx left the PREVIOUS spin on the
		# bone. set_yaw(0.0) is public and silently did nothing.
		skel.set_bone_pose_rotation(i, spin * root_rest_rotations[k])
		# The rig spins about its own origin, so the rest offset turns with it;
		# local_offset is world placement and must NOT.
		skel.set_bone_pose_position(i, spin * (root_rest_origins[k] * rig_scale) + local_offset)


## Runs inside the skeleton's modification phase, i.e. after the mixer.
##
## `_process_modification_with_delta` and NOT `_process_modification`: the
## latter is deprecated in Godot 4.7 and still routed for compatibility, so the
## day that shim goes the rig silently stops being placed.
func _process_modification_with_delta(_delta: float) -> void:
	apply(get_skeleton())
