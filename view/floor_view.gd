class_name FloorView
extends Node3D
## Encoded-space painter: floor passes, globally ordered sprites, actor shadows
## and cropped model render targets. SectorView owns native admission/order;
## this node owns the shared composition sequence. Liquids remain separate.

const CANVAS_SHADER: Shader = preload("res://shaders/floor_canvas.gdshader")
const DISPLAY_SHADER: Shader = preload("res://shaders/floor_display.gdshader")
const OBJECT_SHADER: Shader = preload("res://shaders/object.gdshader")
const SHADOW_SHADER: Shader = preload("res://shaders/static_shadow.gdshader")
const MODEL_SHADER: Shader = preload("res://shaders/model_canvas.gdshader")
const ACTOR_SHADOW_SHADER: Shader = preload("res://shaders/actor_shadow_canvas.gdshader")
var SHADOW_INDICES := PackedInt32Array([0, 1, 2, 2, 1, 3])
var QUAD_INDICES := PackedInt32Array([0, 1, 2, 0, 2, 3])


class SectorData extends RefCounted:
	var texture: Texture2DArray
	var surfaces: Array[Array] = []
	var metadata: Array[PackedInt32Array] = []
	# A reference is (quad_index << 1) | masked. Cells index consecutive spans
	# in refs, sorted by (cell_x + cell_y, cell_x, stack_index).
	var refs := PackedInt32Array()
	var cells := PackedInt32Array()  # interleaved absolute x, y
	var starts := PackedInt32Array()  # includes the final end sentinel
	var bounds := PackedVector3Array()  # min, max per cell, including all overlays
	var sector_bounds := AABB()
	var materials: Dictionary[Vector2i, ShaderMaterial] = {}

	func precedes(a: int, b: int) -> bool:
		var ma: PackedInt32Array = metadata[a & 1]
		var mb: PackedInt32Array = metadata[b & 1]
		var ia := (a >> 1) * 3
		var ib := (b >> 1) * 3
		var da := ma[ia] + ma[ia + 1]
		var db := mb[ib] + mb[ib + 1]
		if da != db:
			return da < db
		if ma[ia] != mb[ib]:
			return ma[ia] < mb[ib]
		if ma[ia + 2] != mb[ib + 2]:
			return ma[ia + 2] < mb[ib + 2]
		return a < b

	var indexed := false


## The root stays hidden until every command is ready. Resource snapshots live
## as long as their RIDs, including while an old generation is being retired.
class Generation extends RefCounted:
	var root := RID()
	var items: Array[RID] = []
	var last_material := RID()
	var sectors: Array[SectorData] = []
	var objects: Array[Dictionary] = []
	var actors: Array[Dictionary] = []
	var shadow_material: ShaderMaterial
	var order_max := PackedInt64Array()
	var pre_object_items := 0
	var animated := false
	var revision := 0
	var epoch := 0
	var ready := false
	var camera_transform := Transform3D()
	var inverse_camera := Transform3D()
	var projection := Projection()
	var rect := Rect2()
	var size := Vector2i()
	var viewport := RID()
	var anchor := Vector2.ZERO
	var planes: Array[Plane] = []

	func project(point: Vector3) -> Vector2:
		var local := inverse_camera * point
		var clip := projection * Vector4(local.x, local.y, local.z, 1.0)
		var screen := Vector2(clip.x / clip.w * 0.5 + 0.5, 0.5 - clip.y / clip.w * 0.5) * rect.size
		return (screen - rect.position) * Vector2(size) / rect.size


var _camera: Camera3D
var _sectors: Dictionary[int, SectorData] = {}
var _target: SubViewport
var _canvas: Node2D
var _plane: MeshInstance3D
var _quad: QuadMesh
var _display_material: ShaderMaterial
var _items: Array[RID] = []
signal _build_tick
const BUILD_SLICE_USEC := 3000
var _deadline := 0
var _revision := 0
var _epoch := 0
var _build: Generation
var _displayed: Generation
var _retired: Array[Generation] = []
var _last_slice_frame := -1
var _rendered: Generation
var _dirty := true
var _last_transform := Transform3D()
var _last_projection := Projection()
var _last_rect := Rect2()
var _last_viewport := RID()
## Retain a border of commands so orthographic pans translate the canvas
## instead of projecting and allocating every visible quad every frame.
const PAN_MARGIN := 256.0
var _pan_anchor := Vector2.ZERO
var _object_sectors: Dictionary[int, Dictionary] = {}
var _shadow_material: ShaderMaterial
var _animated := false
var _actors: Dictionary[int, Dictionary] = {}
var _actor_commands: Array[Dictionary] = []
## Per static item: the largest (pass, cell, chain) order key it drew, so an
## actor's item can binary-search its slot and take a draw index inside the
## 16-wide gap after that item. Statics occupy indices i*16; an actor between
## static items never forces a full rebuild.
var _static_order_max: PackedInt64Array = PackedInt64Array()
const ACTOR_INDEX_STRIDE := 16
var _actor_order: Array[Dictionary] = []
var _actor_order_dirty := true
## Persistent actor canvas items (item RID -> actor entry), freed individually
## so actor movement never touches static commands.
var _actor_items: Dictionary[RID, Dictionary] = {}
## Ground/masked item count at the last static rebuild -- the actor draw-index
## base. -1 before the first rebuild (no actors can be registered yet).
var _pre_object_items := -1


