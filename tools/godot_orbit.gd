extends SceneTree
## Godot-side character viewer: renders the exported Seraphim OBJ + textures
## with an orbiting camera and captures the 8 azimuth stills, mirroring the
## Bevy viewer (bevy-port/src/main.rs). Standalone SceneTree script -- run
## from the port directory so res:// resolves, under a real display (not
## --headless, which has no renderer):
##
##   cd godot-port && xvfb-run -a -s "-screen 0 1024x768x24" \
##     godot --path . -s ../bevy-port/tools/godot_orbit.gd
##
## Reads assets from the bevy-port tree (retail-derived, never committed).

const OBJ := "/home/rlinev/Projects/openheilig/bevy-port/assets/models/seraphim.obj"
const TEX_DIR := "/home/rlinev/Projects/openheilig/bevy-port/assets/textures/"
const OUT_DIR := "/tmp/orbit_godot/"
const ANGLES := [0, 45, 90, 135, 180, 225, 270, 315]
const RADIUS := 110.0
const HEIGHT := 48.0
const TARGET := Vector3(0, 36, 0)

var cam: Camera3D
var frame := 0
var angle_i := -1
var busy := false


func _init() -> void:
	var root_env := Environment.new()
	root_env.background_mode = Environment.BG_COLOR
	root_env.background_color = Color(0.08, 0.08, 0.09)
	root_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	root_env.ambient_light_color = Color(0.85, 0.85, 0.9)
	root_env.ambient_light_energy = 1.0
	var world := WorldEnvironment.new()
	world.environment = root_env
	root.add_child(world)

	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-55), deg_to_rad(-40), 0)
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	root.add_child(sun)

	var floor_mi := MeshInstance3D.new()
	var fm := PlaneMesh.new()
	fm.size = Vector2(400, 400)
	floor_mi.mesh = fm
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = Color(0.35, 0.32, 0.28)
	floor_mi.material_override = fmat
	root.add_child(floor_mi)

	var groups := _parse_obj(OBJ)
	for g in groups:
		var mi := MeshInstance3D.new()
		mi.mesh = g["mesh"]
		# Retail's character lighting (player_view.gd _style): UNSHADED with the
		# full-light ramp constant -- no directional shading, or down-facing
		# normals (legs, back) go dark the way retail never draws them.
		var mat := StandardMaterial3D.new()
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(191.0 / 255.0, 191.0 / 255.0, 213.0 / 255.0)
		var tex_path: String = g["texture"]
		if tex_path != "":
			var img := Image.load_from_file(tex_path)
			if img != null:
				mat.albedo_texture = ImageTexture.create_from_image(img)
			else:
				push_warning("orbit: texture missing %s" % tex_path)
		mi.material_override = mat
		root.add_child(mi)

	cam = Camera3D.new()
	cam.fov = 42.0
	cam.position = Vector3(0, HEIGHT, RADIUS)
	cam.look_at_from_position(cam.position, TARGET, Vector3.UP)
	root.add_child(cam)
	cam.make_current()

	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	process_frame.connect(_tick)


func _parse_obj(path: String) -> Array:
	var pos: PackedVector3Array = []
	var uvs: PackedVector2Array = []
	var nrm: PackedVector3Array = []
	var groups: Array = []
	var cur: Dictionary = {}
	for line in FileAccess.open(path, FileAccess.READ).get_as_text().split("\n"):
		var p := line.split(" ")
		match p[0] if p.size() > 0 else "":
			"v":
				pos.append(Vector3(float(p[1]), float(p[2]), float(p[3])))
			"vt":
				uvs.append(Vector2(float(p[1]), float(p[2])))
			"vn":
				nrm.append(Vector3(float(p[1]), float(p[2]), float(p[3])))
			"usemtl":
				if cur.has("st") and cur["indices"].size() > 0:
					groups.append(cur)
				var gname: String = p[1] if p.size() > 1 else "default"
				cur = {"st": SurfaceTool.new(), "indices": [], "name": gname,
					"texture": TEX_DIR + gname + ".png" if gname.begins_with("tex_") else ""}
				cur["st"].begin(Mesh.PRIMITIVE_TRIANGLES)
			"f":
				if cur.is_empty() or p.size() < 4:
					continue
				var corner_ids: Array = []
				for ci in range(1, p.size()):
					var sub := p[ci].split("/")
					corner_ids.append([int(sub[0]), int(sub[1]), int(sub[2])])
				for k in range(1, corner_ids.size() - 1):
					for ci in [0, k, k + 1]:
						var ids: Array = corner_ids[ci]
						var st: SurfaceTool = cur["st"]
						st.set_uv(uvs[ids[1] - 1])
						st.set_normal(nrm[ids[2] - 1])
						st.add_vertex(pos[ids[0] - 1])
						cur["indices"].append(1)
	if cur.has("st") and cur["indices"].size() > 0:
		groups.append(cur)
	for g in groups:
		g["mesh"] = g["st"].commit()
	return groups


func _set_angle(deg: int) -> void:
	var t := deg_to_rad(float(deg))
	cam.position = Vector3(sin(t) * RADIUS, HEIGHT, cos(t) * RADIUS)
	cam.look_at(TARGET, Vector3.UP)


func _tick() -> void:
	if busy:
		return
	frame += 1
	if frame < 15:
		return
	busy = true
	angle_i += 1
	if angle_i >= ANGLES.size():
		quit(0)
		return
	_set_angle(ANGLES[angle_i])
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	img.save_png(OUT_DIR + "a%d.png" % ANGLES[angle_i])
	print("orbit: captured %d (%dx%d)" % [ANGLES[angle_i], img.get_width(), img.get_height()])
	busy = false
