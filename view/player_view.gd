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
var _shadow_on := false                 ## the drop shadow enables once, then only refreshes
var _scale := 1.0
## Root-bone rest origins, captured once so update() only ever adds this
## call's placement on top of the model's own unscaled rest pose -- never on
## top of whatever the previous update() left behind.
var _root_bones: PackedInt32Array = PackedInt32Array()
var _root_rest_origins: Array[Vector3] = []
var _root_rest_rotations: Array[Quaternion] = []
## Reference rig height in model units -- see the scale block in setup().
const REF_HEIGHT := 73.0

## RETAIL'S OWN DRAWN HEIGHT for a REF_HEIGHT-unit humanoid, in pixels at the
## middle zoom step. This is the measurement the scale block in setup() has been
## asking for in comment form ("no retail capture has measured an actual
## character height yet"), and it replaces the borrowed SectorView.SORTCUBE_PX,
## which is a DEPTH-SORT PROXY BOX and was never a claim about character size.
## SORTCUBE_PX is deliberately left alone: sector_view builds its sort cube from
## it and that sorting is verified, so repurposing it would move two things at
## once.
##
## HOW IT WAS MEASURED, and how far it can be trusted. The port's projection is
## exactly one world unit to one pixel here -- ortho size 768 over a 768-px
## viewport -- which is confirmed rather than assumed: at the old scale of
## 96.0/73.0 = 1.3151 a 74.3-unit SERAPHIM.GRN predicts 97.7 px drawn, and the
## rendered figure measured 97. So the scale is the only free variable, and
## retail pins it. Against the retail campaign-start capture of the same frame,
## same cell 3236,2511, same 1024x768:
##
##     landmark            port (scale 1.3151)   retail     implied scale
##     shoulder -> sole            77 px          110 px        1.879
##     belt     -> sole            62 px           83 px        1.761
##
## Two landmarks rather than overall height because retail's hair rises into the
## stone wall behind her, so the top of that silhouette cannot be segmented from
## the floor, and her drop shadow -- which the port does not draw at all --
## contaminates the bottom. Both landmarks are interior to the body and clear of
## each. 1.82 is their mean; 133.0 = 1.82 * 73.
##
## ponytail: ONE CLASS, ONE FRAME, and the two landmarks disagree by 6%, so read
## this as +/-4% rather than exact. It is a relative calibration turned absolute,
## not a recovered constant. Row 797's warning still stands: this factor is
## GLOBAL and preserves each model's own units, so it must not be re-tuned to
## close the separate wolf/elf ratio gap -- re-measure that ratio as a check.
const RETAIL_HUMANOID_PX := 133.0

## Retail's character light ramp evaluated at FULL light (index 255) with the
## brightness setting at maximum, i.e. 191/255 on red and green and 213/255 on
## blue. Derived in the material loop in setup(), where the table builder and its
## four float constants are transcribed; spelled as a constant here so the call
## site is not three magic fractions.
const RETAIL_LIGHT_FULL := Color(191.0 / 255.0, 191.0 / 255.0, 213.0 / 255.0)
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
		hide_materials: PackedStringArray = PackedStringArray()) -> void:
	model_index = models.index_of(model_name)
	if model_index < 0:
		push_warning("PlayerView: %s not found in models.pak -- drawing nothing" % model_name)
		return

	var mv := ModelView.new()
	mv.set_texture_pak(texture_pak)
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
	_scale = RETAIL_HUMANOID_PX / REF_HEIGHT

	# Transparent pass, like the object sprites this is sorted against
	# (_build_sortcube's constraint 2), mirroring the sortcube's own material.
	# DEPTH_DRAW_OPAQUE_ONLY does NOT mean "still writes depth" -- see _style().
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
		_placement.rig_scale = _scale
		_skeleton.add_child(_placement)

	node = mv



