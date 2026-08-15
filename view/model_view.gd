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
## Whether a clip's POSITION tracks are bound. FALSE, measured (row 760): a
## clip's position track is authored against the CLIP's parent chain, and the
## two files do not share the chain above Bip01 -- a model carries a
## coordinate-alignment bone there that the clip has no node for (row 609).
## Applying such a track to the model's Bip01 displaces everything below it,
## which is what carried a rig bodily out of its own camera framing in the
## viewer and read as splayed limbs in the streamed world. Rotation tracks are
## unaffected: a rotation is expressed in the bone's OWN space and does not
## care what sits above it.
##
## THE COST, stated rather than discovered later: any authored TRANSLATION in a
## clip is now dropped, so a lunge, a hop or a step that moved the body will
## play in place. Retail's own root motion, if it has any, is not reproduced.
## The upgrade path is per-model alignment-bone compensation (option (b) of row
## 760), which needs that bone identified per model rather than only for the
## one entry row 609 measured.
const BIND_POSITION_TRACKS := false

const LIGHT_DIR := Vector3(-0.4, -0.8, -0.45)
## Key light strength, shared with main.gd's streamed-world rig light so a
## creature standing in the world is lit exactly as --grn= previews it.
const KEY_ENERGY := 1.5

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
##
## REMOVED HERE: the `rest_eq_bind` assertion, which was CIRCULAR and is not
## replaced by a weaker one. It compared a bone's Skeleton3D global rest against
## its composed bind transform, but both operands were chain-compositions of the
## SAME stored local rests, and the Skin bind was itself defined as the inverse
## of one of them -- so the product was the identity by construction, for any
## bone data whatsoever, correct or not. It reported true, including on a render
## a human rejected as visibly wrong, and it would have reported true on
## arbitrary garbage. A check that cannot fail proves nothing, and leaving it in
## was worse than having nothing: it advertised a guarantee it never carried.
##
## The skeleton and skin layer is therefore CURRENTLY UNVALIDATED. Validating it
## needs an oracle independent of our own decode -- an external renderer's bone
## positions, or a posed frame compared against retail -- not another
## rearrangement of the same stored numbers.

var _settled := false
var _skeleton: Skeleton3D = null
var _skin: Skin = null
var _weights: Array[Dictionary] = []
var _local_to_bind: Array[PackedInt32Array] = []

## Animation facts, printed by main.gd's --anim= route. anim_bound counts
## clip bones whose sanitized name resolved to a real Skeleton3D bone via
## find_bone() (05-12 Task 1); anim_tracks counts the position/rotation
## tracks actually added to the built Animation (fewer than 2*bound, since
## D-06 omits the clip's own root-bone track(s)); anim_unbound_names carries
## the STORED clip-side name (or "" when the clip's own two-hop chain never
## resolved a name at all) for every bone build_animation() could not match.
var _anim_player: AnimationPlayer = null
var _built_anim: Animation = null
var _anim_frozen := false
var anim_bound := 0
var anim_tracks := 0
var anim_length := 0.0
var anim_unbound_names := PackedStringArray()


## Builds the mesh for `entry` and returns true on success. On failure the
## node is left empty and false is returned -- the caller decides whether an
## undecodable entry is fatal, since this class has no business calling quit().
##
## `frame_camera` (default true, so --grn= is byte-for-byte unchanged):
## suppresses only the final _frame() call below when false -- a caller that
## places this rig in the streamed world (Phase 4's player_view.gd) has its
## own IsoCamera already framing the scene and does not want a second,
## competing Camera3D/DirectionalLight3D built.
## texture.pak, for the model skin. Optional: a caller that only wants
## geometry (grnwalk, the parity dumps) leaves it null and gets clay.
var _texture_pak: Sacred.Pak = null
## Set by setup(): how many textures the .GRN named, and whether one was
## actually applied. Callers report these rather than assuming a skin landed.
var textures_named := 0
var textured := false