## One model target may occur in several native phases (aliased support grids).
## Phase triples are (pass, support ordinal or -1 for base, category partition).
## Sequence is the placement serial; newest placement is first in a cell chain.
func set_actor(model: Node3D, capture: Node3D, cell_order: int, sequence: int,
		phases: Array[Vector3i]) -> void:
	var id := model.get_instance_id()
	var actor: Dictionary = _actors.get(id, {})
	if actor.is_empty():
		var material := ShaderMaterial.new()
		material.shader = MODEL_SHADER
		material.set_shader_parameter(&"image", capture.texture())
		actor = {"model": model, "capture": capture, "material": material,
			"rect": Rect2i(), "phases": [], "cell": -1, "sequence": -1,
			"shadow_material": null, "shadow_texture": null}
		_actors[id] = actor
	if actor["cell"] == cell_order and actor["sequence"] == sequence and actor["phases"] == phases:
		return
	actor["cell"] = cell_order
	actor["sequence"] = sequence
	actor["phases"] = phases.duplicate()
	# Movement re-sorts only the actor stream; the ~35k static commands stay
	# cached. The actor's own canvas items are re-created on the next submit.
	_actor_order_dirty = true


func remove_actor(id: int) -> void:
	if not _actors.has(id):
		return
	for rid: RID in _actor_items.keys():
		if _actor_items[rid].get("model") == _actors[id]["model"]:
			RenderingServer.free_rid(rid)
			_actor_items.erase(rid)
	_actors.erase(id)
	_actor_order_dirty = true


func _sync_actor_targets() -> bool:
	var active := false
	for id: int in _actors.keys():
		var actor: Dictionary = _actors[id]
		if not is_instance_valid(actor["model"]) or not is_instance_valid(actor["capture"]):
			if is_instance_valid(actor["capture"]):
				actor["capture"].queue_free()
			remove_actor(id)
			continue
		var capture: Node3D = actor["capture"]
		if actor["phases"].is_empty():
			capture.set_active(false)
			actor["rect"] = Rect2i()
			continue
		actor["model"].prepare_render()
		capture.set_active(true)
		var rect: Rect2i = capture.sync(_camera)
		actor["rect"] = rect
		active = active or rect.has_area()
	return active


## Static chain entries precede every dynamic phase at the same visited cell.
static func _precedes(a: Dictionary, b: Dictionary) -> bool:
	var ao: Vector3i = a["order"]
	var bo: Vector3i = b["order"]
	if ao.x != bo.x:
		return ao.x < bo.x
	if ao.y != bo.y:
		return ao.y < bo.y
	var ap: int = a.get("phase", 0)
	var bp: int = b.get("phase", 0)
	if ap != bp:
		return ap < bp
	if ap != 0:
		if a["support"] != b["support"]:
			return a["support"] < b["support"]
		if a["category"] != b["category"]:
			return a["category"] < b["category"]
	return ao.z < bo.z


## May be called before either node enters the tree. Rendering waits for sync().
func configure(camera: Camera3D, shadow_texture: Texture2D) -> void:
	_camera = camera
	if shadow_texture != null:
		_shadow_material = ShaderMaterial.new()
		_shadow_material.shader = SHADOW_SHADER
		_shadow_material.set_shader_parameter(&"shadow_tex", shadow_texture)
	_epoch += 1
	_revision += 1
	_dirty = true
	if is_inside_tree() and not RenderingServer.frame_pre_draw.is_connected(sync):
		RenderingServer.frame_pre_draw.connect(sync)


## Replaces a sector atomically. Metadata has (absolute x, y, stack) per quad;
## stack 0 is ground. Arrays contain four N,E,S,W vertices per quad, with scalar
## corner light in COLOR.rgb and a constant art/mask layer within each quad.
## Empty arrays are accepted when their corresponding metadata is empty.
func set_sector(key: int, texture: Texture2DArray, arrays: Array, masked_arrays: Array,
		metadata: PackedInt32Array, masked_metadata: PackedInt32Array) -> void:
	assert(metadata.size() % 3 == 0 and masked_metadata.size() % 3 == 0)
	if metadata.is_empty() and masked_metadata.is_empty():
		remove_sector(key)
		return
	assert(texture != null)
	var data := SectorData.new()
	data.texture = texture
	# Duplicate only the Array shells. Packed payloads remain copy-on-write.
	data.surfaces = [arrays.duplicate(), masked_arrays.duplicate()]
	data.metadata = [metadata, masked_metadata]
	if _sectors.has(key):
		_epoch += 1
	_sectors[key] = data
	_revision += 1
	_dirty = true


