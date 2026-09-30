extends Node3D
## One model subtree, one private depth/color target, one screen-space rectangle.
## Add beside the model, then capture(). Call sync() at frame_pre_draw, after
## skeleton_updated and BoneAttachment3D have finished, not from _process.
## The returned rectangle is in the source viewport's logical pixel coordinates;
## texture() is its premultiplied-alpha ViewportTexture, never a CPU image.
## Materials are deliberately unchanged: isolation does not override a material
## that explicitly disables depth testing/writes. Layer 20 is reserved for blobs.

const ActorBlobShadow := preload("res://view/actor_blob_shadow.gd")
const SHADOW_LAYER := 1 << 19
const RASTER_MARGIN := 2.0
const IDLE_SIZE := Vector2i(2, 2)


class PoseCache:
	extends RefCounted
	var skeleton: Skeleton3D
	var poses: Array[Transform3D] = []
	var revision := 0

	func _init(node: Skeleton3D) -> void:
		skeleton = node
		skeleton.skeleton_updated.connect(sample)
		skeleton.bone_list_changed.connect(bones_changed)
		sample()

	func bones_changed() -> void:
		revision += 1

	func sample() -> void:
		var count := skeleton.get_bone_count()
		if poses.size() != count:
			poses.resize(count)
		# Godot restores pre-modifier poses AFTER skeleton_updated. Keep exactly
		# the palette used for the skin, including RigPlacement's world offset.
		for bone in count:
			poses[bone] = skeleton.get_bone_global_pose(bone)

	func dispose() -> void:
		if is_instance_valid(skeleton):
			skeleton.skeleton_updated.disconnect(sample)
			skeleton.bone_list_changed.disconnect(bones_changed)