## How many surfaces setup() built: one per material group where the groups
## account for every triangle, otherwise one.
var surfaces := 0
## How many of those surfaces carry a real image rather than clay.
var textured_surfaces := 0

func set_texture_pak(pak: Sacred.Pak) -> void:
	_texture_pak = pak

## The material for one draw batch. `slot` is a 0-based index into
## Models.texture_names(), or -1 for "no texture known". Clay whenever the
## slot is unset, the pak was not supplied, the name does not resolve, or the
## image fails to decode -- there is no fallback to another slot's image,
## because a confidently wrong skin is worse than no skin.
func _skin_material(models: Sacred.Models, entry: int, slot: int) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.78, 0.74, 0.68)
	mat.roughness = 0.75
	mat.metallic = 0.0
	if slot < 0 or _texture_pak == null:
		return mat
	var names := models.texture_names(entry)
	if slot >= names.size():
		return mat
	var tid := Sacred.TextureFormat.find_model_texture(_texture_pak, names[slot])
	if tid < 0:
		return mat
	var img := Sacred.TextureFormat.decode_texture(_texture_pak, tid, true)
	if img == null:
		return mat
	mat.albedo_texture = ImageTexture.create_from_image(img)
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	mat.albedo_color = Color.WHITE
	textured_surfaces += 1
	return mat

func setup(models: Sacred.Models, entry: int, frame_camera: bool = true) -> bool:
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
	if not _build_rig(models, entry):
		return false
	if not _fill_weights(models, entry, m, arr):
		# _build_rig succeeded, so _skeleton exists but has not been add_child'd
		# yet -- that only happens on the success path below. Nothing else will
		# free it.
		_discard_rig()
		return false

	# ONE SURFACE PER DRAW BATCH, so a model with several skins gets them.
	#
	# models.material_groups() reads the ModelSection's {mesh, material,
	# triangles} draw batches. Their counts sum to the entry's own triangle
	# total exactly -- that is the check that the fields are what they look
	# like, and a wrong field partitions nothing.
	#
	# THE GROUP'S MESH NUMBER IS NOT THIS READER'S. Measured: GLADIATOR's
	# groups total {0:442, 1:868, 2:385} per mesh while mesh_arrays() lays the
	# submeshes out as {0:868, 1:385, 2:442}, and WALDELFE_DARK permutes
	# differently again. Slicing the concatenated index array in group order
	# would therefore have skinned the wrong triangles -- confidently, and
	# invisibly to any check that only compared totals.
	#
	# The two orderings are reconciled by TRIANGLE COUNT, and only when that is
	# unambiguous: if two submeshes have the same face count the mapping is not
	# determined and the split is refused. Within one submesh the groups are
	# taken in file order, which is assumed rather than measured -- so the worst
	# a residual error can do is swap two batches of the SAME submesh.
	textures_named = models.texture_names(entry).size()
	textured_surfaces = 0
	var groups: Array[Dictionary] = models.material_groups(entry)
	var vmesh: PackedInt32Array = m["vertex_mesh"]

	# this reader's own submesh layout: face count and first triangle
	var port_faces := {}
	var port_start := {}
	var port_order: Array[int] = []
	for t in idx.size() / 3:
		var pm: int = vmesh[idx[t * 3]]
		if not port_faces.has(pm):
			port_faces[pm] = 0
			port_start[pm] = t
			port_order.append(pm)
		port_faces[pm] = int(port_faces[pm]) + 1

	# group triangles per GROUP mesh number, and the count -> port mesh map
	var g_sum := {}
	for g in groups:
		g_sum[g["mesh"]] = int(g_sum.get(g["mesh"], 0)) + int(g["triangles"])
	var by_count := {}
	var ambiguous := false
	for pm in port_faces:
		var c: int = port_faces[pm]
		if by_count.has(c):
			ambiguous = true
		by_count[c] = pm
	var g2p := {}
	for gm in g_sum:
		var c2: int = g_sum[gm]
		if by_count.has(c2):
			g2p[gm] = by_count[c2]
	var split := groups.size() > 1 and not ambiguous and g2p.size() == g_sum.size()

	var mesh := ArrayMesh.new()
	var mats: Array[StandardMaterial3D] = []
	if split:
		var at := {}
		for pm2 in port_order:
			at[pm2] = int(port_start[pm2]) * 3
		for pm3 in port_order:
			for g2 in groups:
				if g2p.get(g2["mesh"], -1) != pm3:
					continue
				var take := int(g2["triangles"]) * 3
				var from: int = at[pm3]
				if from + take > idx.size():
					split = false
					break
				var sub := arr.duplicate()
				sub[Mesh.ARRAY_INDEX] = idx.slice(from, from + take)
				mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sub)
				mats.append(_skin_material(models, entry, int(g2["material"])))
				at[pm3] = from + take
			if not split:
				break
	if not split:
		mesh = ArrayMesh.new()
		mats.clear()
		textured_surfaces = 0
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		mats.append(_skin_material(models, entry, 0 if textures_named == 1 else -1))
	surfaces = mesh.get_surface_count()
	textured = textured_surfaces > 0

	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = mesh
	for i in mats.size():
		mi.set_surface_override_material(i, mats[i])
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
	if frame_camera:
		_frame(transform * mesh.get_aabb())
	_settled = true
	return true