func set_objects(key: int, data: Dictionary) -> void:
	if _object_sectors.has(key):
		_epoch += 1
	_object_sectors[key] = data
	_revision += 1
	_dirty = true


## Raw trigger changes preserve geometry and order, but invalidate cached pixels.
func invalidate_objects() -> void:
	_epoch += 1
	_revision += 1
	_dirty = true


## Removal invalidates pending snapshots; displayed resources survive until the
## replacement is published and their retired commands have been released.
func remove_sector(key: int) -> void:
	if not _sectors.has(key) and not _object_sectors.has(key):
		return
	_epoch += 1
	_revision += 1
	_sectors.erase(key)
	_object_sectors.erase(key)
	_dirty = true


## Releases all floor data and GPU output, retaining the configured camera.
func clear() -> void:
	_release_output()
	_sectors.clear()
	_object_sectors.clear()
	_actor_order_dirty = true
	_epoch += 1
	_revision += 1
	_dirty = true


## sync is the sole coroutine driver. Only its bounded slice writes to the
## building root; live actors continue using the complete displayed root.
func sync() -> void:
	if not is_inside_tree() or not is_instance_valid(_camera) or not _camera.is_inside_tree():
		return
	var frame := Engine.get_process_frames()
	if frame == _last_slice_frame:
		return
	_last_slice_frame = frame
	_deadline = Time.get_ticks_usec() + BUILD_SLICE_USEC
	if _sectors.is_empty() and _object_sectors.is_empty():
		_cancel_build()
		_retire_displayed()
		if _plane != null:
			_plane.hide()
		_retire_slice()
		if _retired.is_empty():
			_release_output()
		_dirty = false
		return
	var viewport := _camera.get_viewport()
	var rect := viewport.get_visible_rect()
	if rect.size.x < 2.0 or rect.size.y < 2.0:
		_cancel_build()
		if _plane != null:
			_plane.hide()
		_dirty = true
		_retire_slice()
		return
	var transform := _camera.get_camera_transform()
	var projection := _camera.get_camera_projection()
	var viewport_rid := viewport.get_viewport_rid()
	var anchor := _camera.unproject_position(Vector3.ZERO)
	if _build != null and (_build.epoch != _epoch \
			or not _can_reuse(_build, transform, projection, rect, viewport_rid, anchor)):
		_cancel_build()
	# Reserve retirement progress even under repeated camera cancellation.
	_retire_slice(mini(_deadline, Time.get_ticks_usec() + 500))
	var reusable := _displayed != null \
		and _can_reuse(_displayed, transform, projection, rect, viewport_rid, anchor)
	var remaining := maxi(0, _deadline - Time.get_ticks_usec())
	var actors_active := _sync_actor_targets()
	if reusable:
		var pan := anchor - _displayed.anchor
		var moved := _canvas.position != pan
		_canvas.position = pan
		if moved:
			_position_display(rect, transform)
			_rendered = null
		var shadows_active := _refresh_actor_order(rect)
		if _animated or actors_active or shadows_active:
			_target.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		elif moved or _target.render_target_update_mode == SubViewport.UPDATE_ALWAYS:
			_target.render_target_update_mode = SubViewport.UPDATE_ONCE
		_plane.show()
	elif _target != null:
		_target.render_target_update_mode = SubViewport.UPDATE_DISABLED
	# Existing live actor capture/composition is independent of static rebuild
	# work. A busy actor frame must not starve the static coroutine forever.
	_deadline = Time.get_ticks_usec() + remaining
	if _build == null and (_dirty or not reusable):
		if not _sectors.is_empty() or _displayed != null:
			_start_build(rect, transform, projection, viewport_rid, anchor)
		else:
			_dirty = false
	elif _build != null:
		_build_tick.emit()
	if _build != null and _build.ready:
		_publish_build(rect, transform, anchor, actors_active)
	_retire_slice()


func is_settled() -> bool:
	if _dirty or _build != null or not _retired.is_empty():
		return false
	if _displayed == null:
		return true
	if not is_instance_valid(_camera) or not _camera.is_inside_tree() or _actor_order_dirty:
		return false
	var viewport := _camera.get_viewport()
	if not _can_reuse(_displayed, _camera.get_camera_transform(), _camera.get_camera_projection(),
			viewport.get_visible_rect(), viewport.get_viewport_rid(), _camera.unproject_position(Vector3.ZERO)):
		return false
	return _rendered == _displayed or DisplayServer.get_name() == "headless"


func _on_frame_post_draw() -> void:
	_rendered = _displayed


func _can_reuse(g: Generation, transform: Transform3D, projection: Projection,
		rect: Rect2, viewport: RID, anchor: Vector2) -> bool:
	if projection != g.projection or rect != g.rect or viewport != g.viewport:
		return false
	if transform == g.camera_transform:
		return true
	var translation := transform.origin - g.camera_transform.origin
	var pan := (anchor - g.anchor).abs()
	return _camera.projection == Camera3D.PROJECTION_ORTHOGONAL \
		and transform.basis == g.camera_transform.basis \
		and absf(translation.dot(transform.basis.z)) < 0.0001 \
		and pan.x < PAN_MARGIN and pan.y < PAN_MARGIN


