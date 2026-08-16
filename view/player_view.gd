class_name PlayerView
extends RefCounted
## Draws the real posed player-character mesh in the streamed world, sorted
## against the painted object quads by the same rule Phase 2/3 established
## (SectorView.ground_depth / SectorView.SORTCUBE_PX) -- no capsule
## placeholder (the allowance for one has expired).
##
## RefCounted, following cursor.gd's shape (plan 04-03 Task 1): it lives in
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

## FALLBACK ONLY. main.gd passes the body mesh for its START_CLASS
## (main.gd's CLASS_MODEL), so the drawn hero follows the class whose
## StartPosition the run spawns at instead of being fixed here. This default
## survives for the call sites that want *a* hero rig without caring which --
## the crowd harness and the parity dumps -- and for a class the map has no
## mesh for, where drawing the wrong body beats drawing none.
##
## ponytail: still no class-SELECTION system; START_CLASS is a constant. The
## upgrade path is a menu that writes it, not a change here.
const MODEL_NAME := "GLADIATOR.GRN"

## The built rig, parented into the tree by the caller (main.gd), or null
## when the model failed to resolve or build -- drawing nothing, matching
## RetailCursor.apply's non-fatal degrade, never a capsule fallback.
var node: Node3D = null
var model_index := -1
## The direction this body FACES in its own rest pose, as an angle in the rig's
## horizontal plane. NAN when the body is not a biped and facing must be
## refused rather than guessed. See rest_yaw().
var rest_yaw_rad := NAN
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
var _root_rest_rotations: Array[Quaternion] = []
## Reference rig height in model units -- see the scale block in setup().
const REF_HEIGHT := 73.0
## Preloaded by PATH rather than referenced by class_name -- see the note at
## the top of rig_placement.gd.
const RigPlacementScript := preload("res://view/rig_placement.gd")
## Applies the placement after the animation; null when the rig has no skeleton.
var _placement: SkeletonModifier3D = null