## Rig facts for `entry` without building a mesh, a camera or a light: the same
## Skeleton3D and Skin the render uses, checked the same way.
##
## Exists so verify.gd's parity fact lines come from the PRODUCTION rig builder
## rather than a second implementation written for the harness -- a harness
## that reimplements the thing it tests can only ever agree with itself.
## Returns an empty Dictionary if the rig could not be built.
func rig_facts(models: Sacred.Models, entry: int) -> Dictionary:
	if not _build_rig(models, entry):
		return {}
	var out := {
		"count": bone_count, "roots": bone_roots, "binds": bind_count,
		"sanitised": bone_sanitised,
	}
	# The Skeleton3D was never added to a tree, so nothing else will free it.
	_discard_rig()
	return out


## Frees a Skeleton3D built by _build_rig() but never handed to the scene tree,
## and clears every field that referred to it.
##
## Every _build_rig() failure path after the Skeleton3D exists, and every caller
## that abandons a successfully-built rig without add_child()-ing it, must come
## through here: a Node created with .new() and never parented is never freed by
## anything else, which is precisely the orphan Godot's own orphan-node counter
## exists to surface.
##
## Safe to call when no rig was built -- the null check is the whole guard.
func _discard_rig() -> void:
	if _skeleton != null:
		_skeleton.free()
		_skeleton = null
	_skin = null


## Builds the Skeleton3D and the Skin for `entry`, checks rest against bind, and
## populates the bone_* / rest_* fields. Returns true on success, INCLUDING the
## case where the entry carries no skeleton at all -- an unskinned model is not
## a malformed one, and it renders exactly as it did before this existed.
## Returns false only when a skeleton is present but unusable, which is loud on
## purpose: a silently-unskinned render of a skinned model looks entirely
## plausible.
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
func _build_rig(models: Sacred.Models, entry: int) -> bool:
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
		# needs uniqueness for get_bone_by_name to mean anything. Names are real
		# since 05-10 (commit a415ac4): Sacred.Models.bone_names() resolves them
		# via the two-hop DataExtension chain. The Bone_%d fallback below covers
		# any entry whose name record is genuinely empty.
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
	_weights = models.mesh_weights(entry)
	if _weights.is_empty():
		push_error("ModelView: entry %d has bones but no readable weight blocks" % entry)
		_discard_rig()
		return false
	# Space 4 -> space 3, one map per Mesh node.
	_local_to_bind = []
	for w: Dictionary in _weights:
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
		_local_to_bind.append(lt)
	bind_count = _skin.get_bind_count()
	if bind_count == 0:
		push_error("ModelView: entry %d has bones but nothing is weighted to any of them" % entry)
		_discard_rig()
		return false

	# The rest-equals-bind assertion stood here and has been REMOVED, not
	# weakened: it was circular and could not fail. See the note at the top of
	# this file. Nothing replaces it, because nothing available from the file
	# alone would be any less circular -- the skeleton and skin layer is
	# knowingly unvalidated until an external oracle exists.
	return true