class MeshBounds:
	extends RefCounted
	var node: MeshInstance3D
	var mesh: Mesh
	var skin: Skin
	var pose: PoseCache
	var revision := -1
	var dirty := true
	var valid := false
	var rigid := AABB()
	var has_rigid := false
	var bind_boxes: Array[AABB] = []
	var bind_bones := PackedInt32Array()
	var bind_poses: Array[Transform3D] = []
	var used_binds := PackedInt32Array()
	var sum_min := 1.0
	var sum_max := 1.0
	var current := AABB()
	var has_current := false

	func _init(instance: MeshInstance3D) -> void:
		node = instance

	func invalidate() -> void:
		dirty = true

	func dispose() -> void:
		if mesh != null:
			mesh.changed.disconnect(invalidate)
		if skin != null:
			skin.changed.disconnect(invalidate)
		mesh = null
		skin = null
		pose = null

	func refresh(palette: PoseCache) -> void:
		var reference := node.get_skin_reference()
		var next_skin: Skin = reference.get_skin() if reference != null else null
		if mesh != node.mesh or skin != next_skin or pose != palette:
			dispose()
			mesh = node.mesh
			skin = next_skin
			pose = palette
			if mesh != null:
				mesh.changed.connect(invalidate)
			if skin != null:
				skin.changed.connect(invalidate)
			dirty = true
		if pose != null and revision != pose.revision:
			dirty = true
		if dirty:
			_rebuild()

	func _rebuild() -> void:
		dirty = false
		valid = false
		has_rigid = false
		bind_boxes.clear()
		bind_bones.clear()
		bind_poses.clear()
		used_binds.clear()
		sum_min = 1.0
		sum_max = 1.0
		if mesh == null:
			return
		if pose == null or skin == null or skin.get_bind_count() == 0:
			rigid = mesh.get_aabb()
			has_rigid = rigid.position.is_finite() and rigid.size.is_finite()
			valid = has_rigid
			return
		revision = pose.revision
		var count := skin.get_bind_count()
		bind_boxes.resize(count)
		bind_bones.resize(count)
		bind_poses.resize(count)
		var used := PackedByteArray()
		used.resize(count)
		for bind in count:
			var bone_name := skin.get_bind_name(bind)
			var bone := pose.skeleton.find_bone(bone_name) if not bone_name.is_empty() \
				else skin.get_bind_bone(bind)
			if bone < 0 or bone >= pose.skeleton.get_bone_count():
				push_error("ModelCanvas: invalid skin bind on %s" % node.name)
				return
			bind_bones[bind] = bone
			bind_poses[bind] = skin.get_bind_pose(bind)
		# Extract arrays only when geometry/bind metadata changes. The steady
		# state keeps one vertex-space box per USED bind, never vertex arrays.
		for surface in mesh.get_surface_count():
			var arrays := mesh.surface_get_arrays(surface)
			if arrays.size() != Mesh.ARRAY_MAX:
				return
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			if arrays[Mesh.ARRAY_BONES] == null or arrays[Mesh.ARRAY_WEIGHTS] == null:
				for vertex in vertices:
					if not vertex.is_finite():
						return
					rigid = rigid.expand(vertex) if has_rigid else AABB(vertex, Vector3.ZERO)
					has_rigid = true
				continue
			var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
			var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
			var slots := 8 if mesh.surface_get_format(surface) & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS else 4
			if bones.size() != vertices.size() * slots or weights.size() != bones.size():
				push_error("ModelCanvas: incomplete skin weights on %s" % node.name)
				return
			for vertex_index in vertices.size():
				var vertex := vertices[vertex_index]
				if not vertex.is_finite():
					return
				var weight_sum := 0.0
				for slot in slots:
					var index := vertex_index * slots + slot
					var weight := weights[index]
					if not is_finite(weight) or weight < 0.0:
						return
					if weight == 0.0:
						continue
					var bind := bones[index]
					if bind < 0 or bind >= count:
						return
					weight_sum += weight
					bind_boxes[bind] = bind_boxes[bind].expand(vertex) if used[bind] \
						else AABB(vertex, Vector3.ZERO)
					used[bind] = 1
				sum_min = minf(sum_min, weight_sum)
				sum_max = maxf(sum_max, weight_sum)
		for bind in count:
			if used[bind]:
				used_binds.append(bind)
		valid = true

	func update_bounds() -> bool:
		has_current = false
		if not valid:
			return false
		var transforms: Array[Transform3D] = []
		if pose != null:
			transforms = pose.poses
			if pose.skeleton.has_meta(&"affine_global_poses"):
				transforms = pose.skeleton.get_meta(&"affine_global_poses")
		for bind in used_binds:
			var bone := bind_bones[bind]
			if bone >= transforms.size():
				return false
			# This runtime uploads the complete global pose times the bind pose.
			var transform := transforms[bone] * bind_poses[bind]
			var box: AABB = transform * bind_boxes[bind]
			if not box.position.is_finite() or not box.size.is_finite():
				return false
			current = current.merge(box) if has_current else box
			has_current = true
		if has_current:
			# Positive normalized weights are a convex combination of these boxes.
			# Also cover the actual weight sums after GPU-format quantization;
			# do not silently assume that four/eight stored weights sum to one.
			var low := Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * sum_min), Vector3.ZERO)
			var high := Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * sum_max), Vector3.ZERO)
			current = (low * current).merge(high * current)
		elif pose != null and skin != null and sum_min == 0.0:
			current = AABB(Vector3.ZERO, Vector3.ZERO)
			has_current = true
		if has_rigid:
			current = current.merge(rigid) if has_current else rigid
			has_current = true
		if node.custom_aabb != AABB():
			current = current.merge(node.custom_aabb) if has_current else node.custom_aabb
			has_current = true
		if has_current and node.extra_cull_margin > 0.0:
			current = current.grow(node.extra_cull_margin)
		return has_current and current.position.is_finite() and current.size.is_finite()


var _model: Node3D
var _viewport: SubViewport
var _stage: Node3D
var _camera: Camera3D
var _active := true
var _watched: Dictionary[int, Node] = {}
var _poses: Dictionary[int, PoseCache] = {}
var _meshes: Dictionary[int, MeshBounds] = {}


