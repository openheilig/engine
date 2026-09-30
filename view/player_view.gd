class_name PlayerView
extends RefCounted
## Builds and poses one model from retail data. RefCounted: main.gd owns its
## state and drives update(), while SectorView captures `node` into a private
## 3D target and inserts that image into the native cell/pass FIFO.
##
## Bodies and rigid objects share native node placement/projection. World
## placement is not applied again to skeleton roots; authored pose and full
## affine scale/shear remain ModelView's responsibility.
## Body self-depth is local to the model target, never compared with terrain's
## synthetic depth band. FloorView composites the model and its blob shadow
## between the appropriate static commands in encoded color space.

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
## Native support height is supplied with the selected blob branch, not inferred
## from the screen-space ground-depth sorting key.
var shadow_ground_height := NAN
var _shadow_world_origin := Vector3.ZERO
const NativeActorShadow := preload("res://view/native_actor_shadow.gd")
const NativeObjectShader: Shader = preload("res://shaders/native_object.gdshader")
var actor_type := 0
var shadow_branch := NativeActorShadow.Branch.UNKNOWN
var _native_model_scale := Vector3(NAN, NAN, NAN)
var _shadow_items: Sacred.Items
var _shadow_creatures: Sacred.Creatures
var _shadow_radius := 0.0
var initial_shadow_heading := Vector2(NAN, NAN)
var _native_projection := NativeActorShadow.model_to_port()
var _material_category := -1
var _native_placed := false
## Root-bone rest origins, captured once so update() only ever adds this
## call's placement on top of the model's own unscaled rest pose -- never on
## top of whatever the previous update() left behind.
var _root_bones: PackedInt32Array = PackedInt32Array()
var _root_rest_origins: Array[Vector3] = []
var _root_rest_rotations: Array[Quaternion] = []
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
		texture_pak: Sacred.Pak = null,
		hide_materials: PackedStringArray = PackedStringArray(), item_texture: int = -1) -> void:
	model_index = models.index_of(model_name)
	if model_index < 0:
		push_warning("PlayerView: %s not found in models.pak -- drawing nothing" % model_name)
		return

	var mv := ModelView.new()
	mv.set_texture_pak(texture_pak)
	mv.item_texture = item_texture
	# Retail's garment-hiding rule (row 1125): base-body materials the start
	# outfit covers are never emitted, so a worn boot does not draw over the
	# body's own `shoes` material. Empty by default -- every caller that does
	# not dress a set keeps the exact mesh it had.
	mv.hide_materials = hide_materials
	if not mv.setup(models, model_index, false):
		push_warning("PlayerView: %s failed to build -- drawing nothing" % model_name)
		mv.free()
		return

	_skeleton = mv.get_node_or_null("Skeleton")
	_mesh = mv.get_node_or_null("Skeleton/Mesh") if _skeleton != null else mv.get_node_or_null("Mesh")
	if _mesh == null or _mesh.mesh == null:
		push_warning("PlayerView: %s built with no Mesh node -- drawing nothing" % model_name)
		_skeleton = null        # never leave a pointer into a freed node
		mv.free()
		return

	vertex_count = mv.vertex_count
	triangle_count = mv.triangle_count
	_native_model_scale = models.native_scale(model_index)
	rest_yaw_rad = rest_yaw(models, model_index)



	# The isolated scene target supplies real self-depth. Alpha-scissor matches
	# the native >64/255 model coverage without a transparent sorting bypass.
	#
	# PER SURFACE, not material_override. ModelView built ONE material for the
	# whole mesh until the material chain landed and now builds one per draw
	# batch, so material_override is null and reading it crashed every rig this
	# class builds -- every NPC, every creature, the player. Two gated commits
	# passed with that live, because nothing in checks/ built a PlayerView; the
	# gate that does is checks/compose_check.gd, added with this fix.
	_mesh.sorting_use_aabb_center = false
	_style(_mesh)

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
		_skeleton.add_child(_placement)

	node = mv