## Fills `arr`'s ARRAY_BONES / ARRAY_WEIGHTS slots from the maps _build_rig
## produced. No-op returning true when the entry has no skeleton.
func _fill_weights(models: Sacred.Models, entry: int, m: Dictionary, arr: Array) -> bool:
	if _skeleton == null:
		return true
	if _weights.size() != int(m["meshes"]):
		push_error("ModelView: entry %d has %d meshes but %d weight blocks" % [
			entry, int(m["meshes"]), _weights.size()])
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
		var w: Dictionary = _weights[mi]
		if src < 0 or src >= int(w["count"]):
			push_error("ModelView: entry %d vertex %d came from source position %d, outside mesh %d's %d weight records" % [
				entry, v, src, mi, int(w["count"])])
			return false
		var wb: PackedInt32Array = w["bones"]
		var ww: PackedFloat32Array = w["weights"]
		var lt: PackedInt32Array = _local_to_bind[mi]
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


# ---------------------------------------------------------------------
# Animation (05-12). Binds a decoded kind=65 clip to THIS rig's Skeleton3D
# BY NAME ONLY -- Sacred.Models.clip_track_bone() resolves a clip record to
# a clip-file bone by DIRECTORY POSITION (within that one file), but the
# clip-file bone is then matched to a MODEL Skeleton3D bone here, in this
# function, exclusively by comparing sanitized name strings. No cross-file
# index join exists anywhere in this section.

