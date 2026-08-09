class_name PlayerView
extends RefCounted
## Draws the real posed player-character mesh in the streamed world, sorted
## against the painted object quads by the same rule Phase 2/3 established
## (SectorView.ground_depth / SectorView.SORTCUBE_PX) -- no capsule
## placeholder (04-CONTEXT.md's allowance for one has expired).
##
## RefCounted, following cursor.gd's shape (04-03-PLAN.md Task 1): it lives in
## view/, may hold engine handles, and does not need to be a Node itself. It
## owns exactly one built rig -- a ModelView, which IS a Node3D main.gd
## parents into the tree via the `node` field below. Must not name a
## world-layer type (ActorRegistry/ActorState/RecordStore/Sim.) and defines
## no _process/_physics_process of its own -- driven from main.gd's single
## _process via update(), below.
##
## Placement is baked into the built rig's SKELETON POSE, never into any
## Node3D's own position/scale. This is not a style choice: SectorView's own
## class doc invariant ("Sits at Transform3D.IDENTITY... every sector mesh
## keeps the exact global transform") and _build_sortcube's doc comment both
## establish that everything sorted by ground_depth()/sorting_offset must
## leave its NODE'S global position at identity, because
## sorting_use_aabb_center=false reads that global position as the sort
## key's baseline (confirmed against Godot 4.7's VisualInstance3D docs:
## "sorting is based on the global position" -- an additive baseline
## sorting_offset sits on top of, not a replacement for it). A real Node3D
## translation would (a) double-count the depth signal already carried by
## sorting_offset for an orthogonal camera with no rotation, where only the
## Z component of that global position enters the sort at all, and (b),
## measured directly from SectorView's own terrain build (pz = (x+y) *
## DEPTH_STEP, sector_view.gd:270), leave the character's real rendered Z
## nowhere near the terrain Z (0..~640 world units) it must be depth-tested
## against for correct floor occlusion. Baking the placement into the
## skeleton's root-bone POSE instead moves the rendered vertices (fixing
## both problems) without moving any Node3D's global_transform (leaving the
## sort-key baseline untouched, exactly like every band mesh and the
## sortcube).

## ponytail: the retail Gladiator hero model stands in for "the player" --
## no class-selection system exists yet (a later phase's job). Named here,
## not passed in, so every call site draws the same model until one does.
const MODEL_NAME := "GLADIATOR.GRN"

## The built rig, parented into the tree by the caller (main.gd), or null
## when the model failed to resolve or build -- drawing nothing, matching
## RetailCursor.apply's non-fatal degrade, never a capsule fallback.
var node: Node3D = null
var model_index := -1
var vertex_count := 0
var triangle_count := 0

var _mesh: MeshInstance3D = null
var _skeleton: Skeleton3D = null
var _scale := 1.0
## Root-bone rest origins, captured once so update() only ever adds this
## call's placement on top of the model's own unscaled rest pose -- never on
## top of whatever the previous update() left behind.
var _root_bones: PackedInt32Array = PackedInt32Array()
var _root_rest_origins: Array[Vector3] = []


## Resolves MODEL_NAME through Sacred.Models.index_of (never a hardcoded
## entry number) and builds it via ModelView, framing suppressed -- the
## streamed world already has its own IsoCamera and does not want a second,
## competing Camera3D/DirectionalLight3D. Non-fatal on any failure.
func _init(models: Sacred.Models) -> void:
	model_index = models.index_of(MODEL_NAME)
	if model_index < 0:
		push_warning("PlayerView: %s not found in models.pak -- drawing nothing" % MODEL_NAME)
		return

	var mv := ModelView.new()
	if not mv.setup(models, model_index, false):
		push_warning("PlayerView: %s failed to build -- drawing nothing" % MODEL_NAME)
		mv.free()
		return

	_skeleton = mv.get_node_or_null("Skeleton")
	_mesh = mv.get_node_or_null("Skeleton/Mesh") if _skeleton != null else mv.get_node_or_null("Mesh")
	if _mesh == null or _mesh.mesh == null:
		push_warning("PlayerView: %s built with no Mesh node -- drawing nothing" % MODEL_NAME)
		mv.free()
		return

	vertex_count = mv.vertex_count
	triangle_count = mv.triangle_count

	# Scale so the rig's bounding box height equals SectorView's existing
	# character-proxy constant (SORTCUBE_PX) -- borrowed, not restated, per
	# 04-03-PLAN.md Task 1. ponytail: no retail capture has measured an
	# actual character height yet; the ceiling is "reads at marker-cube
	# scale, not the model's own untouched size", and the upgrade path is a
	# retail capture through the same autopilot.c route that recovered
	# IsoCamera's ZOOM_SCALES.
	var natural_height: float = (mv.transform * _mesh.mesh.get_aabb()).size.y
	if natural_height > 0.0:
		_scale = SectorView.SORTCUBE_PX / natural_height

	# Transparent pass, like the object sprites this is sorted against
	# (_build_sortcube's constraint 2); depth_draw_mode still writes the
	# depth buffer so opaque terrain occludes/is occluded correctly, mirroring
	# the sortcube's own material exactly.
	var mat: StandardMaterial3D = _mesh.material_override
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
	_mesh.sorting_use_aabb_center = false

	if _skeleton != null:
		for i in _skeleton.get_bone_count():
			if _skeleton.get_bone_parent(i) == -1:
				_root_bones.append(i)
				_root_rest_origins.append(_skeleton.get_bone_rest(i).origin)

	node = mv


## Moves the built rig to `cell`, converted through IsoCamera.cell_to_world
## (already static and exact -- never reimplemented) and placed at the ground
## point SectorView.ground_depth() gives that position, the same formula the
## object sprites and the sortcube use. No-op when the model failed to build.
func update(cell: Vector2) -> void:
	if node == null:
		return
	var p := IsoCamera.cell_to_world(cell)
	var ground_z := SectorView.ground_depth(p)
	_mesh.sorting_offset = ground_z

	if _skeleton == null or _root_bones.is_empty():
		return
	# The world-space placement, divided back through the rig's own
	# coordinate-basis transform (model_view.gd's own idiom in _frame(): work
	# out the target in world space, then express it in this node's local
	# space, so the basis rotation does not carry it off-target) -- never
	# through the node's position, per the class doc above.
	var world_offset := Vector3(p.x, p.y, ground_z)
	var local_offset := node.transform.basis.inverse() * world_offset
	for k in _root_bones.size():
		var i: int = _root_bones[k]
		var rest_origin: Vector3 = _root_rest_origins[k]
		_skeleton.set_bone_pose_scale(i, Vector3.ONE * _scale)
		_skeleton.set_bone_pose_position(i, rest_origin * _scale + local_offset)


## Visibility toggle, independent of update()'s placement logic -- a caller
## that wants the rig temporarily hidden without discarding the built mesh
## and losing model_index/vertex_count/triangle_count in the process.
func set_shown(shown: bool) -> void:
	if node != null:
		node.visible = shown