## Native Gouraud light for typed actors/objects. Geometry-only probes retain
## ModelView's ordinary preview material; no fitted brightness scalar is used.
func _style(mesh: MeshInstance3D) -> void:
	if mesh == null:
		return
	var native_normal := (NativeActorShadow.CAMERA * _native_projection.inverse()).inverse().transposed()
	var light := (NativeActorShadow.CAMERA * -Vector3(1, -1, -3).normalized()).normalized()
	for surface in mesh.get_surface_override_material_count():
		var source: Material = mesh.get_surface_override_material(surface)
		var texture: Texture2D
		var material: ShaderMaterial
		if source is StandardMaterial3D:
			source.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			source.alpha_scissor_threshold = 64.0 / 255.0
			source.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
			source.no_depth_test = false
			texture = source.albedo_texture
		elif source is ShaderMaterial and source.shader == NativeObjectShader:
			material = source
			texture = source.get_shader_parameter(&"skin")
		if _material_category < 0 or texture == null:
			continue
		if material == null:
			material = ShaderMaterial.new()
			material.shader = NativeObjectShader
			mesh.set_surface_override_material(surface, material)
		material.set_shader_parameter(&"skin", texture)
		material.set_shader_parameter(&"native_view_normal_from_world", native_normal)
		material.set_shader_parameter(&"light_direction", light)
		material.set_shader_parameter(&"half_vector", (light + Vector3(0, 0, 1)).normalized())
		# Source-defined initial white daylight, not a replacement solar clock.
		material.set_shader_parameter(&"ambient_value", 0.3 if _material_category == 3 else 0.8)


## Every MeshInstance3D under `n`, styled. A worn piece is a whole ModelView
## subtree, not a bare mesh, so the walk is what makes "style what was just
## attached" a single call at each site.
func _style_tree(n: Node) -> void:
	if n is MeshInstance3D:
		_style(n)
	for c in n.get_children():
		_style_tree(c)

## Feed the post-animation placement modifier. Scene order is supplied
## separately through SectorView.place_actor with the actual support identity.
func update(cell: Vector2) -> void:
	if node == null or _native_placed:
		return
	var p := IsoCamera.cell_to_world(cell)
	var ground_z := SectorView.ground_depth(p)
	# Shadow eligibility/radius/native transforms arrive through explicit
	# configuration. Unsupported shadow branches draw nothing, never a guessed
	# silhouette. The final bone positions refresh after skeleton modifiers.

	if _skeleton == null or _root_bones.is_empty() or _placement == null:
		return
	# The world-space placement, divided back through the rig's own
	# coordinate-basis transform (model_view.gd's own idiom in _frame(): work
	# out the target in world space, then express it in this node's local
	# space, so the basis rotation does not carry it off-target) -- never
	# through the node's position, per the class doc above.
	var world_offset := Vector3(p.x, p.y, ground_z)
	_placement.local_offset = node.transform.basis.inverse() * world_offset
	# cPatchPosition truncates native lattice coordinates before projection.
	# Keep the body's calibrated placement separate; the shadow must use the
	# same integer point as NativeActorShadow's heading and support queries.
	# LGP 0x080D620C stores each complete scalar sum as float32.
	var point := Vector2(int(cell.x * NativeActorShadow.CELL_UNITS),
		int(cell.y * NativeActorShadow.CELL_UNITS))
	var shadow_xy := Vector2(
		NativeActorShadow.LATTICE_X.x * point.x + NativeActorShadow.LATTICE_Y.x * point.y,
		-(NativeActorShadow.LATTICE_X.y * point.x + NativeActorShadow.LATTICE_Y.y * point.y))
	_shadow_world_origin = Vector3(shadow_xy.x, shadow_xy.y, ground_z)
	(node as ModelView).update_shadow_ground(_shadow_world_origin, shadow_ground_height)