## Resolves MODEL_NAME through Sacred.Models.index_of (never a hardcoded
## entry number) and builds it via ModelView, framing suppressed -- the
## streamed world already has its own IsoCamera and does not want a second,
## competing Camera3D/DirectionalLight3D. Non-fatal on any failure.
## `model_name` defaults to the hero, so every existing call site is unchanged.
## Creatures pass their own mesh, resolved through the spawn chain (creature id
## -> Items.name_of -> this): the placement, scaling and depth-sort rules above
## are identical for a wolf and for the hero, and a second class restating them
## would be a rival spelling of the same invariants.
## `texture_pak` is optional and is texture.pak: pass it and a single-texture
## model gets its skin, omit it and the rig is clay. Optional rather than
## required so the parity dumps and grnwalk, which want geometry only, are
## unaffected.
func _init(models: Sacred.Models, model_name: String = MODEL_NAME,
		texture_pak: Sacred.Pak = null) -> void:
	model_index = models.index_of(model_name)
	if model_index < 0:
		push_warning("PlayerView: %s not found in models.pak -- drawing nothing" % model_name)
		return

	var mv := ModelView.new()
	mv.set_texture_pak(texture_pak)
	if not mv.setup(models, model_index, false):
		push_warning("PlayerView: %s failed to build -- drawing nothing" % model_name)
		mv.free()
		return

	_skeleton = mv.get_node_or_null("Skeleton")
	_mesh = mv.get_node_or_null("Skeleton/Mesh") if _skeleton != null else mv.get_node_or_null("Mesh")
	if _mesh == null or _mesh.mesh == null:
		push_warning("PlayerView: %s built with no Mesh node -- drawing nothing" % model_name)
		mv.free()
		return

	vertex_count = mv.vertex_count
	triangle_count = mv.triangle_count
	rest_yaw_rad = rest_yaw(models, model_index)

	# Scale so the rig's bounding box height equals SectorView's existing
	# character-proxy constant (SORTCUBE_PX) -- borrowed, not restated, per
	# plan 04-03 Task 1. ponytail: no retail capture has measured an
	# actual character height yet; the ceiling is "reads at marker-cube
	# scale, not the model's own untouched size", and the upgrade path is a
	# retail capture through the same autopilot.c route that recovered
	# IsoCamera's ZOOM_SCALES.
	# ONE GLOBAL SCALE (row 797). This DIVIDED by the rig's own AABB height
	# until now, which forced every creature to the same drawn height and was
	# the single root cause of two defects chased separately all session: the
	# wolf drawn as tall as a humanoid and longer than a bear (it takes the
	# largest factor precisely because it is the shortest), and the elf, tallest
	# and slimmest, shrunk hardest into a sliver. Measured against retail
	# (row 796): the wolf stands at 0.66 of the wood elf's height there, and the
	# port forced 1.00.
	#
	# A single factor preserves each model's own units, which is what retail
	# evidently does: the wolf/elf ratio then falls straight out of the AABBs at
	# 40.2/72.1 = 0.56, near the measured 0.66 and nothing like 1.00.
	#
	# REF_HEIGHT is the humanoid cluster this corpus measures (SOLDIER 73.4,
	# BEAR 73.6, WALDELFE_DARK 72.1, NOBLE_FEM 64.9), so humanoids keep roughly
	# the size the port already drew them at and only RELATIVE sizes change.
	# ponytail: that is a relative calibration, not an absolute one -- no retail
	# measurement pins the on-screen size of any single model yet, and the
	# residual 0.56 against 0.66 is unexplained (reading error, the wolves' idle
	# crouch, or a real per-species scale). Do NOT tune REF_HEIGHT to close that
	# gap; re-measure the ratio as a CHECK instead.
	_scale = SectorView.SORTCUBE_PX / REF_HEIGHT

	# Transparent pass, like the object sprites this is sorted against
	# (_build_sortcube's constraint 2); depth_draw_mode still writes the
	# depth buffer so opaque terrain occludes/is occluded correctly, mirroring
	# the sortcube's own material exactly.
	#
	# PER SURFACE, not material_override. ModelView built ONE material for the
	# whole mesh until the material chain landed and now builds one per draw
	# batch, so material_override is null and reading it crashed every rig this
	# class builds -- every NPC, every creature, the player. Two gated commits
	# passed with that live, because nothing in checks/ built a PlayerView; the
	# gate that does is checks/compose_check.gd, added with this fix.
	_mesh.sorting_use_aabb_center = false
	for s in _mesh.get_surface_override_material_count():
		var mat: StandardMaterial3D = _mesh.get_surface_override_material(s)
		if mat == null:
			continue
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY

	if _skeleton != null:
		for i in _skeleton.get_bone_count():
			if _skeleton.get_bone_parent(i) == -1:
				_root_bones.append(i)
				_root_rest_origins.append(_skeleton.get_bone_rest(i).origin)
				_root_rest_rotations.append(
					_skeleton.get_bone_rest(i).basis.get_rotation_quaternion().normalized())
		# Placement is applied through a SkeletonModifier3D rather than written
		# here, so it lands AFTER the AnimationMixer each frame. Writing it
		# directly worked only while the world posed static skeletons; once a
		# clip drove the same bones the two writes fought and the mesh came out
		# splayed (row 758). update() now just feeds this node.
		_placement = RigPlacementScript.new()
		_placement.name = "Placement"
		_placement.root_bones = _root_bones
		_placement.root_rest_origins = _root_rest_origins
		_placement.root_rest_rotations = _root_rest_rotations
		_placement.rig_scale = _scale
		_skeleton.add_child(_placement)

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

	if _skeleton == null or _root_bones.is_empty() or _placement == null:
		return
	# The world-space placement, divided back through the rig's own
	# coordinate-basis transform (model_view.gd's own idiom in _frame(): work
	# out the target in world space, then express it in this node's local
	# space, so the basis rotation does not carry it off-target) -- never
	# through the node's position, per the class doc above.
	var world_offset := Vector3(p.x, p.y, ground_z)
	_placement.local_offset = node.transform.basis.inverse() * world_offset


