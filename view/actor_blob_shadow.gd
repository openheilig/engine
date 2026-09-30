extends MeshInstance3D
## cGranny's SHADOWDOT path: LGP 0x080FE8DA, Win 2.28 0x00407960.
## These are five ground quads, not a projection of the character mesh.
## Coordinates below stay in retail Z-up space until the shader applies the
## caller's retail-to-port transform. The body's calibrated basis/scale is not
## a retail camera matrix and must not determine the footprint.

const SHADER := preload("res://shaders/hero_shadow.gdshader")
const BONE_NAMES := [&"__Root", &"Bip01 L Foot", &"Bip01 R Foot"]
const ROOT_SIZE_FACTOR := 0.6000000238418579
const NEXT_SIZE_FACTOR := 0.6666666865348816

## The actual draw packet, in native submission order, retained for migration
## to an encoded-color actor/object compositor. No baked retail assets.
var centers := PackedVector3Array([Vector3.ZERO, Vector3.ZERO, Vector3.ZERO,
	Vector3.ZERO, Vector3.ZERO])
var half_sizes := PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0])
var shadow_texture: Texture2D
var retail_to_port := Basis.IDENTITY
var world_origin := Vector3.ZERO
var root_present := false

var _skeleton: Skeleton3D
var _bones := PackedInt32Array()
var _material: ShaderMaterial
var native_actor_basis := Basis.IDENTITY
var _placement: SkeletonModifier3D
var _posed_to_retail := Basis.IDENTITY
var _ground_height: float
var _placed := false


func configure(skeleton: Skeleton3D, texture: Texture2D, radius: float,
		placement: SkeletonModifier3D, actor_basis: Basis, projection_basis: Basis) -> void:
	_skeleton = skeleton
	shadow_texture = texture
	_placement = placement
	native_actor_basis = actor_basis
	retail_to_port = projection_basis
	for bone_name in BONE_NAMES:
		_bones.append(_skeleton.find_bone(bone_name))
	root_present = _bones[0] >= 0
	# Each multiplication lands in float32, as in the native vertex buffer.
	half_sizes[0] = radius * ROOT_SIZE_FACTOR
	half_sizes[1] = half_sizes[0] * NEXT_SIZE_FACTOR
	half_sizes[2] = half_sizes[1]
	half_sizes[3] = half_sizes[1] * NEXT_SIZE_FACTOR
	half_sizes[4] = half_sizes[3]
	_material = ShaderMaterial.new()
	_material.shader = SHADER
	_material.set_shader_parameter("shadow_texture", shadow_texture)
	_material.set_shader_parameter("half_sizes", half_sizes)
	_material.set_shader_parameter("retail_to_port", retail_to_port)
	_material.set_shader_parameter("root_present", root_present)
	material_override = _material
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	sorting_use_aabb_center = false
	top_level = true
	transform = Transform3D.IDENTITY
	visible = false
	var quads := ArrayMesh.new()
	for draw in 5:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
			Vector3(-1, -1, 0), Vector3(-1, 1, 0),
			Vector3(1, -1, 0), Vector3(1, 1, 0)])
		arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
			Vector2(0, 1), Vector2(0, 0), Vector2(1, 1), Vector2(1, 0)])
		# Internal draw index only; native diffuse is constant 0x50000000.
		arrays[Mesh.ARRAY_TEX_UV2] = PackedVector2Array([
			Vector2(draw, 0), Vector2(draw, 0), Vector2(draw, 0), Vector2(draw, 0)])
		quads.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLE_STRIP, arrays)
	mesh = quads
	# Unlike pose_updated, skeleton_updated includes every placement modifier.
	_skeleton.skeleton_updated.connect(refresh_pose)


func update_ground(origin: Vector3, height: float) -> void:
	world_origin = origin
	_ground_height = height
	sorting_offset = origin.z
	_material.set_shader_parameter("world_origin", world_origin)
	_placed = true


func _bone_position(bone: int) -> Vector3:
	# Undo the port-only placement/scale/yaw, then apply the actual native
	# actor orientation and model-header scale. Animation remains unchanged.
	var origin: Vector3
	if _skeleton.has_meta(&"affine_global_poses"):
		origin = (_skeleton.get_meta(&"affine_global_poses")[bone] as Transform3D).origin
	else:
		origin = _skeleton.get_bone_global_pose(bone).origin
	return _posed_to_retail * (origin - _placement.local_offset)


func refresh_pose() -> void:
	if not _placed:
		return
	_posed_to_retail = native_actor_basis * Basis(Quaternion(Vector3.BACK,
		-_placement.yaw)).scaled(Vector3.ONE / _placement.rig_scale)
	var root := Vector3.ZERO
	if root_present:
		root = _bone_position(_bones[0])
		root.z = _ground_height
	# Native initializes absent-foot deltas to zero, not a substitute bone.
	var left := root
	var right := root
	if _bones[1] >= 0:
		left = _bone_position(_bones[1])
		left.z = root.z
	if _bones[2] >= 0:
		right = _bone_position(_bones[2])
		right.z = root.z
	centers[0] = root
	centers[1] = root + (left - root) * 0.5
	centers[2] = root + (right - root) * 0.5
	centers[3] = left
	centers[4] = right
	_material.set_shader_parameter("centers", centers)
	# Shader placement must have a corresponding CPU culling bound.
	var bounds := AABB(world_origin + retail_to_port * centers[0], Vector3.ZERO)
	for draw in 5:
		for corner in 4:
			var x := -half_sizes[draw] if corner < 2 else half_sizes[draw]
			var y := -half_sizes[draw] if corner % 2 == 0 else half_sizes[draw]
			bounds = bounds.expand(world_origin + retail_to_port *
				(centers[draw] + Vector3(x, y, 0)))
	custom_aabb = bounds
	visible = OS.get_environment("SHADOW_HIDE") == ""