## Authored stationary objects use native model units and camera projection,
## not the humanoid calibration. Cell is already the native cell centre.
## Native per-vertex lighting uses the item's category, not a creature preset.
## Object shadow rendering remains separate.
func place_object(cell: Vector2, heading: Vector2, height: float, category: int) -> bool:
	if node == null or not is_finite(height) or category < 0:
		return false
	var actor_basis := NativeActorShadow.actor_basis(cell, heading, _native_model_scale)
	if not actor_basis.is_finite():
		return false
	for surface in _mesh.get_surface_override_material_count():
		var source: Material = _mesh.get_surface_override_material(surface)
		var texture: Texture2D
		if source is StandardMaterial3D:
			texture = source.albedo_texture
		elif source is ShaderMaterial and source.shader == NativeObjectShader:
			texture = source.get_shader_parameter(&"skin")
		if texture == null:
			push_error("PlayerView.place_object: native lighting requires a decoded skin")
			return false
	_place_native_transform(cell, actor_basis, height)
	_material_category = category
	_style_tree(node)
	return true


func _place_native_transform(cell: Vector2, actor_basis: Basis, height: float) -> void:
	var point := Vector2(int(cell.x * NativeActorShadow.CELL_UNITS),
		int(cell.y * NativeActorShadow.CELL_UNITS))
	var xy := Vector2(
		NativeActorShadow.LATTICE_X.x * point.x + NativeActorShadow.LATTICE_Y.x * point.y,
		-(NativeActorShadow.LATTICE_X.y * point.x + NativeActorShadow.LATTICE_Y.y * point.y))
	_shadow_world_origin = Vector3(xy.x, xy.y, SectorView.ground_depth(xy))
	node.transform = Transform3D(_native_projection * actor_basis,
		_shadow_world_origin + _native_projection.z * height)
	_native_placed = true
	if _placement != null:
		_placement.rig_scale = 1.0
		_placement.local_offset = Vector3.ZERO
		_placement.yaw = 0.0


## The caller has selected retail's SHADOWDOT branch and resolved its native
## actor inputs. Radius is cItems::8139092 (record +0x14, valid zero -> 50),
## not a model AABB. Native ground height is actor/support +240.
func configure_blob_shadow(radius: float, native_actor_basis: Basis,
		retail_to_port: Basis, ground_height: float) -> bool:
	disable_blob_shadow()
	if node == null or _placement == null or not is_finite(ground_height):
		return false
	if not (node as ModelView).configure_blob_shadow(radius, _placement,
			native_actor_basis, retail_to_port):
		return false
	shadow_ground_height = ground_height
	(node as ModelView).update_shadow_ground(_shadow_world_origin, shadow_ground_height)
	return true


## Branch changes must remove the old blob, not retain it as a fallback for
## unsupported projected/stencil branches.
func disable_blob_shadow() -> void:
	shadow_ground_height = NAN
	if node != null:
		(node as ModelView).disable_blob_shadow()


## Native heading/support can change without rebuilding the texture or quads.
func update_blob_shadow_transform(native_actor_basis: Basis, ground_height: float) -> void:
	if node == null or _placement == null or not is_finite(ground_height):
		return
	shadow_ground_height = ground_height
	(node as ModelView).update_blob_shadow_transform(native_actor_basis)
	(node as ModelView).update_shadow_ground(_shadow_world_origin, shadow_ground_height)


## Identity comes from the actor's actual item type, never a reverse lookup of
## an arbitrary model-only preview. Keep the existing low-level packet API for
## native captures; this is the production type/branch integration.
func configure_actor(type_id: int, items: Sacred.Items, creatures: Sacred.Creatures) -> void:
	disable_blob_shadow()
	actor_type = type_id
	_shadow_items = items
	_shadow_creatures = creatures
	initial_shadow_heading = NativeActorShadow.heading_from_degrees(
		items.initial_heading_degrees(type_id)) if items != null else Vector2(NAN, NAN)
	_shadow_radius = items.shadow_radius_of(type_id) if items != null else 0.0
	shadow_branch = NativeActorShadow.Branch.UNKNOWN
	if node != null and items != null and items.has_definition(type_id):
		_material_category = items.category_of(type_id)
		_style_tree(node)
	if not _native_model_scale.is_finite() or not initial_shadow_heading.is_finite():
		push_error("PlayerView: missing native model scale or item heading for actor type %d" % type_id)