func capture(model: Node3D) -> void:
	if _model == model:
		return
	assert(_model == null, "ModelCanvas owns exactly one model")
	assert(is_inside_tree() and model.is_inside_tree(), "Add wrapper and model before capture")
	assert(get_parent() == model.get_parent(), "ModelCanvas must be added beside its model")
	if _model != null or not is_inside_tree() or not model.is_inside_tree() \
			or get_parent() != model.get_parent():
		return
	# The viewport breaks Node3D transform inheritance. Recreate the old parent
	# coordinate system INSIDE it rather than baking placement into the rig.
	transform = Transform3D.IDENTITY
	_viewport = SubViewport.new()
	_viewport.name = "ModelTarget"
	_viewport.size = IDLE_SIZE
	_viewport.own_world_3d = true
	_viewport.transparent_bg = true
	_viewport.gui_disable_input = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	add_child(_viewport)
	_stage = Node3D.new()
	_stage.name = "ModelSpace"
	_viewport.add_child(_stage)
	_stage.transform = global_transform
	_camera = Camera3D.new()
	_camera.name = "CropCamera"
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_viewport.add_child(_camera)
	_model = model
	model.reparent(_stage, false)
	_watch_subtree(model)
	_camera.make_current()


func sync(camera: Camera3D) -> Rect2i:
	if not _active or not is_inside_tree() or not is_instance_valid(_model) \
			or not _model.is_inside_tree() or not is_visible_in_tree() \
			or not _model.is_visible_in_tree() or not is_instance_valid(camera) \
			or not camera.is_inside_tree() or camera.projection != Camera3D.PROJECTION_ORTHOGONAL:
		return _disable()
	_stage.transform = global_transform
	var viewport_size := Vector2i(camera.get_viewport().get_visible_rect().size)
	if viewport_size.x < 2 or viewport_size.y < 2:
		return _disable()
	var camera_transform := camera.get_camera_transform()
	if not camera_transform.is_finite() or is_zero_approx(camera_transform.basis.determinant()):
		return _disable()
	var world_to_camera := camera_transform.affine_inverse()
	var view_bounds := AABB()
	var has_bounds := false
	var mask := camera.cull_mask & ~SHADOW_LAYER
	for id in _meshes:
		var bounds := _meshes[id]
		var mesh := bounds.node
		if not mesh.is_visible_in_tree() or mesh.mesh == null or not (mesh.layers & mask):
			continue
		var skeleton := mesh.get_node_or_null(mesh.skeleton) as Skeleton3D \
			if not mesh.skeleton.is_empty() else null
		var palette: PoseCache = _poses.get(skeleton.get_instance_id()) if skeleton != null else null
		bounds.refresh(palette)
		if not bounds.update_bounds() or not mesh.global_transform.is_finite():
			return _disable()
		var box: AABB = (world_to_camera * mesh.global_transform) * bounds.current
		if not box.position.is_finite() or not box.size.is_finite():
			return _disable()
		view_bounds = view_bounds.merge(box) if has_bounds else box
		has_bounds = true
	if not has_bounds or view_bounds.position.z > -camera.near or view_bounds.end.z < -camera.far:
		return _disable()
	var projection := camera.get_camera_projection()
	if not is_finite(projection.x.x) or not is_finite(projection.y.y) \
			or projection.x.x <= 0.0 or projection.y.y <= 0.0:
		return _disable()
	var size_px := Vector2(viewport_size)
	var lo := Vector2((view_bounds.position.x * projection.x.x + projection.w.x + 1.0) * 0.5 * size_px.x,
		(1.0 - view_bounds.end.y * projection.y.y - projection.w.y) * 0.5 * size_px.y)
	var hi := Vector2((view_bounds.end.x * projection.x.x + projection.w.x + 1.0) * 0.5 * size_px.x,
		(1.0 - view_bounds.position.y * projection.y.y - projection.w.y) * 0.5 * size_px.y)
	if not lo.is_finite() or not hi.is_finite():
		return _disable()
	# Clamp before converting to integers: a finite but distant actor must not
	# overflow an integer or cause a full-screen allocation while offscreen.
	var start := Vector2i(floori(clampf(lo.x - RASTER_MARGIN, 0.0, size_px.x)),
		floori(clampf(lo.y - RASTER_MARGIN, 0.0, size_px.y)))
	var end := Vector2i(ceili(clampf(hi.x + RASTER_MARGIN, 0.0, size_px.x)),
		ceili(clampf(hi.y + RASTER_MARGIN, 0.0, size_px.y)))
	if end.x <= start.x or end.y <= start.y:
		return _disable()
	# SubViewport cannot render a one-pixel dimension. Expand inwards at an
	# edge, keeping the crop clipped and one texel equal to one source pixel.
	start.x = mini(start.x, viewport_size.x - 2)
	start.y = mini(start.y, viewport_size.y - 2)
	end.x = maxi(end.x, start.x + 2)
	end.y = maxi(end.y, start.y + 2)
	var rect := Rect2i(start, end - start)
	var center := Vector2(start) + Vector2(rect.size) * 0.5
	var offset := Vector3(((center.x / size_px.x) * 2.0 - 1.0 - projection.w.x) / projection.x.x,
		(1.0 - (center.y / size_px.y) * 2.0 - projection.w.y) / projection.y.y, 0.0)
	_camera.global_transform = camera_transform * Transform3D(Basis.IDENTITY, offset)
	_camera.keep_aspect = camera.keep_aspect
	var crop_size := camera.size * float(rect.size.y) / size_px.y
	if camera.keep_aspect == Camera3D.KEEP_WIDTH:
		crop_size = camera.size * float(rect.size.x) / size_px.x
	_camera.set_orthogonal(crop_size, camera.near, camera.far)
	_camera.cull_mask = mask
	_camera.environment = camera.environment
	_camera.attributes = camera.attributes
	var source_world := camera.get_world_3d()
	var target_world := _viewport.find_world_3d()
	target_world.environment = source_world.environment
	target_world.fallback_environment = source_world.fallback_environment
	target_world.camera_attributes = source_world.camera_attributes
	_viewport.msaa_3d = camera.get_viewport().msaa_3d
	if _viewport.size != rect.size:
		_viewport.size = rect.size
	_camera.make_current()
	# Only an explicit sync schedules a draw. A skipped sync cannot leave an
	# expensive target rendering forever (or reintroduce a culled model).
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	return rect