## Hangs an equipped mesh on one of the rig's two hand sockets. `slot` is
## startcode's tag-0x02 occurrence: 1 = main hand, 2 = off hand -- the mapping
## measured in ModelView's socket block, not inferred from the socket number.
##
## Returns true if the piece docked. False is the ordinary answer for an item
## the rig cannot carry (the body has no such hand, or the item names no grip
## for it) and the caller draws the character unarmed rather than guessing a
## bone, which is the same refusal ModelView.attach_socket makes.
## `texture` is the ITEM's own skin -- Sacred.Items.texture_of(record) -- or -1
## when the caller holds no item record and the mesh must name its own image.
## Retail prefers this over the mesh's name whenever the item carries one, which
## for most weapons and every shield is the only route to the right picture.
func equip(models: Sacred.Models, mesh_name: String, slot: int,
		texture: int = -1) -> bool:
	if node == null or _skeleton == null:
		return false
	var e := models.index_of(mesh_name)
	if e < 0:
		return false
	var socket := ModelView.SOCKET_MAIN if slot == 1 else ModelView.SOCKET_OFF
	return (node as ModelView).attach_socket(models, e, socket, texture) != null


## Puts a skinned garment on the rig -- the ARMOUR path, distinct from equip()
## above because armour shares the wearer's skeleton and a weapon does not.
## See ModelView.attach_skinned for the measurement that licenses binding by
## bone name.
##
## Returns true if the garment bound. False is the ordinary answer for a piece
## that is a rigid prop, whose vertex weights do not decode, or that is
## weighted to a bone this body lacks -- and the caller draws the character
## without it rather than binding it wrongly.
func wear(models: Sacred.Models, mesh_name: String, texture: int = -1) -> bool:
	if node == null or _skeleton == null:
		return false
	var e := models.index_of(mesh_name)
	if e < 0:
		return false
	return (node as ModelView).attach_skinned(models, e, texture) != null


## How many garments bound, and how many were refused. As with equipped(), a
## refusal is an outcome rather than an error.
func worn() -> int:
	return (node as ModelView).worn_attached if node != null else 0


func worn_refused() -> int:
	return (node as ModelView).worn_refused if node != null else 0


## How many equipped pieces docked, and how many were refused because this body
## names no socket for that hand. A refusal is the honest outcome, not a
## failure: see ModelView.SOCKET_HAND for why the hand bone is not a substitute.
func equipped() -> int:
	return (node as ModelView).sockets_attached if node != null else 0


func equipped_refused() -> int:
	return (node as ModelView).sockets_refused if node != null else 0


## Turns the rig about its own vertical, in radians. Placement is unaffected --
## see rig_placement.gd's `yaw` for why facing is a bone write and not a node
## transform. No-op on a rig that failed to build.
func set_yaw(radians: float) -> void:
	if _placement != null:
		_placement.yaw = radians


## Visibility toggle, independent of update()'s placement logic -- a caller
## that wants the rig temporarily hidden without discarding the built mesh
## and losing model_index/vertex_count/triangle_count in the process.
func set_shown(shown: bool) -> void:
	if node != null:
		node.visible = shown


## THE HERO ANIMATES. Binds the clip Sacred.Rigs picks for this body and starts
## it looping; returns false when the body has no clip, or the clip refuses to
## bind, and leaves the rig in its rest pose rather than in a broken one.
##
## Why this is a call and not something the constructor does: the clip-to-rig
## binding is measured, not certain (research row 609 -- some clips splay the
## skeleton they bind to), so a caller must be able to build the hero and NOT
## animate it. main.gd's `--noanim` is exactly that, and it makes a capture
## pair differ in one variable, the same shape as `--creatures-noanim`.
##
## rig_placement.gd already exists to survive this: it re-applies the placement
## pose AFTER the AnimationMixer writes, so animating does not undo update().
func animate(models: Sacred.Models, rigs) -> bool:
	var mv := node as ModelView
	if mv == null or rigs == null:
		return false
	# THE RESTING CLIP, not the best-scoring one. Sacred.Rigs picks a mesh's
	# clip by bone geometry, which answers "whose skeleton is this" and says
	# nothing about what the clip DOES -- and for several bodies the highest
	# scorer is an attack, so a hero standing in a meadow swung a sword on a
	# loop. rest_clip() prefers IDLE, then its fidget variant, then WALK, and
	# falls back to the overall best so a mesh with no resting clip still
	# animates rather than freezing.
	var ci: int = rigs.rest_clip(model_index)
	if ci < 0:
		return false
	return mv.play_clip(models, ci)