func update_native_actor(cell: Vector2, heading: Vector2, ground_height: float,
		support_ref: int, support_is_horse: bool, detail: int,
		hidden_remote_player: bool, debug_override: bool) -> void:
	var selected := NativeActorShadow.branch(actor_type, _shadow_items, _shadow_creatures,
		detail, support_ref, support_is_horse, hidden_remote_player, debug_override)
	var basis := NativeActorShadow.actor_basis(cell, heading, _native_model_scale)
	if not basis.is_finite() or not is_finite(ground_height):
		selected = NativeActorShadow.Branch.UNKNOWN
	else:
		_place_native_transform(cell, basis, ground_height)
	if selected != NativeActorShadow.Branch.BLOB:
		disable_blob_shadow()
	elif shadow_branch != NativeActorShadow.Branch.BLOB:
		if not configure_blob_shadow(_shadow_radius, basis,
				NativeActorShadow.retail_to_port(), ground_height):
			selected = NativeActorShadow.Branch.UNKNOWN
			push_warning("PlayerView: native blob configuration failed for actor type %d" % actor_type)
	else:
		update_blob_shadow_transform(basis, ground_height)
	shadow_branch = selected

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
	var piece := (node as ModelView).attach_socket(models, e, socket, texture)
	if piece == null:
		return false
	# A carried weapon is lit by the same model as the body it hangs off, so it
	# takes the same treatment -- see _style for why this cannot live in setup().
	_style_tree(piece)
	return true


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
	var worn_mesh := (node as ModelView).attach_skinned(models, e, texture)
	if worn_mesh == null:
		return false
	_style(worn_mesh)
	return true


## How many garments bound, and how many were refused. As with equipped(), a
## refusal is an outcome rather than an error.
func worn() -> int:
	return (node as ModelView).worn_attached if node != null else 0


func worn_refused() -> int:
	return (node as ModelView).worn_refused if node != null else 0


## How many equipped pieces docked, and how many were refused because this body
## names no socket for that hand. A refusal is the honest outcome, not a
## failure: see ModelView.SOCKET_HAND for why the hand bone is not a substitute.
## Dynamic garment-hiding (row 1125, slot-driven): hide the base-body
## surfaces the tokens name after a garment successfully binds. No-op when
## the body was not skinned (no Skeleton/Mesh).
func hide_base_surfaces(tokens: PackedStringArray) -> void:
	if node is ModelView:
		(node as ModelView).set_materials_hidden_by_token(tokens, true)


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
	if not mv.play_clip(models, ci):
		return false
	# Seed play_action's state, so the first switch away from rest is a real
	# switch and a switch back to it is correctly a no-op.
	_action_clip = ci
	action = Sacred.Rigs.action_of(models.entry_name(ci))
	return true


## THE CLIP THIS BODY IS PLAYING RIGHT NOW, as an ACTION name ("WALK",
## "IDLE", ...) or "" before animate() has run. Read-only by convention --
## play_action() owns it.
var action := ""
## The clip entry `action` resolved to, so a repeat call is a no-op rather
## than a rebuild. -1 when nothing is playing.
var _action_clip := -1