func _start_build(rect: Rect2, transform: Transform3D, projection: Projection,
		viewport: RID, anchor: Vector2) -> void:
	_ensure_output()
	var g := Generation.new()
	g.sectors.assign(_sectors.values())
	g.objects.assign(_object_sectors.values())
	g.shadow_material = _shadow_material
	g.revision = _revision
	g.epoch = _epoch
	g.camera_transform = transform
	g.inverse_camera = transform.affine_inverse()
	g.projection = projection
	g.rect = rect
	g.size = Vector2i(ceil(rect.size.x), ceil(rect.size.y))
	g.viewport = viewport
	g.anchor = anchor
	g.planes = _camera.get_frustum()
	var margin_world := _camera.project_position(Vector2(PAN_MARGIN, 0), _camera.near) \
		.distance_to(_camera.project_position(Vector2.ZERO, _camera.near))
	for i in g.planes.size():
		if absf(g.planes[i].normal.dot(_camera.global_basis.z)) < 0.5:
			g.planes[i].d += margin_world
	g.root = RenderingServer.canvas_item_create()
	RenderingServer.canvas_item_set_parent(g.root, _canvas.get_canvas_item())
	RenderingServer.canvas_item_set_visible(g.root, false)
	_build = g
	_build_commands(g)


func _publish_build(rect: Rect2, transform: Transform3D, anchor: Vector2,
		actors_active: bool) -> void:
	var g := _build
	_build = null
	_retire_displayed()
	_displayed = g
	_items = g.items
	_static_order_max = g.order_max
	_pre_object_items = g.pre_object_items
	_animated = g.animated
	_last_transform = g.camera_transform
	_last_projection = g.projection
	_last_rect = g.rect
	_last_viewport = g.viewport
	_pan_anchor = g.anchor
	_canvas.position = anchor - g.anchor
	_target.size = g.size
	_position_display(rect, transform)
	_actor_order_dirty = true
	var shadows_active := _refresh_actor_order(rect)
	RenderingServer.canvas_item_set_visible(g.root, true)
	_target.render_target_update_mode = SubViewport.UPDATE_ALWAYS \
		if _animated or actors_active or shadows_active else SubViewport.UPDATE_ONCE
	_plane.show()
	# Publish additive snapshots rather than restarting on every streamed sector.
	_dirty = g.revision != _revision


func _cancel_build() -> void:
	if _build == null:
		return
	var old := _build
	_build = null
	_build_tick.emit()
	_retired.append(old)


func _retire_displayed() -> void:
	if _displayed == null:
		return
	RenderingServer.canvas_item_set_visible(_displayed.root, false)
	# Actors share the same root/depth ordering, and their materials must live
	# until these hidden RIDs have also been released by the retirement slice.
	for rid: RID in _actor_items:
		_displayed.items.append(rid)
	_displayed.actors = _actor_commands
	_actor_items.clear()
	_actor_commands = []
	_actor_order_dirty = true
	_retired.append(_displayed)
	_displayed = null
	_rendered = null
	_items = []
	_static_order_max = PackedInt64Array()
	_pre_object_items = -1


func _budget(g: Generation) -> bool:
	if Time.get_ticks_usec() >= _deadline:
		await _build_tick
	return _build == g


func _retire_slice(until: int = -1) -> void:
	var limit := _deadline if until < 0 else until
	while not _retired.is_empty() and Time.get_ticks_usec() < limit:
		var g := _retired[0]
		if not g.items.is_empty():
			RenderingServer.free_rid(g.items.pop_back())
		else:
			RenderingServer.free_rid(g.root)
			_retired.pop_front()


func _ensure_output() -> void:
	if _target != null:
		return
	_target = SubViewport.new()
	_target.name = "FloorCanvas"
	_target.disable_3d = true
	_target.use_hdr_2d = false
	_target.transparent_bg = true
	_target.gui_disable_input = true
	_target.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	_target.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_target)
	_canvas = Node2D.new()
	_target.add_child(_canvas)
	_quad = QuadMesh.new()
	_display_material = ShaderMaterial.new()
	_display_material.shader = DISPLAY_SHADER
	_display_material.set_shader_parameter(&"image", _target.get_texture())
	_plane = MeshInstance3D.new()
	_plane.name = "FloorDisplay"
	_plane.mesh = _quad
	_plane.material_override = _display_material
	_plane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_plane.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_plane.ignore_occlusion_culling = true
	add_child(_plane)
	_plane.top_level = true
	_plane.hide()