## Builds an Animation for `clip_entry`, bound to this rig's Skeleton3D bones
## by name. Returns {"animation": Animation, "bound": int, "tracks": int,
## "unbound_names": PackedStringArray}; "animation" is null and the rest
## zeroed/empty when no skeleton has been built yet, the clip has no
## decodable records, or clip_track_bone() refuses (record/bone count
## mismatch -- see its own doc comment).
##
## A clip bone's stored name goes through the IDENTICAL ':'/'/' -> '_'
## sanitizing substitution _build_rig() applies to a model bone's stored
## name before either side is compared -- the two names must go through the
## same transform to mean the same string. Unlike _build_rig(), no
## Bone_%d/dedup-suffix fallback is applied here: an empty or duplicate
## clip-side name simply fails find_bone() and is recorded unbound (D-19 --
## nothing invented to make a track bind).
##
## D-06: a clip bone whose OWN parent_effective is -1 (the clip's structural
## root) still counts toward `bound` when its name resolves, but gets NO
## position/rotation track -- PlayerView.update() writes this rig's root
## bone's pose every tick from the sim's cell, and a placement track on the
## same bone would fight it every frame.
##
## `falsify` (05-12 Task 2 counterfactual, "" in normal operation) deliberately
## breaks the name join to prove it is load-bearing: "offset" resolves to
## find_bone(name) PLUS ONE instead of the exact match; "drop" skips the name
## lookup entirely and binds every track to skeleton bone 0. Both are for
## --anim-falsify= only and must never run outside that flag.
func build_animation(models: Sacred.Models, clip_entry: int, falsify: String = "") -> Dictionary:
	var fail := {"animation": null, "bound": 0, "tracks": 0, "unbound_names": PackedStringArray()}
	if _skeleton == null:
		return fail
	var c := models.clip(clip_entry)
	var track_bone := models.clip_track_bone(clip_entry)
	var clip_names := models.clip_bone_names(clip_entry)
	var clip_bone_list := models.clip_bones(clip_entry)
	if c.is_empty() or track_bone.is_empty() or clip_names.is_empty() or clip_bone_list.is_empty():
		return fail

	var records: Array = c["records"]
	var anim := Animation.new()
	anim.length = maxf(float(c["length"]), 0.001)
	# ponytail: every clip loops uniformly; the format has not yielded a
	# decoded per-clip loop flag yet, so LOOP_LINEAR is applied to all of
	# them rather than guessed per name. Upgrade when that field is found.
	anim.loop_mode = Animation.LOOP_LINEAR

	var bound := 0
	var tracks := 0
	var unbound := PackedStringArray()
	var bone_count := _skeleton.get_bone_count()
	for ri in records.size():
		var bi: int = track_bone[ri]
		var stored: String = clip_names[bi] if bi < clip_names.size() else ""
		var nm := stored.replace(":", "_").replace("/", "_")
		var skel_idx := _skeleton.find_bone(nm) if nm != "" else -1
		if falsify == "drop":
			skel_idx = 0 if bone_count > 0 else -1
		elif falsify == "offset" and skel_idx != -1 and bone_count > 0:
			skel_idx = (skel_idx + 1) % bone_count
		if skel_idx == -1:
			unbound.append(stored)
			continue
		nm = _skeleton.get_bone_name(skel_idx)
		bound += 1
		if int(clip_bone_list[bi]["parent_effective"]) == -1:
			continue
		var r: Dictionary = records[ri]
		var path := NodePath("%s:%s" % [_skeleton.name, nm])
		var times_pos: PackedFloat32Array = r["times_pos"]
		var positions: PackedVector3Array = r["positions"]
		if times_pos.size() > 0 and BIND_POSITION_TRACKS:
			var pt := anim.add_track(Animation.TYPE_POSITION_3D)
			anim.track_set_path(pt, path)
			for i in times_pos.size():
				anim.position_track_insert_key(pt, times_pos[i], positions[i])
			tracks += 1
		var times_rot: PackedFloat32Array = r["times_rot"]
		var rotations: Array = r["rotations"]
		if times_rot.size() > 0:
			var rt := anim.add_track(Animation.TYPE_ROTATION_3D)
			anim.track_set_path(rt, path)
			# RETARGET, do not transplant (row 766). A clip's key is expressed
			# against the CLIP's own rest, and the clip and the model do not
			# share one: row 739 measured their local rests agreeing on only 47
			# of 60 bones, worst case 6.74. Writing the key straight onto the
			# model's bone therefore replaces that bone's rest orientation with a
			# foreign one, and because a parent's error is inherited by its whole
			# limb the displacement accumulates outward -- measured at 84.71
			# units on a rig 110 units wide, AT t=0, where the pose is supposed
			# to BE the bind pose.
			#
			# So take the clip's motion RELATIVE to the clip's own rest and
			# replay it on the model's rest:
			#
			#   pose = model_rest * (clip_rest^-1 * key)
			#
			# At t=0 a clip's first key is its rest (measured: 5855 of 5916
			# unambiguous records), so the delta is the identity and the pose is
			# exactly the bind pose -- the property that was violated before and
			# that anim_check.gd now pins.
			var clip_rest: Quaternion = ((clip_bone_list[bi]["rest"] as Transform3D)
				.basis.get_rotation_quaternion()).normalized()
			var model_rest: Quaternion = (_skeleton.get_bone_rest(skel_idx)
				.basis.get_rotation_quaternion()).normalized()
			var retarget := model_rest * clip_rest.inverse()
			for i in times_rot.size():
				# clip() only checks unit-length to within ANIM_QUAT_EPS
				# (0.07 -- a decode-validity discriminator, not a precision
				# claim). Godot's own rotation-track interpolation demands
				# an exact unit quaternion and logs an ERROR per sampled
				# frame otherwise; normalized() re-scales the SAME
				# already-accepted rotation rather than changing what was
				# decoded or loosening what clip() itself checks.
				anim.rotation_track_insert_key(rt, times_rot[i],
					(retarget * (rotations[i] as Quaternion).normalized()).normalized())
			tracks += 1

	return {"animation": anim, "bound": bound, "tracks": tracks, "unbound_names": unbound}