## The clip index Sacred.Rigs picked for this body, and how well it scored.
## Reported rather than trusted -- see Rigs.score_for.
func clip_score(rigs) -> float:
	return rigs.score_for(model_index) if rigs != null else 0.0


## --- Facing ----------------------------------------------------------------
##
## THE PROBLEM THIS SOLVES. `set_yaw` has existed and been passed 0.0 at every
## call site since it was written, because nothing established which way a
## model faces in its own coordinates -- and a wrong constant is 180 or 90
## degrees wrong on every character in the game, which looks deliberate.
##
## Two routes were measured (probes/facing_probe.gd, row 964):
##
##   A locomotion clip's ROOT translation -- REFUTED. Sacred's clips are in
##   place: GLAD_WALK_BH's root nets to exactly zero over the cycle.
##
##   `Toe0 - Foot` in the rig's own rest -- the toe is in front of the ankle,
##   so this is a forward vector whose SIGN is fixed by anatomy rather than
##   chosen. Measured in MESH space the seven class bodies disagreed badly
##   (worst pairwise dot 0.46) and split into two families.
##
## THE SPLIT WAS THE ALIGNMENT BONE, and finding it is what made this usable.
## The chain above `Bip01` is `__Root -> Root -> Bip01` on some bodies and
## `__Root -> Bip01` on others, and its NET rotation about the vertical is
## exactly 0 or -90 degrees -- quantised, never anything between:
##
##   GLADIATOR, SERAPHIM, WALDELFE   Root spins +90, Bip01 spins -90 -> net 0
##   MAGICIAN, DUNKELELVE            no Root at all                  -> net -90
##   DWARF                           Root spins 0                    -> net -90
##   DAEMONIA                        Bip01 spins -0.8                -> net ~0
##
## Re-measured in BIP01's own frame the same seven bodies agree at worst dot
## 0.9556, and every forward comes out +X with the residual being nothing but
## each body's own toe splay. So they are ONE rig convention differing by one
## rotation, and that is what licenses treating the mesh-space angle as a
## per-model constant: it already contains the alignment, so nothing has to be
## special-cased per family.
const FEET := [["Bip01 L Foot", "Bip01 L Toe0"], ["Bip01 R Foot", "Bip01 R Toe0"]]
## Below this the horizontal part of the toe vector is noise and the angle it
## implies is meaningless.
const FACING_MIN := 0.05


## The angle this body faces in its own rest pose, in the rig's horizontal
## plane, or NAN when it is not a biped.
##
## Both feet are averaged so a splayed stance cancels. The rigs are Z-UP (see
## rig_placement.gd: a humanoid's rest bbox is ~107 on Z against ~10-19
## horizontally), so the horizontal components are X and Y and the vertical --
## which for a toe-minus-ankle vector is the LARGER part, the ankle being well
## above the ball of the foot -- is discarded.
static func rest_yaw(models: Sacred.Models, entry: int) -> float:
	if entry < 0:
		return NAN
	var bones: Array = models.bones(entry)
	var xf: Array[Transform3D] = []
	var byname: Dictionary = {}
	for i in bones.size():
		var local: Transform3D = bones[i]["rest"]
		var p: int = int(bones[i]["parent"])
		xf.append(local if p < 0 or p >= i else xf[p] * local)
		var nm: String = (bones[i]["name"] as PackedByteArray).get_string_from_utf8()
		if nm != "" and not byname.has(nm):
			byname[nm] = i
	var fwd := Vector3.ZERO
	var n := 0
	for pair in FEET:
		if byname.has(pair[0]) and byname.has(pair[1]):
			fwd += xf[int(byname[pair[1]])].origin - xf[int(byname[pair[0]])].origin
			n += 1
	if n == 0:
		return NAN
	fwd /= float(n)
	if Vector2(fwd.x, fwd.y).length() < FACING_MIN:
		return NAN
	return atan2(fwd.y, fwd.x)


## True when this body can be turned. A caller that gets false draws it facing
## its rest direction, which is what it did before facing existed.
func can_face() -> bool:
	return _placement != null and not is_nan(rest_yaw_rad)