func _position_display(rect: Rect2, camera_transform: Transform3D) -> void:
	# A real opaque plane, just inside the camera's far limit, cannot overwrite
	# nearer opaque objects even when Godot reorders the opaque draw queue.
	var depth := lerpf(_camera.near, _camera.far, 0.999)
	var top_left := _camera.project_position(rect.position, depth)
	var top_right := _camera.project_position(Vector2(rect.end.x, rect.position.y), depth)
	var bottom_left := _camera.project_position(Vector2(rect.position.x, rect.end.y), depth)
	_quad.size = Vector2(top_left.distance_to(top_right), top_left.distance_to(bottom_left))
	_plane.global_transform = Transform3D(camera_transform.basis, (top_right + bottom_left) * 0.5)
	# sync may run in frame_pre_draw, after the scene-tree transform flush.
	# Publish the matching display plane now, not one frame after its canvas.
	_plane.force_update_transform()


## Sorting is sliced too: sorting an entire static stream must not become the
## next frame stall after projection and command creation have been bounded.
func _sort(g: Generation, values: Array, precedes: Callable) -> bool:
	var scratch: Array = []
	scratch.resize(values.size())
	var width := 1
	while width < values.size():
		for start in range(0, values.size(), width * 2):
			var middle := mini(start + width, values.size())
			var end := mini(start + width * 2, values.size())
			var left := start
			var right := middle
			for out in range(start, end):
				if not await _budget(g):
					return false
				if left < middle and (right >= end or not precedes.call(values[right], values[left])):
					scratch[out] = values[left]
					left += 1
				else:
					scratch[out] = values[right]
					right += 1
		for i in values.size():
			if not await _budget(g):
				return false
			values[i] = scratch[i]
		width *= 2
	return true


func _index_sector(g: Generation, data: SectorData) -> bool:
	if data.indexed:
		return true
	var order: Array = []
	for surface in 2:
		for quad in data.metadata[surface].size() / 3:
			if not await _budget(g):
				return false
			order.append((quad << 1) | surface)
	if not await _sort(g, order, data.precedes):
		return false
	var refs := PackedInt32Array(order)
	var cells := PackedInt32Array()
	var starts := PackedInt32Array()
	var bounds := PackedVector3Array()
	var last_cell := Vector2i()
	var box := AABB()
	var sector_box := AABB()
	for i in refs.size():
		if not await _budget(g):
			return false
		var ref := refs[i]
		var surface := ref & 1
		var quad := ref >> 1
		var meta: PackedInt32Array = data.metadata[surface]
		var cell := Vector2i(meta[quad * 3], meta[quad * 3 + 1])
		var vertices: PackedVector3Array = data.surfaces[surface][Mesh.ARRAY_VERTEX]
		if i == 0 or cell != last_cell:
			if i > 0:
				bounds.append(box.position)
				bounds.append(box.end)
			cells.append(cell.x)
			cells.append(cell.y)
			starts.append(i)
			box = AABB(vertices[quad * 4], Vector3.ZERO)
			last_cell = cell
		for corner in 4:
			box = box.expand(vertices[quad * 4 + corner])
	if not refs.is_empty():
		bounds.append(box.position)
		bounds.append(box.end)
		sector_box = AABB(bounds[0], Vector3.ZERO)
		for point in bounds:
			if not await _budget(g):
				return false
			sector_box = sector_box.expand(point)
	starts.append(refs.size())
	data.refs = refs
	data.cells = cells
	data.starts = starts
	data.bounds = bounds
	data.sector_bounds = sector_box
	data.indexed = true
	return true


func _build_commands(g: Generation) -> void:
	var visible: Array = []
	for s in g.sectors.size():
		var data := g.sectors[s]
		if not await _index_sector(g, data):
			return
		if not _intersects_view(data.sector_bounds, g.planes):
			continue
		for cell in data.starts.size() - 1:
			if not await _budget(g):
				return
			var lo := data.bounds[cell * 2]
			var hi := data.bounds[cell * 2 + 1]
			if _intersects_view(AABB(lo, hi - lo), g.planes):
				visible.append(Vector2i(s, cell))
	var precedes := func(a: Vector2i, b: Vector2i) -> bool:
		var ca: PackedInt32Array = g.sectors[a.x].cells
		var cb: PackedInt32Array = g.sectors[b.x].cells
		var ax := ca[a.y * 2]
		var bx := cb[b.y * 2]
		var da := ax + ca[a.y * 2 + 1]
		var db := bx + cb[b.y * 2 + 1]
		return da < db if da != db else ax < bx
	if not await _sort(g, visible, precedes):
		return
	var cursors := PackedInt32Array()
	cursors.resize(visible.size())
	for i in visible.size():
		if not await _budget(g):
			return
		var cell: Vector2i = visible[i]
		var data := g.sectors[cell.x]
		var cursor := data.starts[cell.y]
		var ref := data.refs[cursor]
		if data.metadata[ref & 1][(ref >> 1) * 3 + 2] == 0:
			_submit_quad(g, data, ref)
			cursor += 1
		cursors[i] = cursor
	var masked := 1
	while true:
		var pending := false
		for i in visible.size():
			if not await _budget(g):
				return
			var cell: Vector2i = visible[i]
			var data := g.sectors[cell.x]
			var cursor := cursors[i]
			var end := data.starts[cell.y + 1]
			while cursor < end:
				if not await _budget(g):
					return
				var ref := data.refs[cursor]
				if (ref & 1) != masked:
					pending = true
					break
				_submit_quad(g, data, ref)
				cursor += 1
			cursors[i] = cursor
		if not pending:
			break
		masked = 1 - masked
	if not await _build_objects(g):
		return
	g.ready = true