## Plays `clip_entry` on this rig through a real AnimationPlayer /
## AnimationLibrary / Animation triad (D-04: Godot's own playback owns
## sampling here, never a hand-rolled per-frame writer -- this file defines
## no _process). The AnimationPlayer is created once and reused; each call
## rebuilds the Animation via build_animation() and (re)registers it under
## the clip's own entry name in the player's default ("") library. Updates
## anim_bound/anim_tracks/anim_unbound_names as a side effect, for
## main.gd's --anim= fact lines. Returns true iff at least one track bound
## and playback started.
func play_clip(models: Sacred.Models, clip_entry: int, falsify: String = "") -> bool:
	if _skeleton == null:
		return false
	var built := build_animation(models, clip_entry, falsify)
	var anim: Animation = built["animation"]
	anim_bound = int(built["bound"])
	anim_tracks = int(built["tracks"])
	anim_unbound_names = built["unbound_names"]
	if anim == null or anim_tracks == 0:
		anim_length = 0.0
		return false
	anim_length = anim.length
	if _anim_player == null:
		_anim_player = AnimationPlayer.new()
		_anim_player.name = "AnimationPlayer"
		add_child(_anim_player)
	var lib: AnimationLibrary = _anim_player.get_animation_library("") if _anim_player.has_animation_library("") else null
	if lib == null:
		lib = AnimationLibrary.new()
		_anim_player.add_animation_library("", lib)
	var clip_name := models.entry_name(clip_entry)
	if lib.has_animation(clip_name):
		lib.remove_animation(clip_name)
	lib.add_animation(clip_name, anim)
	_built_anim = anim
	_anim_player.play(clip_name)
	return true


## The Skeleton3D's CURRENT pose transform for `bone_name`, sanitized the
## same way _build_rig() sanitizes a stored model-bone name. A probe for
## main.gd's headless --anim= verify (confirms sampled poses actually move
## between two advance() calls) -- never called from a per-frame path.
## Transform3D.IDENTITY if this rig has no such bone.
func sample_bone_pose(bone_name: String) -> Transform3D:
	if _skeleton == null:
		return Transform3D.IDENTITY
	# THE GUARD (row 784). Reading a pose while the mixer is still advancing
	# yields whatever frame the clip drifted to, not the pose the caller asked
	# for -- and it does so silently, which is exactly how four rows of findings
	# were built on an artefact. freeze_anim() is the sanctioned setup.
	if _anim_player != null and _anim_player.is_playing() and not anim_frozen:
		push_error("ModelView.sample_bone_pose: the AnimationPlayer is still advancing. Call freeze_anim(t) first -- a pose read against a running player is a read of some later frame (autoresearch row 784).")
		return Transform3D.IDENTITY
	var nm := bone_name.replace(":", "_").replace("/", "_")
	var idx := _skeleton.find_bone(nm)
	if idx == -1:
		return Transform3D.IDENTITY
	return _skeleton.get_bone_pose(idx)


## Seeks the live AnimationPlayer to an explicit time and immediately updates
## the Skeleton3D pose (update=true) so a caller can sample_bone_pose() at a
## chosen time without waiting on _process -- this file defines none (D-04).
## A no-op when play_clip() has not been called yet.
func seek_anim(t: float) -> void:
	if _anim_player != null:
		# NOT a freeze. The player keeps advancing, which is what --creatures
		# wants (it seeks to desynchronise loops). Anything that then READS the
		# posed skeleton must use freeze_anim() instead -- see row 784.
		_anim_frozen = false
		_anim_player.seek(t, true)


