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
## Skeleton facts, printed by main.gd. bone_count is the Skeleton3D bone count,
## bind_count the Skin bind-array length (a bone nothing is weighted to is NOT
## bound, so these differ legitimately), bone_roots the number of parentless
## bones, bone_sanitised the number whose stored name could not be used as-is.
var bone_count := 0
var bone_roots := 0
var bind_count := 0
var bone_sanitised := 0

var _settled := false
var _skeleton: Skeleton3D = null
var _skin: Skin = null


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

	# Must precede add_surface_from_arrays: ARRAY_BONES/ARRAY_WEIGHTS are
	# surface arrays, not something attachable afterwards.
	if not _build_skin(models, entry, m, arr):
		return false

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
	if _skeleton != null:
		# MeshInstance3D under the Skeleton3D, with `skeleton` as the relative
		# NodePath ".." -- the conventional layout, and the one that does not
		# depend on this node's own name. The Skeleton3D itself sits at identity
		# under ModelView, so the coordinate basis on ModelView.transform still
		# applies exactly once, to the whole rig, exactly as before.
		add_child(_skeleton)
		_skeleton.add_child(mi)
		mi.skeleton = NodePath("..")
		mi.skin = _skin
	else:
		add_child(mi)

	# The AABB the camera must frame is the one the viewer sees, so it is the
	# local AABB carried through this node's basis, not the raw one.
	_frame(transform * mesh.get_aabb())
	_settled = true
	return true