func _build_objects(g: Generation) -> bool:
	g.pre_object_items = g.items.size()
	var order: Array = []
	for data: Dictionary in g.objects:
		for shadow: Dictionary in data["shadows"]:
			if not await _budget(g):
				return false
			order.append({"order": shadow["order"], "shadow": shadow})
		for span: Dictionary in data["spans"]:
			if not await _budget(g):
				return false
			order.append({"order": span["order"], "span": span, "data": data})
	if not await _sort(g, order, _precedes):
		return false
	for entry: Dictionary in order:
		if not await _budget(g):
			return false
		if entry.has("shadow"):
			_submit_shadow(g, entry["shadow"], _pack_order(entry["order"]))
			continue
		var span: Dictionary = entry["span"]
		if not span["admitted"]:
			continue
		var packed := _pack_order(entry["order"])
		if not span["shadow"].is_empty():
			_submit_shadow(g, span["shadow"], packed)
		var data: Dictionary = entry["data"]
		var indices: PackedInt32Array = data["idx"]
		var vertices: PackedVector3Array = data["pos"]
		var uvs: PackedVector2Array = data["uv"]
		var layers: PackedVector2Array = data["uv2"]
		var colors: PackedColorArray = data["animation"]
		for index in range(span["start"], span["end"], 6):
			if not await _budget(g):
				return false
			var first := indices[index]
			var points := _project_quad(g, vertices, first)
			if points.is_empty():
				continue
			var layer := int(layers[first].x)
			var material: ShaderMaterial = data["materials"].get(layer)
			if material == null:
				material = ShaderMaterial.new()
				material.shader = OBJECT_SHADER
				material.set_shader_parameter(&"tex", data["texture"])
				material.set_shader_parameter(&"layer", layer)
				data["materials"][layer] = material
			g.animated = g.animated or colors[first].r > 0.0
			var item := _command(g, material)
			RenderingServer.canvas_item_add_triangle_array(item,
				QUAD_INDICES, points, colors.slice(first, first + 4), uvs.slice(first, first + 4))
			g.order_max[g.items.size() - 1] = maxi(g.order_max[g.items.size() - 1], packed)
	return true


func _rebuild_actor_order() -> void:
	_actor_order.clear()
	for actor: Dictionary in _actors.values():
		for phase: Vector3i in actor["phases"]:
			_actor_order.append({"order": Vector3i(phase.x, actor["cell"], -actor["sequence"]),
				"phase": 2 if phase.y < 0 else 1, "support": phase.y,
				"category": phase.z, "actor": actor})
	_actor_order.sort_custom(_precedes)


func _submit_actor_commands(pre_object_items: int) -> void:
	for rid: RID in _actor_items:
		RenderingServer.free_rid(rid)
	_actor_items.clear()
	_actor_commands.clear()
	var spread := 0
	var last_key := -1
	for entry: Dictionary in _actor_order:
		var actor: Dictionary = entry["actor"]
		if actor["shadow_material"] == null:
			var shadow_material := ShaderMaterial.new()
			shadow_material.shader = ACTOR_SHADOW_SHADER
			actor["shadow_material"] = shadow_material
		var key := _pack_order(entry["order"])
		spread = spread + 1 if key == last_key else 0
		last_key = key
		# The gap between the static item this actor belongs behind and the
		# next one. Same-key actors keep native chain order: placement
		# prepends, so the newest draws first (lowest index).
		var base := _actor_draw_index(key, pre_object_items) + spread * 2
		var shadow_item := _new_item(actor["shadow_material"], base - 1)
		var item := _new_item(actor["material"], base)
		entry["shadow_item"] = shadow_item
		entry["item"] = item
		_actor_items[shadow_item] = entry
		_actor_items[item] = entry
		_actor_commands.append(entry)


## order Vector3i (pass, cell, chain) packed into one comparable int64.
static func _pack_order(order: Vector3i) -> int:
	return (clampi(order.x, 0, 7) << 54) | (clampi(order.y, 0, 1 << 26) << 14) \
		| clampi(order.z + (1 << 13), 0, (1 << 14) - 1)


## The draw index just after the last static item this actor belongs behind.
## Static items occupy the top of each ACTOR_INDEX_STRIDE gap; the actor takes
## slots just below the first item whose max key exceeds its own. Only OBJECT
## items are searched -- the sentinel-filled ground/masked entries before
## pre_object_items would otherwise advance the cursor past object item 0 and
## draw the actor over statics it belongs behind.
func _actor_draw_index(key: int, pre_object_items: int) -> int:
	var lo := pre_object_items
	var hi := _static_order_max.size()
	while lo < hi:
		var mid := (lo + hi) >> 1
		if _static_order_max[mid] <= key:
			lo = mid + 1
		else:
			hi = mid
	return (lo + 1) * ACTOR_INDEX_STRIDE - 3

