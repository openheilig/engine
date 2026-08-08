class_name ModelView
extends Node3D
## Renders one Granny .GRN entry from models.pak as a single ArrayMesh, with
## its own framing camera and key light, for --grn=NAME.
##
## Owns the engine handles Sacred.Models deliberately does not: the reader
## stays a RefCounted returning typed arrays, and every ArrayMesh /
## MeshInstance3D / Camera3D in this phase is created here.
##
## The coordinate conversion is applied EXACTLY ONCE, as this node's own
## basis. It is never baked per vertex and never re-applied further down, so
## "which way round is a Sacred model" has one answer in one place. When
## Sacred.Models.coordinate_basis() cannot find the matrix in the file the
## basis is the identity and the render is whatever the retail bytes say --
## deliberately, because a rotation inserted to make the picture look upright
## would be a fudge factor, and it would make a real later finding
## unfalsifiable.
##
## The camera and the light are children of this node, so the basis above
## would otherwise rotate them along with the model and hide exactly the
## reorientation it encodes. Both are therefore placed in world space and
## divided back through this node's own transform.
##
## Lit, and back-face culled (StandardMaterial3D's default). A flat unlit
## render hides inside-out winding and mirrored handedness, which are the two
## errors this phase most needs to be able to see.
##
## Defines no _process -- main.gd._process stays the single per-frame entry
## point, exactly as SectorView does. Nothing here is per-frame anyway: the
## mesh is built once in setup().

## Camera vertical FOV, and the fraction of extra room left around the
## model's bounding sphere so nothing touches the frame edge.
const CAM_FOV := 45.0
const CAM_MARGIN := 1.15
## Viewing direction, from the model toward the camera: a three-quarter view,
## which shows a silhouette's asymmetry where a straight-on view would not.
const CAM_DIR := Vector3(0.55, 0.35, 1.0)
## Key light direction, deliberately off the camera axis so surfaces facing
## the viewer still shade and the form reads.
const LIGHT_DIR := Vector3(-0.4, -0.8, -0.45)

var vertex_count := 0
var triangle_count := 0
var basis_located := false

var _settled := false


## Builds the mesh for `entry` and returns true on success. On failure the
## node is left empty and false is returned -- the caller decides whether an
## undecodable entry is fatal, since this class has no business calling quit().
func setup(models: Sacred.Models, entry: int) -> bool:
	var b := models.coordinate_basis(entry)
	basis_located = models.last_basis_located
	transform = Transform3D(b, Vector3.ZERO)

	var m := models.mesh_arrays(entry)
	if m.is_empty():
		push_error("ModelView: entry %d has no decodable mesh" % entry)
		return false

	var pos: PackedVector3Array = m["positions"]
	var nrm: PackedVector3Array = m["normals"]
	var uv: PackedVector2Array = m["uvs"]
	var idx: PackedInt32Array = m["indices"]
	vertex_count = int(m["vertex_count"])
	triangle_count = int(m["triangle_count"])

	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = pos
	if not nrm.is_empty():
		arr[Mesh.ARRAY_NORMAL] = nrm
	if not uv.is_empty():
		arr[Mesh.ARRAY_TEX_UV] = uv
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.78, 0.74, 0.68)
	mat.roughness = 0.75
	mat.metallic = 0.0

	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = mesh
	mi.material_override = mat
	add_child(mi)

	# The AABB the camera must frame is the one the viewer sees, so it is the
	# local AABB carried through this node's basis, not the raw one.
	_frame(transform * mesh.get_aabb())
	_settled = true
	return true


## True once the surface exists. There is no streaming here, so this is
## settled immediately after a successful setup() -- the shared settle-await
## in main.gd still gets a truthful answer from the same question it asks
## SectorView.
func is_settled() -> bool:
	return _settled


## Places the camera and the key light in world space, then expresses both in
## this node's local space so the coordinate basis on `transform` does not
## drag them around with the model.
func _frame(box: AABB) -> void:
	var centre := box.get_center()
	var dir := CAM_DIR.normalized()
	var right := Vector3.UP.cross(dir).normalized()
	var up := dir.cross(right)

	# Fit the eight corners inside the frustum rather than the bounding
	# sphere: a humanoid's diagonal is far longer than its silhouette from any
	# one angle, and framing the sphere leaves the model a smudge in the
	# middle of an empty picture -- which is the one thing a capture meant for
	# spotting inside-out and mirrored geometry cannot afford.
	var tan_v := tan(deg_to_rad(CAM_FOV * 0.5))
	var tan_h := tan_v * _aspect()
	var dist := 0.0
	for i in 8:
		var c := box.get_endpoint(i) - centre
		dist = maxf(dist, c.dot(dir) + absf(c.dot(right)) / tan_h)
		dist = maxf(dist, c.dot(dir) + absf(c.dot(up)) / tan_v)
	dist = maxf(dist, 0.001) * CAM_MARGIN
	var span := maxf(box.size.length(), 0.001)
	var inv := transform.affine_inverse()

	var cam := Camera3D.new()
	cam.name = "Camera"
	cam.fov = CAM_FOV
	cam.near = maxf(dist * 0.01, 0.01)
	cam.far = dist + span * 2.0
	# A flat background and a little ambient fill. Without the fill the only
	# light is the key below, and every surface it grazes goes to near-black,
	# hiding the silhouette detail this render exists to show.
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.09, 0.10, 0.13)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.60, 0.72)
	env.ambient_light_energy = 0.65
	cam.environment = env
	cam.transform = inv * Transform3D(Basis(), centre + dir * dist).looking_at(centre, Vector3.UP)
	add_child(cam)
	cam.make_current()

	var key := DirectionalLight3D.new()
	key.name = "Key"
	key.light_energy = 1.5
	key.transform = inv * Transform3D(Basis(), centre).looking_at(
		centre + LIGHT_DIR.normalized(), Vector3.UP)
	add_child(key)


## Viewport aspect from the project's own configured size. setup() runs before
## this node is in the tree, so get_viewport() is not available yet, and the
## capture resolution is exactly what these settings say.
func _aspect() -> float:
	var w := float(ProjectSettings.get_setting("display/window/size/viewport_width", 1152))
	var h := float(ProjectSettings.get_setting("display/window/size/viewport_height", 648))
	return maxf(w, 1.0) / maxf(h, 1.0)