## Turns the rig to face a CELL-SPACE direction.
##
## WHY THIS DOES NOT USE THE WORLD DISPLACEMENT, which was the first attempt
## and is wrong in a way worth keeping: this world is ALREADY PROJECTED. The
## terrain is built at cell-to-screen coordinates with a depth that exists only
## to sort (SectorView's `pz = (x+y) * DEPTH_STEP`), so a cell step maps to a
## world displacement whose two horizontal components are `+-HW` on screen and
## a few thousandths of depth. Normalising that throws the depth away, and the
## four cardinal directions collapse onto two facings -- east and south both
## read "screen right". facing_check caught exactly that.
##
## SO THE CELL GRID IS THE GROUND PLANE, treated as the square grid it is, and
## the only thing that has to be recovered is how the rig's own horizontal axes
## sit against the camera. Both of those ARE derivable from the node's basis,
## with no constant chosen here:
##
##   TOWARDS_CAMERA  the rig-horizontal angle whose world image points most
##                   directly at the viewer. Cell direction (1,1) runs down the
##                   screen -- `screen_y = (cx + cy) * HH` -- so a character
##                   walking that way walks towards the viewer and must show
##                   its front.
##   SCREEN_RIGHT    the rig-horizontal angle whose world image points along
##                   world +X. Cell direction (1,-1) runs that way, and which
##                   of the two possible senses of rotation matches it is what
##                   fixes the handedness.
##
## Both are measured off the basis at call time rather than written down, so a
## change to how ModelView orients a rig moves the facing with it.
##
## Returns false and turns nothing for a zero direction or a body with no
## measurable rest facing.
func face(_cell: Vector2, dir: Vector2) -> bool:
	if not can_face() or dir.length_squared() <= 0.0 or node == null:
		return false
	var basis := node.transform.basis
	# The rig-horizontal angle that points at the viewer, and the one that
	# points along screen +X. `_horizon` walks the rig's own horizontal circle
	# and reports where a given world axis is most closely matched.
	var to_camera := _horizon(basis, Vector3(0.0, 0.0, -1.0))
	var to_right := _horizon(basis, Vector3(1.0, 0.0, 0.0))
	if is_nan(to_camera) or is_nan(to_right):
		return false
	# Cell (1,1) is towards the viewer and cell (1,-1) is screen right, so the
	# cell-space angle between them is -90 degrees. Whichever SENSE of rotation
	# reproduces that is the one this projection uses.
	var quarter := _wrap_pi(to_right - to_camera)
	var sense := 1.0 if quarter < 0.0 else -1.0
	var phi := _wrap_pi(atan2(dir.y, dir.x) - atan2(1.0, 1.0))
	set_yaw(_wrap_pi(to_camera + sense * phi - rest_yaw_rad))
	return true


## The rig-horizontal angle whose world image best matches `world_axis`.
## NAN when the rig's horizontal plane is degenerate in that direction, which
## would make the angle meaningless rather than merely imprecise.
static func _horizon(basis: Basis, world_axis: Vector3) -> float:
	# A rig-horizontal direction at angle t is (cos t, sin t, 0) -- the rigs are
	# Z-up, see rig_placement.gd. Its world image is linear in cos t and sin t,
	# so the best t has a closed form rather than needing a search.
	var wx := basis * Vector3(1.0, 0.0, 0.0)
	var wy := basis * Vector3(0.0, 1.0, 0.0)
	var a := wx.dot(world_axis)
	var b := wy.dot(world_axis)
	if Vector2(a, b).length() < FACING_MIN:
		return NAN
	return atan2(b, a)


static func _wrap_pi(a: float) -> float:
	while a > PI:
		a -= TAU
	while a < -PI:
		a += TAU
	return a


## The yaw currently applied, in radians. 0.0 when the rig failed to build.
func yaw() -> float:
	return _placement.yaw if _placement != null else 0.0


## Applies the current placement and yaw to the skeleton immediately, outside
## the normal modification phase. FOR CHECKS ONLY: a gate has no rendered frame
## to hang a SkeletonModifier3D off, and asserting that a yaw reaches the bones
## is exactly what cannot be done by reading the variable back.
func pose_now() -> void:
	if _placement != null:
		_placement._process_modification()