## Object items start after the ground/masked items the last full rebuild
## created; that count is the actor draw-index base.
func pre_object_items_for_actors() -> int:
	return _pre_object_items


## An actor order change alone (walking) resubmits just the actor items --
## the cached static commands stay untouched.
func _refresh_actor_order(rect: Rect2) -> bool:
	if _actor_order_dirty:
		_rebuild_actor_order()
		_submit_actor_commands(_pre_object_items)
		_actor_order_dirty = false
	return _refresh_actor_commands(rect)


## Only live actor commands change on an idle camera. Cached static commands,
## atlases and materials stay intact while skeletal targets update on the GPU.
func _refresh_actor_commands(rect: Rect2) -> bool:
	var active := false
	var scale := Vector2(_target.size) / rect.size
	for entry: Dictionary in _actor_commands:
		var actor: Dictionary = entry["actor"]
		var item: RID = entry["item"]
		var shadow_item: RID = entry["shadow_item"]
		# Actor crops/shadows are projected with the current camera, unlike
		# static commands. Cancel the cached canvas's pan for these siblings.
		var screen_transform := Transform2D(0.0, -_canvas.position)
		RenderingServer.canvas_item_set_transform(item, screen_transform)
		RenderingServer.canvas_item_set_transform(shadow_item, screen_transform)
		RenderingServer.canvas_item_clear(item)
		RenderingServer.canvas_item_clear(shadow_item)
		if not is_instance_valid(actor["model"]) or not is_instance_valid(actor["capture"]):
			continue
		var model: Node3D = actor["model"]
		if not model.is_inside_tree() or not model.is_visible_in_tree() \
				or not actor["capture"].is_visible_in_tree():
			continue
		if model.has_method("blob_shadow"):
			var shadow = model.blob_shadow()
			if is_instance_valid(shadow) and shadow.visible:
				if actor["shadow_texture"] != shadow.shadow_texture:
					actor["shadow_texture"] = shadow.shadow_texture
					actor["shadow_material"].set_shader_parameter(&"shadow_texture", shadow.shadow_texture)
				for draw in 5:
					if draw == 0 and not shadow.root_present:
						continue
					var points := PackedVector2Array()
					points.resize(4)
					for corner in 4:
						var x: float = -shadow.half_sizes[draw] if corner < 2 else shadow.half_sizes[draw]
						var y: float = -shadow.half_sizes[draw] if corner % 2 == 0 else shadow.half_sizes[draw]
						var position: Vector3 = shadow.world_origin + shadow.retail_to_port * (shadow.centers[draw] + Vector3(x, y, 0))
						points[corner] = (_camera.unproject_position(position) - rect.position) * scale
					var bounds := Rect2(points[0], Vector2.ZERO)
					for corner in range(1, 4):
						bounds = bounds.expand(points[corner])
					if not bounds.intersects(Rect2(Vector2.ZERO, Vector2(_target.size))):
						continue
					active = true
					RenderingServer.canvas_item_add_triangle_array(shadow_item, SHADOW_INDICES,
						points, PackedColorArray([Color.WHITE]),
						PackedVector2Array([Vector2(0, 1), Vector2(0, 0), Vector2(1, 1), Vector2(1, 0)]))
		var target_rect: Rect2i = actor["rect"]
		if target_rect.has_area():
			var screen_rect := Rect2((Vector2(target_rect.position) - rect.position) * scale,
				Vector2(target_rect.size) * scale)
			RenderingServer.canvas_item_add_texture_rect(item, screen_rect,
				actor["capture"].texture().get_rid())
	return active



func _submit_shadow(g: Generation, shadow: Dictionary, order: int) -> void:
	if g.shadow_material == null:
		return
	var points := _project_quad(g, shadow["points"], 0)
	if points.is_empty():
		return
	# ponytail: current world is daylight. Native's solar clock changes shadow
	# transparency (environment +77188); there is no solar-clock input here yet.
	# Daylight's observed zero transparency means white diffuse, not a fitted alpha.
	RenderingServer.canvas_item_add_triangle_array(_command(g, g.shadow_material),
		SHADOW_INDICES, points, PackedColorArray([Color.WHITE]), shadow["uv"])
	g.order_max[g.items.size() - 1] = maxi(g.order_max[g.items.size() - 1], order)


func _project_quad(g: Generation, vertices: PackedVector3Array, first: int) -> PackedVector2Array:
	var points := PackedVector2Array()
	points.resize(4)
	for corner in 4:
		points[corner] = g.project(vertices[first + corner])
	var bounds := Rect2(points[0], Vector2.ZERO)
	for corner in range(1, 4):
		bounds = bounds.expand(points[corner])
	if not bounds.intersects(Rect2(Vector2.ZERO, Vector2(g.size)).grow(PAN_MARGIN)):
		return PackedVector2Array()
	return points