func texture() -> Texture2D:
	return _viewport.get_texture() if is_instance_valid(_viewport) else null


func set_active(active: bool) -> void:
	_active = active
	if not active:
		_disable()


func _disable() -> Rect2i:
	if is_instance_valid(_viewport):
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		# Release the formerly visible allocation; hidden actors keep only the
		# smallest valid target and still animate for admission on a later frame.
		if _viewport.size != IDLE_SIZE:
			_viewport.size = IDLE_SIZE
	return Rect2i()


func _watch_subtree(node: Node) -> void:
	var id := node.get_instance_id()
	if _watched.has(id):
		return
	_watched[id] = node
	node.child_entered_tree.connect(_watch_subtree)
	node.child_exiting_tree.connect(_unwatch_subtree)
	if node is Skeleton3D:
		_poses[id] = PoseCache.new(node)
	elif node is ActorBlobShadow:
		# refresh_pose changes visible; a separate layer keeps all its updates
		# and packet data alive without allowing this camera to draw it twice.
		node.layers = SHADOW_LAYER
	elif node is MeshInstance3D:
		_meshes[id] = MeshBounds.new(node)
	for index in node.get_child_count():
		_watch_subtree(node.get_child(index))


func _unwatch_subtree(node: Node) -> void:
	var id := node.get_instance_id()
	if not _watched.has(id):
		return
	node.child_entered_tree.disconnect(_watch_subtree)
	node.child_exiting_tree.disconnect(_unwatch_subtree)
	for index in node.get_child_count():
		_unwatch_subtree(node.get_child(index))
	if _meshes.has(id):
		_meshes[id].dispose()
		_meshes.erase(id)
	if _poses.has(id):
		_poses[id].dispose()
		_poses.erase(id)
	_watched.erase(id)


func _enter_tree() -> void:
	if is_instance_valid(_model):
		_watch_subtree(_model)


func _exit_tree() -> void:
	_disable()
	if is_instance_valid(_model):
		_unwatch_subtree(_model)