## Switches this body to its clip for `action` and returns whether it is now
## playing one. THE MECHANISM ONLY: which action a character should be in is a
## simulation question and this class never asks it -- the caller passes a
## name, exactly as it passes a cell to update() and an angle to face().
##
## REFUSES RATHER THAN APPROXIMATES, the same contract animate() has. A mesh
## with no clip for `action` keeps playing whatever it was playing and this
## returns false, because the alternative -- falling back to some other
## action -- would make a body that cannot walk silently attack instead.
##
## "IDLE" IS THE ONE NAME THAT LADDERS, via rest_clip's IDLE -> FIDLE -> WALK.
## It reads like the same shortcut would suit every member of REST_ACTIONS and
## it must not: WALK is in that list because rest_clip may FALL BACK to a walk
## for a body with no idle, and routing a WALK request through rest_clip made
## play_action("WALK") return the IDLE clip and answer true. The Seraphim --
## who resolves no WALK at all -- reported herself as walking on the spot.
##
## A repeat call for the action already playing is free: the clip index is
## compared, not the name, so REST_ACTIONS collapsing onto the same clip
## costs nothing either.
##
## ponytail: a switch rebuilds the Animation from the .GRN every time, because
## ModelView.play_clip decodes on each call. Walk <-> idle transitions are
## rare enough (a few per second at worst) that this has not been measured to
## hitch; if it does, cache the built Animation in the AnimationPlayer's
## library by clip name instead of removing and re-adding it.
func play_action(models: Sacred.Models, rigs, action_name: String) -> bool:
	var mv := node as ModelView
	if mv == null or rigs == null:
		return false
	var ci: int = rigs.rest_clip(model_index) if action_name == "IDLE" \
		else rigs.clip_for_action(model_index, action_name)
	if ci < 0:
		return false
	if ci == _action_clip:
		action = action_name
		return true
	if not mv.play_clip(models, ci):
		return false
	_action_clip = ci
	action = action_name
	return true


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
## The cell-space angle of (1,1), which runs down the screen and therefore
## towards the viewer. A constant rather than atan2(1,1) recomputed per frame.
const TOWARDS_VIEWER := PI / 4.0


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
		var nm: String = (bones[i]["name"] as PackedByteArray).get_string_from_ascii()
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
	# -Z, CALIBRATED BY RENDER, and the calibration story matters because this
	# sign has now been "corrected" once in each direction (rows 1007/1014).
	# The camera-axis argument says towards-the-viewer is +Z 	(camera at
	# z=+1000, unrotated, terrain depth growing with x+y), and the posed
	# Toe0-Foot vector agrees with it -- and BOTH are the wrong ground truth:
	# rendering the dressed body at each yaw and looking for the FACE (red
	# lips, necklace -- unmistakable, unlike the bare figure whose forward
	# pigtails read as a face from behind) shows the front at exactly the yaw
	# this -Z axis produces, on the same frame retail shows its front. The
	# composed toe vector points BEHIND these rigs' visual front, so any
	# facing rule derived from it lands 180 degrees off the pixels. The render
	# is the parity target; the render wins.
	var to_camera := _horizon(basis, Vector3(0.0, 0.0, -1.0))
	var to_right := _horizon(basis, Vector3(1.0, 0.0, 0.0))
	if is_nan(to_camera) or is_nan(to_right):
		return false
	# Cell (1,1) is towards the viewer and cell (1,-1) is screen right, so the
	# cell-space angle between them is -90 degrees. Whichever SENSE of rotation
	# reproduces that is the one this projection uses.
	var quarter := angle_difference(to_camera, to_right)
	var sense := 1.0 if quarter < 0.0 else -1.0
	var phi := angle_difference(TOWARDS_VIEWER, atan2(dir.y, dir.x))
	set_yaw(wrapf(to_camera + sense * phi - rest_yaw_rad, -PI, PI))
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


## The yaw currently applied, in radians. 0.0 when the rig failed to build.
func yaw() -> float:
	return _placement.yaw if _placement != null else 0.0


## Applies the current placement and yaw to the skeleton immediately, outside
## the normal modification phase. FOR CHECKS ONLY: a gate has no rendered frame
## to drive a SkeletonModifier3D, and asserting that a yaw REACHES the bones is
## exactly what cannot be done by reading the variable back.
##
## Calls the modifier's own public apply() rather than its engine virtual. The
## first version invoked `_process_modification()` directly, which is both
## deprecated in 4.7 and a parallel path -- when the body moved to
## `_process_modification_with_delta` that call would have posed NOTHING and the
## check would have gone green on stale bones. A seam whose failure mode is
## "silently passes" is worse than no seam.
func pose_now() -> void:
	if _placement != null and _skeleton != null:
		_placement.apply(_skeleton)
		(node as ModelView).refresh_drop_shadow()