func _command(g: Generation, material: ShaderMaterial) -> RID:
	var material_rid := material.get_rid()
	if g.items.is_empty() or material_rid != g.last_material:
		# Static items occupy i * ACTOR_INDEX_STRIDE so actor items can slot
		# into the gaps without renumbering the statics.
		var item := RenderingServer.canvas_item_create()
		RenderingServer.canvas_item_set_parent(item, g.root)
		RenderingServer.canvas_item_set_draw_index(item, (g.items.size() + 1) * ACTOR_INDEX_STRIDE - 1)
		RenderingServer.canvas_item_set_material(item, material_rid)
		g.items.append(item)
		g.order_max.append(-1)
		g.last_material = material_rid
	return g.items[-1]


## A standalone canvas item at an explicit draw index -- the actor path, whose
## items outlive static rebuilds and are freed individually.
func _new_item(material: ShaderMaterial, draw_index: int) -> RID:
	var item := RenderingServer.canvas_item_create()
	RenderingServer.canvas_item_set_parent(item, _displayed.root)
	RenderingServer.canvas_item_set_draw_index(item, draw_index)
	RenderingServer.canvas_item_set_material(item, material.get_rid())
	return item


func _intersects_view(box: AABB, planes: Array[Plane]) -> bool:
	var center := box.get_center()
	var half := box.size * 0.5
	for plane in planes:
		if plane.distance_to(center) > plane.normal.abs().dot(half):
			return false
	return true


func _submit_quad(g: Generation, data: SectorData, ref: int) -> void:
	var surface := ref & 1
	var first := (ref >> 1) * 4
	var arrays: Array = data.surfaces[surface]
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var layers: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var custom := PackedFloat32Array()
	var mask := -1
	if surface == 1:
		custom = arrays[Mesh.ARRAY_CUSTOM0]
		mask = int(custom[first * 4 + 2])
	var points := PackedVector2Array()
	var attributes := PackedColorArray()
	points.resize(4)
	attributes.resize(4)
	for corner in 4:
		var vertex := first + corner
		points[corner] = g.project(vertices[vertex])
		var mask_uv := Vector2.ZERO
		if surface == 1:
			mask_uv = Vector2(custom[vertex * 4], custom[vertex * 4 + 1])
		attributes[corner] = Color(colors[vertex].r, mask_uv.x, mask_uv.y, 1.0)
	var key := Vector2i(int(layers[first].x), mask)
	var material: ShaderMaterial = data.materials.get(key)
	if material == null:
		material = ShaderMaterial.new()
		material.shader = CANVAS_SHADER
		material.set_shader_parameter(&"tex", data.texture)
		material.set_shader_parameter(&"art_layer", key.x)
		material.set_shader_parameter(&"mask_layer", key.y)
		data.materials[key] = material
	RenderingServer.canvas_item_add_triangle_array(_command(g, material), QUAD_INDICES,
		points, attributes, uvs.slice(first, first + 4))


func _free_commands() -> void:
	_cancel_build()
	for rid: RID in _actor_items:
		RenderingServer.free_rid(rid)
	_actor_items.clear()
	_actor_commands.clear()
	_actor_order.clear()
	_actor_order_dirty = true
	if _displayed != null:
		_retired.append(_displayed)
	_displayed = null
	_rendered = null
	_items = []
	_static_order_max = PackedInt64Array()
	_pre_object_items = -1
	# Explicit clear/tree exit has no future frame in which to finish releasing
	# raw RIDs. Streaming replacement/removal instead uses _retire_slice().
	for g in _retired:
		for item in g.items:
			RenderingServer.free_rid(item)
		RenderingServer.free_rid(g.root)
	_retired.clear()


func _release_output() -> void:
	_free_commands()
	if is_instance_valid(_plane):
		_plane.free()
	_plane = null
	_quad = null
	_display_material = null
	if is_instance_valid(_target):
		_target.free()
	_target = null
	_canvas = null


func _enter_tree() -> void:
	if not RenderingServer.frame_pre_draw.is_connected(sync):
		RenderingServer.frame_pre_draw.connect(sync)
	if not RenderingServer.frame_post_draw.is_connected(_on_frame_post_draw):
		RenderingServer.frame_post_draw.connect(_on_frame_post_draw)
	_last_slice_frame = -1
	_dirty = true


func _exit_tree() -> void:
	if RenderingServer.frame_pre_draw.is_connected(sync):
		RenderingServer.frame_pre_draw.disconnect(sync)
	if RenderingServer.frame_post_draw.is_connected(_on_frame_post_draw):
		RenderingServer.frame_post_draw.disconnect(_on_frame_post_draw)
	# The child Nodes own their viewport/mesh RIDs and free those with the tree.
	# Raw canvas RIDs are ours. Free now, also making removal/re-entry safe.
	_free_commands()
	if is_instance_valid(_target):
		_target.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if is_instance_valid(_plane):
		_plane.hide()
	_dirty = true