## Freezes playback and parks the clip at `t`. THE ONLY sanctioned setup for
## reading a posed skeleton.
##
## WHY THIS EXISTS (autoresearch row 784). play_clip() starts PLAYBACK. A
## measurement that seeks to 0 and then reads bone poses on the next frame is
## reading frame 1, because the AnimationMixer advanced ~16ms in between. Four
## rows of "bind defect" findings -- 43 meshes off bind, a wolf model defect
## proven across five clips, nine surviving suspects -- were all that artefact,
## and every one had to be withdrawn. Frozen, the same rig measures 0.0109
## worst-case where running it measured 0.5259.
##
## The pose still lands one frame later (the mixer writes during the frame), so
## a caller reads on the frame AFTER this call -- but with speed_scale at 0 that
## frame is still `t`.
func freeze_anim(t: float) -> void:
	if _anim_player == null:
		return
	_anim_player.speed_scale = 0.0
	_anim_player.seek(t, true)
	_anim_frozen = true


## True once freeze_anim() has parked the clip and nothing has un-parked it.
## Read by sample_bone_pose()'s guard and by anim_freeze_check.
var anim_frozen: bool:
	get:
		return _anim_frozen and _anim_player != null and is_equal_approx(_anim_player.speed_scale, 0.0)


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
	key.light_energy = KEY_ENERGY
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

## NOT CALLED. Retained as measured data, not as dead code to revive blindly --
## see row 792 for why neutralising this bone is the wrong lever.
##
## The Granny bone index of a COORDINATE-ALIGNMENT bone, or -1.
##
## Shape: an intermediate bone sitting between `__Root` and the rig's root
## `Bip01`, carrying a rotation that no clip drives (no clip has a node for it,
## row 609). 68 of 124 creature meshes hang Bip01 straight off __Root; 29 have
## an intermediate, and on BEAR, WOLF, RABBIT and RED_DEER that intermediate is
## `Root` with an IDENTITY rotation, so it changes nothing and those meshes
## render correctly. Seven carry `Root` at +90 about Z -- the whole wood/dark
## elf family, Waldelfe_dark, dryadin_01/02, DARKELVENPC/2, DarkElve2b and
## DarkElve_slave -- and FLIGHT_LIZARD carries +90 about X.
##
## WHY IT IS NEUTRALISED (row 790, and this is a correction of row 771). The
## rotation IS in the file, and row 771 concluded from that alone that
## canonical-first meant reproducing it. Retail says otherwise: captured beside
## its own wolves, retail draws this character as a full-width humanoid facing
## the camera, while the port drew a thin edge-on sliver -- the peers' chain
## nets -90 about Z and the elf's nets 0, and that 90 degrees is the entire
## difference. Reproducing retail's behaviour is the rule; reproducing our own
## composition of authored data that retail evidently does not compose is not.
##
## Deliberately narrow: it fires only for an intermediate whose parent is
## `__Root` and whose child is the Bip01 root, so StachelalbaufBlutschrecke
## (Bone01 at -104 under `Haupt-Bone`) is left alone -- that is a different
## shape and has no oracle behind it yet.
func _align_bone(bl: Array[Dictionary]) -> int:
	var names := PackedStringArray()
	for b in bl:
		names.append((b["name"] as PackedByteArray).get_string_from_utf8().strip_edges())
	var bip := -1
	for i in names.size():
		if names[i].begins_with("Bip01") and not names[i].contains(" "):
			bip = i
			break
	if bip < 0:
		return -1
	var p: int = bl[bip]["parent_effective"]
	if p < 0 or p >= names.size() or names[p] == "__Root":
		return -1
	var gp: int = bl[p]["parent_effective"]
	if gp < 0 or gp >= names.size() or names[gp] != "__Root":
		return -1
	# An identity intermediate needs no correction and reports as none, so the
	# meshes that already render correctly take exactly the path they took
	# before this existed.
	var q := ((bl[p]["rest"] as Transform3D).basis.get_rotation_quaternion()).normalized()
	return -1 if absf(q.w) > 0.9999 else p