## Applies the character material model to every surface of `mesh`.
##
## SEPARATE FROM setup() BECAUSE GARMENTS ARRIVE LATER. attach_skinned builds
## each worn piece as its OWN ModelView with its own MeshInstance3D, and
## _dress_player runs after this class is constructed, so a loop that ran once
## over the body mesh reached the body and nothing else. Measured: with the ramp
## on the body alone, hero-pixel p75 and p90 moved onto retail (1.500 -> 1.188
## and 1.241 -> 0.980) while p10 through p50 did not move AT ALL, because those
## darker pixels are the garments and they were still lit by the old model.
##
## Transparent pass, like the object sprites this is sorted against
## (_build_sortcube's constraint 2), mirroring the sortcube's own material.
##
## DEPTH_DRAW_OPAQUE_ONLY DOES NOT MEAN "still writes the depth buffer", which
## this comment claimed until 2026-08-25. It means only OPAQUE materials write
## depth, so this one writes none. Terrain still occludes a rig correctly
## because TERRAIN writes depth; what is absent is the rig's own contribution,
## and the only thing that could reveal it is a rig overlapping ITSELF.
##
## LEFT ALONE ON PURPOSE, and by measurement rather than argument. Switching to
## TRANSPARENCY_ALPHA_DEPTH_PRE_PASS -- which is what retail's fixed-function
## path amounts to, since `install/sacred` links glAlphaFunc and glDepthMask,
## i.e. alpha TEST plus depth writes -- changes the rendered frame by ZERO
## pixels in the NPC window and 3 in the hero box. The rigs do not self-overlap
## in practice, so the extra pass buys no fidelity. All ten character skins
## sampled are opaque on every texel (a=255), which is why; the Horse's genuine
## cutouts (see model_view.gd, a1=0.877) are the case that would need it.
##
## PER SURFACE, not material_override. ModelView built ONE material for the
## whole mesh until the material chain landed and now builds one per draw batch,
## so material_override is null and reading it crashed every rig this class
## builds -- every NPC, every creature, the player. Two gated commits passed with
## that live, because nothing in checks/ built a PlayerView; the gate that does
## is checks/compose_check.gd.
func _style(mesh: MeshInstance3D) -> void:
	if mesh == null:
		return
	for s in mesh.get_surface_override_material_count():
		var mat: StandardMaterial3D = mesh.get_surface_override_material(s)
		if mat == null:
			continue
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
		# UNSHADED, BECAUSE RETAIL DOES NOT LIGHT CHARACTERS WITH LIGHTS.
		#
		# Sacred's character lighting is a SCALAR LOOKUP, recovered from the Windows
		# retail build's sub_41B5B0: it starts from a base ambient of 32/255,
		# accumulates a contribution per nearby light source attenuated by distance,
		# clamps the total to 255, and uses that ONE number to index three 256-entry
		# per-channel colour ramps, whose output then modulates the mesh. There is no
		# surface normal anywhere in it -- no diffuse term, no specular, no light
		# direction. The port was instead lighting the hero with two DirectionalLight3Ds
		# (main.gd:_ensure_rig_light), which is a different model and produced a
		# harsh, directionally-shaded figure where retail draws a flat modulated one.
		#
		# The terrain path already works retail's way and already matches: sector_view
		# draws unshaded and multiplies by the cell's own +0x14 light byte, and over
		# ten floor patches chosen clear of the hero and furniture SIX come out
		# byte-identical to retail, with 71.35% of the whole frame inside 12/255.
		# Applying the same model to the character is consistency, not a new guess.
		#
		# MEASURED EFFECT, including where it is still wrong. Skin, hair, the white
		# boots and the gold all move onto retail's values by eye, and the highlight
		# deficit closes: hero-pixel V p90 goes 119.0 -> 181.3 against retail's 139.7.
		# It now OVERSHOOTS by 41.7. That is expected and is NOT tuned out here with a
		# scalar, for two reasons. First, the two masks are different sizes (3995 port
		# pixels against 5504 retail) because the port's figure is separately known to
		# be too small, so a percentile-to-percentile ratio does not compare the same
		# pixels -- the fallacy that produced rows 979 and 999. Second, the honest fix
		# is the missing half of the mechanism: retail's ramp, and the per-cell light
		# value feeding it. At this start cell the light byte is 255, so full albedo is
		# the right INPUT and the ramp is what would bring the top end down.
		#
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		# NO DEPTH TEST, BECAUSE A CHARACTER IS A UNIT, NOT TERRAIN (row 1014).
		#
		# The rig is true 3D: placed at the cell, the Seraphim's body spans
		# world z 268.8..310.1 -- 826 DEPTH_STEPs -- while her own floor quad
		# sits at 287.4, through her waist. With the depth test on, every
		# pixel of her behind that plane loses, and what survives is the thin
		# dark cross-section the port drew for days (row 1006's "narrow trunk"
		# was a MEASUREMENT OF THIS ARTEFACT, not of her geometry). The 2005
		# engine never depth-tests a character against the ground: units draw
		# whole, in painter's order.
		#
		# So the character opts out of the z-buffer and takes its ordering
		# entirely from the transparent queue's sort -- node global position
		# plus the sorting_offset update() maintains -- which is the exact
		# regime the object sprites already live in. Terrain is opaque and
		# drawn first, so she stands ON the floor; walls and props are
		# transparent-queue and sort against her baseline, so they still
		# occlude her when she walks behind them.
		#
		# ponytail: pieces of ONE body no longer depth-test against each
		# other either -- intra-body overlap is submission order. At 133 px
		# that reads fine; if a pose ever shows a hand behind the chest it
		# should be in front of, the upgrade is a vertex-shader z-compress
		# about the baseline, not turning the test back on.
		mat.no_depth_test = true
		# ...AND THE RAMP, WHICH IS THE OTHER HALF OF THAT MECHANISM.
		#
		# sub_41B5B0 indexes three 256-entry per-channel tables with its
		# accumulated light scalar. Their BUILDER is sub_417FA0 at 0x4188C0-0x4189ED:
		# one loop, i from 0 to 255, filling all six tables (two sets of three) from
		# four float constants, which read 0.25 (flt_88F7C4), 64.0 (flt_88F914),
		# 1/3 (flt_88F910) and 0.75 (flt_88F90C):
		#
		#     base  = clamp(brightness_setting, 0, 1) * 64      ; sub_81C9E0, clamped
		#                                                        against 0.0 and 1.0
		#     R = G = floor(i * 0.25    + base + 64)            ; tables +0xFE18, +0x10218
		#     B     = floor(i * (1/3)   + base + 64)            ; table  +0x10618
		#
		# and the packed result modulates the mesh. Blue climbs faster than red and
		# green, which is why the ramp cools the image as it brightens rather than
		# just scaling it -- a plain multiply cannot reproduce that and neither can
		# a gamma. (The second set of three tables, +0x12E18 onward, is a separate
		# neutral ramp, floor(i*0.75 + 64) on all three channels, selected by the
		# flag at +40460; that path is not the one the world draws through.)
		#
		# APPLIED HERE AT FULL LIGHT ONLY. i = 255 with the brightness setting at
		# maximum gives R = G = floor(63.75 + 128) = 191 and B = floor(85 + 128) = 213,
		# hence the constants below. That is the right value for this frame and no
		# other: the Seraphim's start cell carries terrain light byte 255 and has no
		# dynamic light near her. A rig standing in shadow needs i from the cell and
		# the ramp evaluated per rig, which is the next step and is NOT done here.
		#
		# Direction confirmed independently before it was applied: with the figures
		# finally at matching size, the port read BRIGHTER than retail at every
		# percentile of the hero mask (p10 through p90, ratios 1.18 to 1.53), and
		# 1/0.749 = 1.34 sits inside that band.
		mat.albedo_color = RETAIL_LIGHT_FULL


## Every MeshInstance3D under `n`, styled. A worn piece is a whole ModelView
## subtree, not a bare mesh, so the walk is what makes "style what was just
## attached" a single call at each site.
func _style_tree(n: Node) -> void:
	if n is MeshInstance3D:
		_style(n)
	for c in n.get_children():
		_style_tree(c)

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
	# The drop shadow rides every placement: enabled on the first update (one
	# duplicate of each skinned piece under the skeleton), then only its two
	# moving constants refresh. Retail draws it for every character without a
	# flag, so there is no opt-in here either.
	if not _shadow_on:
		_shadow_on = true
		(node as ModelView).enable_drop_shadow(Vector3(p.x, p.y, ground_z), Vector2(105, 40))
	else:
		(node as ModelView).update_shadow_ground(Vector3(p.x, p.y, ground_z))

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
