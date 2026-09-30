## Rendered, asset-free regression: run with Forward+ and a display (or xvfb-run).
## godot --path godot-port --script res://probes/canvas_pan_probe.gd
extends SceneTree
const Floor = preload("res://view/floor_view.gd")
var failures := 0
var floor_view: Node3D
var camera: Camera3D
func _initialize() -> void:
	_run.call_deferred()
func _frames() -> void:
	var deadline := Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		await RenderingServer.frame_post_draw
		if floor_view.is_settled():
			return
	_expect(false, "canvas publishes a complete generation before timeout")
	quit(1)
func _run() -> void:
	root.size = Vector2i(128,128)
	camera = Camera3D.new()
	root.add_child(camera)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 128
	camera.position.z = 100
	camera.far = 200
	camera.current = true
	floor_view = Floor.new()
	root.add_child(floor_view)
	floor_view.configure(camera, null)
	floor_view.set_sector(0, _texture(Color.WHITE), _arrays(2048), [], PackedInt32Array([0,0,0]), PackedInt32Array())
	var sprite = _arrays(16)
	var vertices: PackedVector3Array = sprite[Mesh.ARRAY_VERTEX]
	for i in vertices.size():
		vertices[i].x += 100
	floor_view.set_objects(0, {"shadows": [], "spans": [{"order": Vector3i(3,2,0), "admitted": true, "shadow": {}, "start": 0, "end": 6}], "idx": PackedInt32Array([0,1,2,0,2,3]), "pos": vertices, "uv": sprite[Mesh.ARRAY_TEX_UV], "uv2": sprite[Mesh.ARRAY_TEX_UV2], "animation": PackedColorArray([Color(0,0,0,0),Color(0,0,0,0),Color(0,0,0,0),Color(0,0,0,0)]), "materials": {}, "texture": _texture(Color(1,0,0,1))})
	await _frames()
	for x in [80.0, 100.25, 400.0, 100.0]:
		camera.position.x = x
		await _frames()
		var cached := root.get_texture().get_image()
		floor_view.invalidate_objects()
		await _frames()
		var fresh := root.get_texture().get_image()
		_expect(cached.get_data() == fresh.get_data(), "cached pan equals fresh render at x=" + str(x))
		if x == 100:
			_expect(fresh.get_pixel(64,64).b > 0.9 and fresh.get_pixel(64,64).r < 0.1, "static survives pan and cache-boundary rebuild")
	camera.size = 64
	root.size = Vector2i(192,128)
	await _frames()
	var resized := root.get_texture().get_image()
	floor_view.invalidate_objects()
	await _frames()
	_expect(resized.get_data() == root.get_texture().get_image().get_data(), "zoom and resize invalidate projection")
	print("pan_probe failures=", failures)
	quit(1 if failures else 0)
func _texture(color: Color) -> Texture2DArray:
	var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	image.fill(color)
	var texture := Texture2DArray.new()
	texture.create_from_images([image])
	return texture

func _arrays(half: float) -> Array:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(-half, half, -10), Vector3(half, half, -10), Vector3(half, -half, -10), Vector3(-half, -half, -10)])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2(0,0), Vector2(1,0), Vector2(1,1), Vector2(0,1)])
	arrays[Mesh.ARRAY_TEX_UV2] = PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
	arrays[Mesh.ARRAY_COLOR] = PackedColorArray([Color.WHITE, Color.WHITE, Color.WHITE, Color.WHITE])
	return arrays

func _expect(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ", label)
	if not ok:
		failures += 1