## Builds the Skeleton3D and Skin for `entry` and fills `arr`'s ARRAY_BONES /
## ARRAY_WEIGHTS slots. Returns true on success, INCLUDING the case where the
## entry carries no skeleton at all -- an unskinned model is not a malformed
## one, and it renders exactly as it did before this existed. Returns false
## only when a skeleton is present but unusable, which is loud on purpose: a
## silently-unskinned render of a skinned model looks entirely plausible.
##
## THREE INDEX SPACES, and none of them is assumed equal to another:
##
##   1. GRANNY FILE ORDER      -- what Sacred.Models.bones() returns
##   2. SKELETON3D BONE INDEX  -- what add_bone() hands back; produced by the
##                                topological sort below, because Skeleton3D
##                                requires every parent index to be strictly
##                                less than its child's
##   3. SKIN BIND-ARRAY POSITION -- the order add_bind() was called in
##
## plus a fourth, per-Mesh-node bone index space that the weight records use
## and Sacred.Models.mesh_weights().bone_map resolves into space 1.
##
## ARRAY_BONES is filled from space 3. This is the single most common way to
## get a plausible-looking wrong deformation: Godot indexes ARRAY_BONES into
## the SKIN's bind array, not into the Skeleton3D, and the two coincide only
## when every bone happens to be bound in skeleton order -- which is exactly
## what does NOT happen here, since binds are added in mesh-local order and
## only for bones something is actually weighted to.
func _build_skin(models: Sacred.Models, entry: int, m: Dictionary, arr: Array) -> bool:
	var bl := models.bones(entry)
	if bl.is_empty():
		return true

	var n := bl.size()
	var binds := models.bind_poses(entry)
	if binds.size() != n:
		push_error("ModelView: entry %d has %d bones but %d bind poses" % [entry, n, binds.size()])
		return false

	# Topological sort into Skeleton3D order. The measured corpus is already in
	# parent-before-child order, so this is a no-op on it -- but "already
	# sorted" is a property of three sampled files, not of the format, and an
	# out-of-order file would otherwise hit Skeleton3D's parent<child rule as an
	# engine error rather than as a decode failure. The sort is stable in file
	# order, so on the sampled corpus space 1 and space 2 do coincide; the maps
	# below are still used everywhere rather than that coincidence.
	var granny_to_skel := PackedInt32Array()
	granny_to_skel.resize(n)
	granny_to_skel.fill(-1)
	var order: Array[int] = []
	var progress := true
	while progress and order.size() < n:
		progress = false
		for g in n:
			if granny_to_skel[g] != -1:
				continue
			var p: int = bl[g]["parent_effective"]
			if p != -1 and granny_to_skel[p] == -1:
				continue
			granny_to_skel[g] = order.size()
			order.append(g)
			progress = true
	if order.size() != n:
		push_error("ModelView: entry %d bone graph is not a forest -- %d of %d bones sort" % [
			entry, order.size(), n])
		return false

	_skeleton = Skeleton3D.new()
	_skeleton.name = "Skeleton"
	var used := {}
	bone_roots = 0
	bone_sanitised = 0
	for g in order:
		var raw: PackedByteArray = bl[g]["name"]
		var stored := raw.get_string_from_utf8().strip_edges()
		# Godot reserves ':' and '/' in bone names, rejects the empty name, and
		# needs uniqueness for get_bone_by_name to mean anything. Every stored
		# name in this format is empty (the 68-byte bone record has no name
		# field), so in practice every name is generated -- see
		# Sacred.Models.bones()'s `name` documentation for why the real strings
		# in the file are deliberately not guessed at.
		var nm := stored.replace(":", "_").replace("/", "_")
		if nm.is_empty():
			nm = "Bone_%d" % g
		while used.has(nm):
			nm = "%s_%d" % [nm, g]
		used[nm] = true
		if nm != stored:
			bone_sanitised += 1
		_skeleton.add_bone(nm)
		var s := granny_to_skel[g]
		var p: int = bl[g]["parent_effective"]
		if p == -1:
			bone_roots += 1
		else:
			_skeleton.set_bone_parent(s, granny_to_skel[p])
		_skeleton.set_bone_rest(s, bl[g]["rest"])
	# A fresh bone's POSE is not its rest -- it defaults to the identity, which
	# collapses every bone onto the origin and produces a crumpled model that
	# still renders. There is no animation in this plan, so the pose is the
	# rest; letting the engine derive it keeps rest and pose using the same
	# decomposition rather than a hand-rolled one.
	_skeleton.reset_bone_poses()
	bone_count = n

	# One bind per bone something is actually weighted to, added in mesh-local
	# order, which is how space 3 gets its ordering.
	_skin = Skin.new()
	var skel_to_bind := PackedInt32Array()
	skel_to_bind.resize(n)
	skel_to_bind.fill(-1)
	var weights := models.mesh_weights(entry)
	if weights.size() != int(m["meshes"]):
		push_error("ModelView: entry %d has %d meshes but %d weight blocks" % [
			entry, int(m["meshes"]), weights.size()])
		return false
	# Space 4 -> space 3, one map per Mesh node.
	var local_to_bind: Array[PackedInt32Array] = []
	for w: Dictionary in weights:
		var bone_map: PackedInt32Array = w["bone_map"]
		var lt := PackedInt32Array()
		lt.resize(bone_map.size())
		for l in bone_map.size():
			var g := bone_map[l]
			var s := granny_to_skel[g]
			if skel_to_bind[s] == -1:
				skel_to_bind[s] = _skin.get_bind_count()
				# The bind pose is the INVERSE of the bone's world bind
				# transform: it takes a vertex from model space into the bone's
				# own space, so the bone's pose can then put it back.
				_skin.add_bind(s, binds[g].affine_inverse())
			lt[l] = skel_to_bind[s]
		local_to_bind.append(lt)
	bind_count = _skin.get_bind_count()
	if bind_count == 0:
		push_error("ModelView: entry %d has bones but nothing is weighted to any of them" % entry)
		return false

	var vsrc: PackedInt32Array = m["vertex_source"]
	var vmesh: PackedInt32Array = m["vertex_mesh"]
	if vsrc.size() != vertex_count or vmesh.size() != vertex_count:
		push_error("ModelView: entry %d vertex provenance is %d/%d for %d vertices" % [
			entry, vsrc.size(), vmesh.size(), vertex_count])
		return false
	var slots := Sacred.Models.WEIGHT_SLOTS
	var ab := PackedInt32Array()
	var aw := PackedFloat32Array()
	ab.resize(vertex_count * slots)
	aw.resize(vertex_count * slots)
	for v in vertex_count:
		var mi := vmesh[v]
		var src := vsrc[v]
		var w: Dictionary = weights[mi]
		if src < 0 or src >= int(w["count"]):
			push_error("ModelView: entry %d vertex %d came from source position %d, outside mesh %d's %d weight records" % [
				entry, v, src, mi, int(w["count"])])
			return false
		var wb: PackedInt32Array = w["bones"]
		var ww: PackedFloat32Array = w["weights"]
		var lt: PackedInt32Array = local_to_bind[mi]
		for s in slots:
			var l := wb[src * slots + s]
			if l < 0 or l >= lt.size():
				push_error("ModelView: entry %d vertex %d slot %d names mesh-local bone %d of %d" % [
					entry, v, s, l, lt.size()])
				return false
			ab[v * slots + s] = lt[l]
			# Stored verbatim. Renormalising here would hide a decode error by
			# making any set of weights sum to 1, which is the check that the
			# reader already applies to the bytes as an actual test.
			aw[v * slots + s] = ww[src * slots + s]
	arr[Mesh.ARRAY_BONES] = ab
	arr[Mesh.ARRAY_WEIGHTS] = aw
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
