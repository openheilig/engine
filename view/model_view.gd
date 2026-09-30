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
## Key light strength, shared with main.gd's streamed-world rig light so a
## creature standing in the world is lit exactly as --grn= previews it.
const KEY_ENERGY := 1.5

var vertex_count := 0
## Triangles the split path drew that no material group claimed -- see the
## leftovers block in setup(). 0 on the unsplit path, which draws everything.
var ungrouped_triangles := 0
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
## Validation now uses independent native evidence (findings 1247/1265/1266):
## same-pose Seraphim/novice geometry and normals, plus native wolf affine
## matrices. These fixtures are not a claim of complete corpus-wide parity;
## the circular rest-times-inverse-rest assertion remains deliberately absent.

var _settled := false
var _skeleton: Skeleton3D = null
var _skin: Skin = null
var _weights: Array[Dictionary] = []
var _local_to_bind: Array[PackedInt32Array] = []

## Granny locals are T * R * SS, with a full 3x3 SS. Skeleton3D stores only
## TRS; even global-pose overrides interpolate through that decomposition.
## Preserve the authored matrices and replace the render palette after Godot
## updates it. Ordinary TRS rigs keep the engine path.
var affine_global_poses: Array[Transform3D] = []
var _affine_rests: Array[Transform3D] = []
var _affine_rest_rotations: Array[Quaternion] = []
var _affine_rest_scales: Array[Basis] = []
var _affine_rest_pose_inverse: Array[Transform3D] = []
var _affine_positions := PackedVector3Array()
var _affine_rotations: Array[Quaternion] = []
var _affine_roots: Array[Transform3D] = []
var _affine_tracks: Dictionary = {}
var _affine_meshes: Array[MeshInstance3D] = []
var _affine_sockets: Array[BoneAttachment3D] = []
var _affine_rest_required := false
var _affine_required := false
var _affine_time := 0.0
var _standalone_render := false

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
## The image each EMITTED surface received, in surface order, and the material
## slot it came from. Recorded rather than re-derived: the emission order is the
## reconciled submesh order, not the group order material_groups() returns, so a
## caller pairing group i with surface i is reading a different assignment from
## the one the renderer made.
var surface_texture := PackedStringArray()
var surface_material := PackedInt32Array()

## The texture.pak entry this rig's ITEM skins it with, or -1 for "use the
## mesh's own texture names". Set before setup() -- attach_socket takes it as an
## argument; a body is never skinned this way, only a carried piece.
var item_texture := -1

## Base-body MATERIAL NAMES setup() must not emit -- claimed but never drawn.
## Set before setup(). This is retail's garment-hiding rule (row 1125): a body
## wearing real boots must not also draw the base `shoes` material painted onto
## it, or two boots render in one place. The vocabulary is material_names() --
## SERAPHIM's base materials name themselves Angel_body / legs / Angel_Hair /
## Angel_head / shoes / Angel_arms. Only boots -> "shoes" is measured; the rest
## of the slot table is deliberately absent until each slot is measured against
## retail the same way.
## ponytail: one measured slot mapping; upgrade by dressing each slot in retail
## and diffing, not by guessing the remaining five.
var hide_materials := PackedStringArray()

func set_texture_pak(pak: Sacred.Pak) -> void:
	_texture_pak = pak


## THE EQUIPMENT SOCKETS. Both halves of the dock are NAMED, on both sides, in
## the file -- nothing here is a guess about where a weapon hangs.
##
## Corpus census over all 1571 rigged models.pak entries (2026-08-15):
##
##   WEARER SIDE   Bone_weapon_01 <- Bip01 R Hand   235 entries
##                 Bone_weapon_02 <- Bip01 L Hand   192
##   WEAPON SIDE   Bone_weapon_01 <- __Root         206      the grip point, in
##                 Bone_weapon_02 <- __Root         176      the weapon's space
##
## with ZERO disagreements: _01 never hangs off a left hand and _02 never off a
## right one. The two populations are disjoint by parent, so the same bone name
## means "where I hold it" on a body and "where it is held" on a weapon, and
## docking is aligning one to the other.
##
## _01 IS THE MAIN HAND, and that is measured rather than assumed from the
## number. startcode's tag-0x02 occurrence 1 and 2 are the two hand slots; over
## the 1111 armed slots the eight classes declare, SHIELDS are 58.8% of slot 2
## against 10.5% of slot 1. The structural half is stronger than that rate: all
## 272 slot-2 meshes carry Bone_weapon_02, while 97 of the 839 slot-1 meshes do
## NOT -- the polearms (PIKE, SPEAR, HELLEBARDE, STAFF_FIGHT), which have only
## a main-hand grip. Zero items sit in slot 2 without an off-hand socket.
const SOCKET_MAIN := "Bone_weapon_01"
const SOCKET_OFF := "Bone_weapon_02"
## The hand each socket hangs off, used to TELL THE TWO SIDES APART -- never as
## a place to hang a weapon when the wearer has no socket.
##
## Substituting the hand was tried and is withdrawn. It was justified on
## position, which is real: on the bodies carrying both, the socket sits ~1e-6
## from the hand. But a dock uses the whole TRANSFORM, and the ROTATION does not
## follow. Over the 441 wearer-side sockets, the socket's rest rotation relative
## to its parent hand is:
##
##      0-15 deg  299   the hand is a fair stand-in
##     30-60 deg   13
##    90-180 deg  107   a completely different frame
##
## So the hand is right about two thirds of the time and off by a quarter turn
## or more for a quarter of the corpus -- and a body with no socket gives no way
## to tell which group it belongs to. That is invention with a known failure
## rate, and on SOLDIER it laid a kite shield flat across the character's chest.
## A wearer with no socket is REFUSED and counted instead.
const SOCKET_HAND := {SOCKET_MAIN: "Bip01 R Hand", SOCKET_OFF: "Bip01 L Hand"}

## Pieces docked by attach_socket(), and pieces refused because this rig names
## no socket for that hand. The second is the honest measure of how much of the
## cast cannot be armed yet -- see research/formats/granny-grn.md.
var sockets_attached := 0
var sockets_refused := 0
## Skinned garments (attach_skinned) that bound, and that were refused because
## the piece is a prop, its weights did not decode, it is weighted to a bone
## this wearer does not have, or it was cut for a different body.
var worn_attached := 0
var worn_refused := 0
## Rest-transform tolerance for the garment-fits-wearer test in
## attach_skinned. Borrowed from checks/equip_check.gd's WITHIN rather than
## chosen here, so the render path admits a garment on exactly the instrument
## R1.4 was measured with.
const FIT_WITHIN := 0.01

## True when the entry declared bones but no weights: an unskinned rigid prop,
## whose bones are locators. Set by _build_rig; the Skeleton3D is discarded, so
## bone_rests below is the only record of where those locators are.
var is_prop := false
## Sacred.Models.bones() for a prop, kept because a prop has no Skeleton3D to
## ask. Empty for a skinned rig, which answers through its skeleton instead.
var bone_rests: Array[Dictionary] = []


## The Skeleton3D bone indices the SKIN actually binds, i.e. the bones the mesh
## deforms with. Smaller than the bone count and legitimately so: GLADIATOR
## stores 68 bones and binds 56, because a Granny export from Max carries the
## scene's helpers -- Omni01/03/05 are omni LIGHTS, Cam_*.Target are camera
## targets, and the two weapon sockets deform nothing either. They sit hundreds
## of units from the body, so anything that treats the bone list as the skeleton
## (a viewer, an AABB, a retarget) is reading furniture as anatomy.
func bound_bones() -> PackedInt32Array:
	var out := PackedInt32Array()
	if _skin == null:
		return out
	for i in _skin.get_bind_count():
		out.append(_skin.get_bind_bone(i))
	return out


## Where `socket` sits in THIS rig's own model space, or null when the rig does
## not name it. Answers for a skinned rig and for a prop alike -- the two keep
## the same numbers in different places, and every caller wants the transform
## rather than an index into whichever one it happens to be.
##
## Null is a real answer and the only honest one: there is no substitute bone,
## for the reason SOCKET_HAND documents.
func socket_rest(socket: String) -> Variant:
	if is_prop:
		var idx := -1
		for i in bone_rests.size():
			if (bone_rests[i]["name"] as PackedByteArray).get_string_from_ascii() == socket:
				idx = i
		return _prop_global_rest(idx) if idx >= 0 else null
	if _skeleton == null:
		return null
	var b := _skeleton.find_bone(socket)
	return _skeleton.get_bone_global_rest(b) if b >= 0 else null


## A prop bone's rest composed up its parent chain, which is what a Skeleton3D
## would have done had one been built.
func _prop_global_rest(idx: int) -> Transform3D:
	var t: Transform3D = bone_rests[idx]["rest"]
	var p: int = bone_rests[idx]["parent_effective"]
	var guard := 0
	while p >= 0 and p < bone_rests.size() and guard < bone_rests.size():
		t = (bone_rests[p]["rest"] as Transform3D) * t
		p = bone_rests[p]["parent_effective"]
		guard += 1
	return t


## Docks `entry` onto this rig's `socket`, building it with the same unmodified
## setup() every other mesh goes through. Returns the built piece, or null.
##
## THE ALIGNMENT, in one line, and why it is that line. A BoneAttachment3D child
## of the Skeleton3D reproduces the socket bone's posed transform S, so a piece
## parented under it renders at S * T * p for a point p in its own model space.
## The piece's grip sits at G = its coordinate basis times the grip bone's own
## global rest, so setting T = G^-1 puts the grip exactly on the socket and
## leaves the piece hanging off it -- which is the whole dock.
##
## The piece keeps its OWN small skeleton and is never re-skinned onto this one:
## measured, a weapon shares only __Root and the socket names with a body (3 of
## 8..16 bones), so it is a rigid prop on a moving socket and not a second
## garment. The BoneAttachment3D is what makes it follow the animated hand.
## `texture` is the carried item's own skin -- an items.pak `+0x08` texture.pak
## entry, or -1 to let the piece's mesh name its own image. See
## ModelView.item_texture and Sacred.Items.TEXTURE_OFF.
func attach_socket(models: Sacred.Models, entry: int, socket: String,
		texture: int = -1) -> ModelView:
	if _skeleton == null:
		return null
	var bone := _skeleton.find_bone(socket)
	if bone < 0:
		# This wearer names no socket for this hand, so where the weapon goes is
		# simply not in the file. Refused, not approximated.
		sockets_refused += 1
		return null
	var piece := ModelView.new()
	piece.name = "%s_%d" % [socket, entry]
	piece.set_texture_pak(_texture_pak)
	piece.item_texture = texture
	if not piece.setup(models, entry, false):
		piece.free()
		return null
	var grip: Variant = piece.socket_rest(socket)
	if grip == null:
		# The piece names no grip for this hand. Refused rather than dropped at
		# the origin: an item with only a main-hand grip (every polearm) put in
		# an off hand would otherwise render inside the character.
		piece.free()
		return null
	var att := BoneAttachment3D.new()
	att.name = "Socket_%s_%d" % [socket, entry]
	_skeleton.add_child(att)
	att.bone_idx = bone
	att.add_child(piece)
	# T = G^-1, and NOTHING ELSE. The piece's own coordinate basis is deliberately
	# overwritten rather than composed in: a BoneAttachment3D under this rig's
	# Skeleton3D lives in the body's RAW model space, because setup() applies the
	# basis once at the ModelView above the skeleton and every bone transform
	# below it is pre-basis. Multiplying the piece's basis back in here applies it
	# twice and lands the grip 18.8 units off the hand, which is exactly what the
	# first version of this line did. Safe because the two bases are the same
	# transform anyway -- measured identical on all 41 body/hand pairs the eight
	# startcode classes declare.
	#
	# ORTHONORMALIZED, because G^-1 ALSO INVERTS G'S SCALE and that scale is not
	# ours to apply. A grip is a place to put the hilt, not a size for the
	# weapon: measured across the corpus the grips carry wildly different scales
	# -- SWORD.GRN's is 1.0000, SeraWindslicer's is 0.1497 and SeraWindweaver's
	# is 2.1800 -- so the raw inverse magnified the Seraphim's own starting blade
	# by 6.68x and shrank the other to 0.46x. At her campaign start that drew a
	# 49.2-unit sword as 328.9 units against a 74.3-unit SERAPHIM body (measured,
	# both from the built rigs' AABBs): the flat sheet lying across her in every
	# world capture, which three separate investigations mistook for a wing, a
	# shadow and a broken rig before this line was read. SWORD.GRN's unit grip is
	# why the --figure= viewer never showed it.
	#
	# HALF THE CORPUS IS A CONTROL GROUP, which is why this survived so long:
	# 101 of the 206 weapon-side grips are already unit (SWORD.GRN, SPEAR, every
	# SHIELD_*), and every viewer and check ever pointed at a weapon happened to
	# use one of those. Across the 105 scaled ones the values cluster PER EXPORT
	# BATCH -- 0.2297 shared by 21 files across VAMP_*/WEAPON_DUNKELELF_*/
	# MAGIERSTAB_*, 0.0799 by 12, 0.0964 by 7, 0.1497 by 6 -- which is a per-scene
	# Max helper-node scale, not a per-weapon size. The mesh vertices are already
	# authored at final world size, so neither s nor 1/s may be applied here, only
	# 1.0. Dropped, the 105 land in the same on-screen band as the 101 unit
	# controls (median 48.6 against the controls' median 33.4, max 97.6, against
	# bodies of 74-82); kept, they land at median 308 and max 1114.
	#
	# THE SCALE IS REAL FILE DATA, not a composition artefact: the scale_shear
	# blocks are clean uniform diagonals with off-diagonals exactly +-0 (e.g.
	# SK_HAMMER Bone_weapon_02 = 0.059148 on all three). Models.bones() must go
	# on reporting it faithfully; this dock is the one consumer that must not
	# apply it, which is why the fix lives here and not in formats/models.gd.
	#
	# MIRRORED GRIPS ARE OUT OF SCOPE and unchanged by this line: 9 grips have a
	# negative-determinant basis (AXE_BRIGHT, AXE_DARK, AXE_HEAVY, GREATAXE,
	# GREATAXE_1BLADE, HAMMER_ECKIG, HAMMER_HEAVY, HAMMER_NEO at -1.0000, and
	# GARDE_AXE at -1.2806). orthonormalized() preserves handedness, so those
	# weapons still dock point-mirrored exactly as they did under the raw
	# inverse. Whether retail mirrors them too is UNMEASURED.
	#
	# Dropping the scale keeps the alignment the line exists for: T maps the
	# grip's own origin to zero either way, so the hilt still lands on the hand;
	# only the magnification goes.
	#
	# GUARDED, because orthonormalized() DIVIDES BY EACH AXIS LENGTH and a grip
	# whose basis has a zero-length axis therefore comes back as NaN. Emitting
	# that transform does not merely misplace the weapon: it poisons the piece's
	# AABB, and a non-finite AABB stops the renderer presenting frames at all --
	# measured, as a run that streamed its 16 sectors normally and then hung
	# forever instead of settling, twice. A grip that cannot be normalised keeps
	# the raw inverse it has always had, which is wrong by a scale factor but
	# renders.
	# The guard tests the ANSWER, not the input. Checking the grip's axis
	# LENGTHS is not enough: Gram-Schmidt also emits NaN for a basis whose axes
	# are merely parallel, which has perfectly ordinary lengths, and a first
	# version of this guard passed such a grip straight through.
	var g := grip as Transform3D
	var t := Transform3D(g.basis.orthonormalized(), g.origin).affine_inverse()
	if not _is_finite_transform(t):
		push_warning("ModelView.attach_socket: entry %d grip for %s does not normalise (scale %s) -- keeping the raw inverse" % [
			entry, socket, str(g.basis.get_scale())])
		t = g.affine_inverse()
	piece.transform = t
	_affine_sockets.append(att)
	sockets_attached += 1
	return piece

## Puts a SKINNED garment on this rig: the piece's mesh is added under THIS
## skeleton and its skin re-bound to this skeleton's bones BY NAME, so it
## deforms with the body instead of standing beside it. This is the armour
## path; attach_socket above is the weapon path, and they are different because
## the files are different (granny-grn.md, "A weapon is a rigid prop, not a
## second garment").
##
## WHY BY NAME IS ENOUGH, measured rather than assumed. R1.4 (checks/
## equip_check.gd) confirmed armour shares its wearer's skeleton on the local
## instrument -- for the SERA family, 0.9123 own-agreement against a 0.2059
## cross-character control over 72 pieces. And the naming gap that looks fatal
## is not: Uriel's Legacy pieces carry 75-77 bones against the body's 72, but
## every extra one (`Angel_armor_Breast`, `Bip01 Ponytail1`, the two
## `Spot*.Target` light aims) is an UNWEIGHTED locator. Across the seven pieces
## the count of bones that are weighted AND absent from the body is ZERO, which
## is why the refusal below tests the BIND SET and not the bone list -- testing
## the bone list would refuse every garment in the game.
##
## Returns the added MeshInstance3D, or null on refusal. Refusals are ordinary
## and counted, never approximated: a garment half-bound to the wrong bones is
## worse than a character without it.
func attach_skinned(models: Sacred.Models, entry: int, texture: int = -1) -> MeshInstance3D:
	if _skeleton == null:
		return null
	var piece := ModelView.new()
	piece.name = "Worn_%d" % entry
	piece.set_texture_pak(_texture_pak)
	piece.item_texture = texture
	if not piece.setup(models, entry, false):
		piece.free()
		worn_refused += 1
		return null
	# A prop has no skin to re-bind, and an entry whose weights did not decode
	# reaches here with _skin null as well -- both are refusals, and the caller
	# is told which by mesh_weights' own push_error rather than by a guess here.
	if piece._skeleton == null or piece._skin == null or piece._skin.get_bind_count() == 0:
		piece.free()
		worn_refused += 1
		return null
	# Bind ORDER is what the mesh's ARRAY_BONES indexes, so the remap keeps the
	# order and changes only which skeleton each bind points into. The bind
	# POSE is the WEARER's -- the inverse of the same-named bone's global rest
	# in THIS skeleton, exactly what _build_rig gave this body's own vertices
	# -- not the piece's own bind pose. Row 1121 measured why: garment and
	# wearer rest poses disagree on most shared bones (SeraBoots01 vs
	# SERAPHIM: only 1 of 4 shared weighted bones agrees), so binding through
	# the piece's own poses deforms the garment as if its rest were the
	# wearer's. Row 1122 measured the wearer-rest inverse against retail's own
	# render: the upper body lands on retail's pixels; residual offsets are
	# per-bone and small.
	#
	# NAMES ALONE DO NOT SAY THE GARMENT FITS, and the control is what showed
	# it: offered Uriel's Legacy, GLADIATOR.GRN binds 5 pieces and refuses 2 --
	# exactly SERAPHIM.GRN's own score. Every humanoid shares the `Bip01 *`
	# biped names, so a name-only test discriminates nothing, which is the same
	# way the weapon-socket instrument once "measured" its own sockets agreeing
	# with themselves (granny-grn.md). rust.bin exists precisely because a
	# garment is per-wearer, so binding one to the wrong body is a real error
	# and not a curiosity.
	#
	# So the admission test is GEOMETRIC, and it is R1.4's local instrument
	# (checks/equip_check.gd): a bind bone's own rest transform in the garment,
	# compared to the same-named bone's rest in this body, chain never composed.
	# Measured over Uriel's seven pieces: SERAPHIM agrees on 1/1, 1/15, 5/7,
	# 3/5 and 2/7 bind bones, while GLADIATOR and DWARF agree on ZERO of every
	# one. The rule is therefore "at least one bind bone agrees" -- weak-looking
	# and totally separating on what has been measured.
	# ponytail: `> 0` is the threshold the evidence supports, not a tuned one.
	# The own-rates are low and uneven because a garment poses fingers and
	# extremities freely; a per-bone fit score would be a better rule and needs
	# a wider measurement than five pieces to set a cut on.
	var skin := Skin.new()
	var agreed := 0
	var uses_foot := false
	for i in piece._skin.get_bind_count():
		var pb := piece._skin.get_bind_bone(i)
		var nm := piece._skeleton.get_bone_name(pb)
		var b := _skeleton.find_bone(nm)
		if b < 0:
			piece.free()
			worn_refused += 1
			return null
		if nm.ends_with("Foot"):
			uses_foot = true
		var pr := piece._skeleton.get_bone_rest(pb)
		var wr := _skeleton.get_bone_rest(b)
		if pr.origin.distance_to(wr.origin) < FIT_WITHIN \
				and pr.basis.get_rotation_quaternion().angle_to(wr.basis.get_rotation_quaternion()) < FIT_WITHIN:
			agreed += 1
	# Foot-weighted garments (boots) sit far from the wearer's rest for their
	# weighted bones (row 1121: 1/4 agree), so the wearer-rest bind leaves them
	# at the piece's authored floor position -- on the ground. Those retarget
	# through the piece's own rest inverse, the granny name-remap; vertices
	# weighted to a single bone are rigid with that bone under it, which is
	# where they must land. Multi-bone upper garments keep the wearer-rest
	# bind row 1122 calibrated against retail's pixels.
	for i in piece._skin.get_bind_count():
		var pb := piece._skin.get_bind_bone(i)
		var b := _skeleton.find_bone(piece._skeleton.get_bone_name(pb))
		if uses_foot:
			skin.add_bind(b, piece._skeleton.get_bone_global_rest(pb).affine_inverse())
		else:
			skin.add_bind(b, _skeleton.get_bone_global_rest(b).affine_inverse())
	if agreed == 0:
		# This garment was cut for a different body. Refused rather than bound
		# to a skeleton whose bones sit somewhere else.
		piece.free()
		worn_refused += 1
		return null
	var src: MeshInstance3D = piece.get_node_or_null("Skeleton/Mesh")
	if src == null or src.mesh == null:
		piece.free()
		worn_refused += 1
		return null
	var mi := MeshInstance3D.new()
	mi.name = "Worn_%d" % entry
	mi.mesh = src.mesh
	for s in src.mesh.get_surface_count():
		mi.set_surface_override_material(s, src.get_surface_override_material(s))
	_skeleton.add_child(mi)
	mi.skeleton = NodePath("..")
	mi.skin = skin
	_affine_meshes.append(mi)
	# The mesh and its materials are Resources and outlive the node they were
	# built under, so the scratch rig goes away here rather than lingering as a
	# second, invisible skeleton under this one.
	piece.free()
	worn_attached += 1
	return mi

## Dynamic garment-hiding (row 1125's rule, slot-driven): after a garment
## binds, hide the base-body surfaces its slot displaces by swapping their
## override material for an invisible one; show_base_surfaces restores the
## originals. Token matching is case-less substring against the surface's
## material name -- per-class names differ (Angel_body vs Gladiator_body),
## so exact strings cannot work. The emit-time hide_materials array stays
## for build-time hiding; this is the runtime half, driven by which slots
## ACTUALLY hold a piece rather than by what the set contains (the static
## derivation hid base shoes even when nothing was worn -- findings row with
## this change).
var _hidden_orig := {}
var _invisible_mat: StandardMaterial3D = null

func set_materials_hidden_by_token(tokens: PackedStringArray, hidden: bool) -> void:
	var mesh_mi: MeshInstance3D = get_node_or_null("Skeleton/Mesh") as MeshInstance3D
	if mesh_mi == null:
		mesh_mi = get_node_or_null("Mesh") as MeshInstance3D
	if mesh_mi == null:
		return
	if _invisible_mat == null:
		_invisible_mat = StandardMaterial3D.new()
		_invisible_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_invisible_mat.albedo_color = Color(0.0, 0.0, 0.0, 0.0)
	for s in surface_texture.size():
		var nm := String(surface_texture[s]).to_lower()
		var hit := false
		for tok in tokens:
			if nm.contains(String(tok).to_lower()):
				hit = true
				break
		if not hit:
			continue
		if hidden:
			if not _hidden_orig.has(s):
				_hidden_orig[s] = mesh_mi.get_surface_override_material(s)
			mesh_mi.set_surface_override_material(s, _invisible_mat)
		elif _hidden_orig.has(s):
			mesh_mi.set_surface_override_material(s, _hidden_orig[s])
			_hidden_orig.erase(s)

## --- Actor blob shadow ------------------------------------------------------
##
## The observed branch is LGP 0x080FE8DA / Win 2.28 0x00407960, not either
## projected-mesh branch. Configuration is explicit: a model filename cannot
## supply actor eligibility, radius, support height or native placement.
const ActorBlobShadow := preload("res://view/actor_blob_shadow.gd")
var _blob_shadow: ActorBlobShadow = null

## `native_actor_basis` maps the unplaced, unscaled, unrotated posed model into
## native actor-relative coordinates (native orientation * model-header scale).
## `retail_to_port` maps native Z-up deltas into the world's screen-plane basis.
## No implicit identity/camera/size fallback is installed for unknown branches.
func configure_blob_shadow(radius: float, placement: SkeletonModifier3D,
		native_actor_basis: Basis, retail_to_port: Basis) -> bool:
	disable_blob_shadow()
	if _skeleton == null or _texture_pak == null:
		return false
	if radius <= 0.0 or not is_finite(radius) or placement == null:
		return false
	var tid := Sacred.TextureFormat.find_model_texture(_texture_pak, "SHADOWDOT.TGA")
	if tid < 0:
		return false
	# Use the decoder's actual dimensions and ARGB4444 -> RGBA8 conversion.
	# run02's named resource is byte-identical to this decode, not GL name 81.
	var image := Sacred.TextureFormat.decode_texture(_texture_pak, tid, false)
	if image == null:
		return false
	var shadow := ActorBlobShadow.new()
	shadow.name = "ActorBlobShadow"
	add_child(shadow)
	shadow.configure(_skeleton, ImageTexture.create_from_image(image), radius,
		placement, native_actor_basis, retail_to_port)
	_blob_shadow = shadow
	return true


func disable_blob_shadow() -> void:
	if _blob_shadow != null:
		_blob_shadow.free()
		_blob_shadow = null


func update_shadow_ground(world_origin: Vector3, ground_height: float) -> void:
	if _blob_shadow != null:
		_blob_shadow.update_ground(world_origin, ground_height)


func update_blob_shadow_transform(native_actor_basis: Basis) -> void:
	if _blob_shadow != null:
		_blob_shadow.native_actor_basis = native_actor_basis


## Manual pose consumers use the same refresh as skeleton_updated.
func refresh_drop_shadow() -> void:
	if _blob_shadow != null:
		_blob_shadow.refresh_pose()


func blob_shadow() -> ActorBlobShadow:
	return _blob_shadow

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
	if _texture_pak == null:
		return mat
	# THE ITEM'S SKIN WINS, and it is consulted BEFORE the slot because retail
	# consults it before the name: bindTextures prefers its override whenever
	# that is non-zero and never looks the mesh's own texture name up in that
	# case (Sacred.Items.TEXTURE_OFF). A kite shield has no other route at all --
	# the name its mesh carries ships in no pak, and the twelve items naming that
	# one mesh are the only thing that tells the twelve skins apart.
	if item_texture >= 0:
		var oimg := Sacred.TextureFormat.decode_texture(_texture_pak, item_texture, false)
		if oimg == null:
			return mat
		if not surface_texture.is_empty():
			surface_texture[surface_texture.size() - 1] = "item:%d" % item_texture
		mat.albedo_texture = ImageTexture.create_from_image(oimg)
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
		mat.albedo_color = Color.WHITE
		textured_surfaces += 1
		return mat
	if slot < 0:
		return mat
	var names := models.texture_names(entry)
	# THE MATERIAL IS NOT THE TEXTURE. `slot` is the draw batch's MATERIAL index;
	# the material then names a texture, and on GLADIATOR that mapping is the
	# permutation 2,6,1,3,4,5 rather than the identity. Using slot directly put
	# the head on the body image and an arm on the boots image while every batch
	# still carried plausible leather -- see Models.material_textures.
	var link := models.material_textures(entry)
	var tex_slot := slot
	if slot >= 0 and slot < link.size():
		tex_slot = link[slot]
	elif not link.is_empty():
		# The entry has a material table and this batch is not in it. Clay is the
		# honest answer; guessing an index is what produced the scrambled skin.
		tex_slot = -1
	if tex_slot < 0 or tex_slot >= names.size():
		return mat
	var tid := Sacred.TextureFormat.find_model_texture(_texture_pak, names[tex_slot])
	if tid < 0:
		return mat
	# render=FALSE, and the difference is not a detail. The payload is ARGB4444;
	# the render=true branch hands those bytes to Godot as FORMAT_RGBA4444, which
	# rotates every channel by one -- the real ALPHA is read as red and the real
	# BLUE as alpha. Measured on Gladiator_body.tga: (1.00,0.41,0.32) a=0.28
	# against the correct (0.41,0.32,0.28) a=1.00.
	#
	# Terrain can live with that because it samples through its own shader; a
	# StandardMaterial3D cannot. Combined with the TRANSPARENCY_ALPHA that
	# player_view.gd sets for depth sorting, an average alpha of 0.28 with NO
	# fully-opaque pixel rendered every character nearly invisible while the
	# untextured weapons stayed solid -- the whole body of the defect that made
	# the world look like floating weapons.
	#
	# Correctly decoded the alpha is real: Gladiator and Wolf are fully opaque
	# (a1=1.000) and Horse carries genuine cutouts (a1=0.877), so the transparent
	# pass is still the right one to draw in.
	var img := Sacred.TextureFormat.decode_texture(_texture_pak, tid, false)
	if img == null:
		return mat
	if not surface_texture.is_empty():
		surface_texture[surface_texture.size() - 1] = names[tex_slot].get_file()
	mat.albedo_texture = ImageTexture.create_from_image(img)
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	mat.albedo_color = Color.WHITE
	textured_surfaces += 1
	return mat


## Returns the mean Y of triangles in submesh `pm` from index buffer `idx`,
## reading vertex_mesh to find which triangles belong to `pm`. Used to sort
## the per-group surface emit into back-to-front painter's order so
## no_depth_test=true keeps the rig from reading as torn (row 1184).
func _submesh_mean_y(m: Dictionary, idx: PackedInt32Array, vmesh: PackedInt32Array, pm: int) -> float:
	var pos: PackedVector3Array = m["positions"]
	var n := 0
	var s := 0.0
	for t in idx.size() / 3:
		if vmesh[idx[t * 3]] != pm:
			continue
		s += pos[idx[t * 3]].y + pos[idx[t * 3 + 1]].y + pos[idx[t * 3 + 2]].y
		n += 3
	return s / n if n > 0 else 0.0

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
	# The two orderings are reconciled by the FILE'S OWN REFERENCE --
	# models.group_submesh(), which reads each group's FormMesh payload. This
	# replaced a reconciliation by TRIANGLE COUNT that refused the split
	# whenever two submeshes had the same face count: 143 of 1567 entries hit
	# that, and the twelve of them naming more than one texture rendered as
	# flat clay, because one merged surface has no single material to carry.
	# The count rule agreed with the reference wherever it decided at all
	# (1563 of 1565 entries), so this is the same answer without the refusals.
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

	# The file's own group -> submesh answer, one entry per group in the same
	# order. A group naming no drawable submesh refuses the split rather than
	# landing its triangles on a neighbour.
	var g2p := models.group_submesh(entry)
	var mat_names := models.material_names(entry)
	var split := groups.size() > 1 and g2p.size() == groups.size()
	if split:
		for gi in groups.size():
			if not port_faces.has(g2p[gi]):
				split = false
				break

	var mesh := ArrayMesh.new()
	var mats: Array[StandardMaterial3D] = []
	if split:
		# EACH GROUP NAMES ITS OWN TRIANGLES. The previous version sliced the
		# submesh's index range in group order, which assumed the groups were
		# laid out contiguously. They are not: GLADIATOR's 442-triangle leg
		# submesh splits 212 skin / 230 boot with the boot's indices running
		# 28..441 interleaved through the skin's, so the slice put half a boot on
		# a thigh and sampled the empty background of the wrong image.
		#
		# tri_index is exact -- across a submesh's groups it covers 0..n-1 once --
		# so there is no ordering assumption left here at all.
		# PAINTER'S-ORDER (findings row 1184): the surfaces are emitted in
		# port_order, which is the order sub-meshes appear in the index buffer --
		# not back-to-front, so the back-facing halves of the body draw AFTER
		# the front-facing halves, and the rig reads as torn. Sort by sub-mesh
		# mean Y DESCENDING so the back of the body draws first and the front
		# of the body draws last. With no_depth_test=true the transparent queue
		# takes this order as-is, which is exactly the regime object sprites
		# already live in.
		var _pm2_with_y: Array = []
		for _pm3 in port_order:
			_pm2_with_y.append([_pm3, _submesh_mean_y(m, idx, vmesh, _pm3)])
		_pm2_with_y.sort_custom(func(a, b): return a[1] > b[1])
		for _pm2_pair in _pm2_with_y:
			var pm2: int = _pm2_pair[0]
			# Triangles of this submesh no group named. Retail binds a texture
			# per batch, so geometry outside every batch has no material to
			# draw with -- but dropping it silently is how a character loses a
			# limb, so it is counted here and emitted below as clay.
			var claimed := {}
			for gi2 in groups.size():
				if g2p[gi2] != pm2:
					continue
				for t3 in (groups[gi2].get("tri_index", PackedInt32Array()) as PackedInt32Array):
					claimed[t3] = true
			for gi2 in groups.size():
				if g2p[gi2] != pm2:
					continue
				var g2: Dictionary = groups[gi2]
				var picks: PackedInt32Array = g2.get("tri_index", PackedInt32Array())
				if picks.size() != int(g2["triangles"]):
					split = false
					break
				# GARMENT-HIDING (row 1125). A hidden material's triangles stay
				# claimed -- they were named by a batch, so letting them fall
				# through to the leftovers pass would redraw them as clay -- but
				# no surface is emitted for them.
				if not hide_materials.is_empty() \
						and int(g2["material"]) >= 0 and int(g2["material"]) < mat_names.size() \
						and hide_materials.has(mat_names[int(g2["material"])]):
					continue
				var start: int = int(port_start[pm2])
				var gi := PackedInt32Array()
				gi.resize(picks.size() * 3)
				var bad := false
				for t2 in picks.size():
					var gt: int = start + picks[t2]
					if gt < 0 or gt * 3 + 2 >= idx.size():
						bad = true
						break
					gi[t2 * 3] = idx[gt * 3]
					gi[t2 * 3 + 1] = idx[gt * 3 + 1]
					gi[t2 * 3 + 2] = idx[gt * 3 + 2]
				if bad:
					split = false
					break
				var sub := arr.duplicate()
				sub[Mesh.ARRAY_INDEX] = gi
				mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sub)
				var mat_name: String = mat_names[int(g2["material"])] if g2["material"] >= 0 and g2["material"] < mat_names.size() else "<unknown>"
				surface_texture.append(mat_name)
				surface_material.append(int(g2["material"]))
				mats.append(_skin_material(models, entry, int(g2["material"])))
			if not split:
				break
			# TRIANGLES NO GROUP CLAIMS -- SKIPPED, NOT DRAWN AS CLAY. A batch
			# is what names a texture, so geometry outside every batch has no
			# stated material to draw with. The earlier port drew those triangles
			# as <clay> for entries naming exactly one texture (the single-texture
			# fallback): doors, vases, chests kept every triangle they had.
			# That rule is REFUTED: ELVE_SORCESS's six unclaimed 14-triangle
			# submeshes rendered as a column of pale lumps down her spine, and
			# retail's own draw loop binds glDrawElements to dword_9551F14 from
			# sub_8624508 at 0x8625404 with one indexed GL_TRIANGLES call per
			# declared batch -- no implicit material, no separate pass reaches
			# leftovers on any single-texture entry either (row 1167). Counting
			# but skipping all unclaimed geometry is the correct rule.
			# `ungrouped_triangles` publishes the residue so the count is
			# measurable even though no surface is emitted for it.
			var rest := PackedInt32Array()
			for t4 in int(port_faces[pm2]):
				if claimed.has(t4):
					continue
				var rt: int = int(port_start[pm2]) + t4
				if rt * 3 + 2 >= idx.size():
					continue
				rest.append(idx[rt * 3])
				rest.append(idx[rt * 3 + 1])
				rest.append(idx[rt * 3 + 2])
	if not split and ungrouped_triangles == 0:
		# Single-texture fallback -- only when the per-group split failed AND
		# there are no ungrouped triangles. The legacy code emitted a single
		# "<clay>" surface for any entry that did not split, but that fallback
		# is what wire_c_ungrouped_check removes. When the split succeeded the
		# per-group surfaces above stay intact; when it failed AND there are
		# leftovers, retail draws nothing for them so the surface count is
		# whatever the partial split produced.
		mesh = ArrayMesh.new()
		mats.clear()
		textured_surfaces = 0
		surface_texture.clear()
		surface_material.clear()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		var fallback_name: String = mat_names[0] if mat_names.size() > 0 else ""
		surface_texture.append(fallback_name)
		surface_material.append(0 if textures_named == 1 else -1)
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
		_affine_meshes.append(mi)
	else:
		add_child(mi)

	# The AABB the camera must frame is the one the viewer sees, so it is the
	# local AABB carried through this node's basis, not the raw one.
	if frame_camera:
		_frame(transform * mesh.get_aabb())
	_settled = true
	_standalone_render = frame_camera
	if _standalone_render and is_inside_tree() \
			and not RenderingServer.frame_pre_draw.is_connected(prepare_render):
		RenderingServer.frame_pre_draw.connect(prepare_render)
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
	_affine_rests.resize(n)
	_affine_rest_rotations.resize(n)
	_affine_rest_scales.resize(n)
	_affine_rest_pose_inverse.resize(n)
	_affine_positions.resize(n)
	_affine_rotations.resize(n)
	_affine_roots.resize(n)
	affine_global_poses.resize(n)
	var used := {}
	bone_roots = 0
	bone_sanitised = 0
	for g in order:
		var raw: PackedByteArray = bl[g]["name"]
		var stored := raw.get_string_from_ascii().strip_edges()
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
		_affine_rests[s] = bl[g]["rest"]
		_affine_rest_rotations[s] = bl[g]["rotation"]
		var ss := _scale_shear_basis(bl[g]["scale_shear"])
		_affine_rest_scales[s] = ss
		if not ss.is_equal_approx(Basis.from_scale(Vector3(ss.x.x, ss.y.y, ss.z.z))):
			_affine_rest_required = true
	# A fresh bone's POSE is not its rest -- it defaults to the identity, which
	# collapses every bone onto the origin and produces a crumpled model that
	# still renders. There is no animation in this plan, so the pose is the
	# rest; letting the engine derive it keeps rest and pose using the same
	# decomposition rather than a hand-rolled one.
	_skeleton.reset_bone_poses()
	bone_count = n
	for s in n:
		if _skeleton.get_bone_parent(s) < 0:
			_affine_rest_pose_inverse[s] = _skeleton.get_bone_pose(s).affine_inverse()
	_affine_required = _affine_rest_required
	_skeleton.skeleton_updated.connect(_capture_affine_pose)
	_capture_affine_pose()

	# One bind per bone something is actually weighted to, added in mesh-local
	# order, which is how space 3 gets its ordering.
	_skin = Skin.new()
	var skel_to_bind := PackedInt32Array()
	skel_to_bind.resize(n)
	skel_to_bind.fill(-1)
	# A RIGID PROP is not a decode failure. 199 of the 221 entries carrying a
	# weapon-side grip declare no MeshWeights at all: a sword's bones are
	# locators (the grip, the fx emitters), and nothing deforms. Those build as
	# an unskinned mesh and keep their bone TRANSFORMS available for docking.
	#
	# The loud failure below is kept for the other case -- weights declared and
	# unreadable -- because that IS the silently-unskinned render this class
	# refuses to make. has_mesh_weights() is what separates the two; without it
	# mesh_weights()' empty answer means both.
	if not models.has_mesh_weights(entry):
		is_prop = true
		bone_rests = bl
		_discard_rig()
		return true
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

# ---------------------------------------------------------------------
## Interpolation mode 2, decoded 2026-09-01 (row 1219): a corner-cutting
## quadratic B-spline. The keys are CONTROL POINTS, not points on the curve
## -- at each knot the curve equals the time-weighted blend of that knot's
## two neighbours (uniform case: their average), and the value inside a span
## is a three-key weighted blend.open-grn's runtime sampler documents the
## exact basis and the vendor's leading/trailing pads pin endpoint sampling
## to the endpoint keys. Endpoints are authored poses, not necessarily the
## model's bind pose (finding 1247). Corpus: position and quaternion mode is
## 2 on ALL 255,461 ordinary tracks; even key counts exist (9,956 position
## records), which REFUTES the rival Bézier-triples reading needing odd
## counts; all recorded key times are strictly ascending, which is all this
## basis needs.
##
## Godot Animation tracks interpolate linearly through keys and offer no
## custom basis, so the curve is honoured by SUBDIVISION: QUAD_SUBDIV linear
## keys per key span. ponytail: this approximates the curve; no universal
## subpixel bound is established. After preserving control magnitudes,
## running rotation error is 0.023 degrees versus 0.000039 at exact time.
const QUAD_SUBDIV := 8

static func _quad_weights(ta: float, tb: float, tc: float, td: float,
		t: float) -> Vector3:
	## The runtime's quadratic basis over the bracket (tb, tc) with the
	## neighbouring control times ta and td. Returns (-1, 0, 0) as the
	## refuse signal -- the caller falls back to the linear path.
	if tc - tb <= 0.0 or tc - ta <= 0.0:
		return Vector3(-1, 0, 0)
	var f1 := (t - tb) / (tc - tb)
	var f2 := (t - ta) / (tc - ta)
	var g := f1 + f2 - f1 * f2
	var h := 0.0
	if td > tb:
		h = ((t - tb) / (td - tb)) * f1
	return Vector3(1.0 - g, g - h, h)

func _resample_quad_rot(times: PackedFloat32Array, keys: Array) -> Array:
	## One mode-2 rotation channel -> [t, Quaternion] pairs at QUAD_SUBDIV
	## per span. [] = refused (non-ascending times); caller falls back loud.
	var out: Array = []
	var n := times.size()
	if n == 0:
		return out
	for i in range(1, n):
		if times[i] <= times[i - 1]:
			push_error("ModelView: mode-2 track has non-ascending times at key %d" % i)
			return []
	for j in n - 1:
		var ia := maxi(j - 1, 0)
		var ic := mini(j + 1, n - 1)
		var idd := mini(j + 2, n - 1)
		var ta: float = times[ia]
		var td: float = times[idd]
		var ka: Quaternion = keys[ia]
		var kb: Quaternion = keys[j]
		var kc: Quaternion = keys[ic]
		# The runtime aligns each neighbour to the bracket's upper key
		# hemisphere before blending; without this a crossing q sign
		# flips the curve mid-span.
		if ka.dot(kc) < 0.0:
			ka = -ka
		if kb.dot(kc) < 0.0:
			kb = -kb
		for s in QUAD_SUBDIV:
			var t: float = lerpf(times[j], times[ic], float(s) / QUAD_SUBDIV)
			var w := _quad_weights(ta, times[j], times[ic], times[idd], t)
			out.append([t, (w.x * ka + w.y * kb + w.z * kc).normalized()])
	out.append([times[n - 1], keys[n - 1]])
	return out

func _resample_quad_pos(times: PackedFloat32Array, keys: PackedVector3Array) -> Array:
	## The position-channel twin of _resample_quad_rot (no hemisphere fix).
	var out: Array = []
	var n := times.size()
	if n == 0:
		return out
	for i in range(1, n):
		if times[i] <= times[i - 1]:
			push_error("ModelView: mode-2 position track has non-ascending times at key %d" % i)
			return []
	for j in n - 1:
		var ia := maxi(j - 1, 0)
		var ic := mini(j + 1, n - 1)
		var idd := mini(j + 2, n - 1)
		var ta: float = times[ia]
		var td: float = times[idd]
		var ka: Vector3 = keys[ia]
		var kb: Vector3 = keys[j]
		var kc: Vector3 = keys[ic]
		for s in QUAD_SUBDIV:
			var t: float = lerpf(times[j], times[ic], float(s) / QUAD_SUBDIV)
			var w := _quad_weights(ta, times[j], times[ic], times[idd], t)
			out.append([t, w.x * ka + w.y * kb + w.z * kc])
	out.append([times[n - 1], keys[n - 1]])
	return out

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
	var affine_tracks := {}
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
		var scale_keys: Array[Basis] = []
		for values: PackedFloat32Array in r["others"]:
			scale_keys.append(_scale_shear_basis(values))
		affine_tracks[skel_idx] = {
			"times": r["times_other"], "keys": scale_keys, "mode": int(r["scale_mode"]),
			"position": not (r["times_pos"] as PackedFloat32Array).is_empty(),
			"rotation": not (r["times_rot"] as PackedFloat32Array).is_empty(),
		}
		var path := NodePath("%s:%s" % [_skeleton.name, nm])
		var times_pos: PackedFloat32Array = r["times_pos"]
		var positions: PackedVector3Array = r["positions"]
		if times_pos.size() > 0:
			var pt := anim.add_track(Animation.TYPE_POSITION_3D)
			anim.track_set_path(pt, path)
			var pos_keys: Array = []
			var pos_mode: int = int(r.get("pos_mode", 1))
			if pos_mode == 2:
				pos_keys = _resample_quad_pos(times_pos, positions)
				if pos_keys.is_empty():
					pos_mode = 1  # refusal logged at the resampler
			if pos_mode == 2:
				for pair in pos_keys:
					anim.position_track_insert_key(pt, pair[0], pair[1])
			else:
				if pos_mode == 0:
					anim.track_set_interpolation_type(pt, Animation.INTERPOLATION_NEAREST)
				elif pos_mode > 1:
					push_error("ModelView.build_animation: position mode %d is outside the decoded corpus (0..2); playing linear" % pos_mode)
				for i in times_pos.size():
					anim.position_track_insert_key(pt, times_pos[i], positions[i])
			tracks += 1
		var times_rot: PackedFloat32Array = r["times_rot"]
		var rotations: Array = r["rotations"]
		if times_rot.size() > 0:
			var rt := anim.add_track(Animation.TYPE_ROTATION_3D)
			anim.track_set_path(rt, path)
			# Authored keys are absolute LOCAL poses, not deltas from clip rest.
			# Native Seraphim and novice-nun captures match direct keys; the old
			# model_rest * clip_rest.inverse() correction introduced up to 90°
			# of error. Position tracks carry authored motion too (finding 1247).
			var rot_keys: Array = []
			var quat_mode: int = int(r.get("quat_mode", 1))
			if quat_mode == 2:
				rot_keys = _resample_quad_rot(times_rot, rotations)
				if rot_keys.is_empty():
					quat_mode = 1  # refusal logged at the resampler
			if quat_mode == 2:
				for pair in rot_keys:
					anim.rotation_track_insert_key(rt, pair[0],
						(pair[1] as Quaternion).normalized())
			else:
				if quat_mode == 0:
					anim.track_set_interpolation_type(rt, Animation.INTERPOLATION_NEAREST)
				elif quat_mode > 1:
					push_error("ModelView.build_animation: rotation mode %d is outside the decoded corpus (0..2); playing linear" % quat_mode)
				# clip() only checks unit-length to within a decode
				# discriminator, not a precision claim; Godot's rotation
				# tracks demand exact units and log per frame otherwise.
				# normalized() re-scales the SAME already-accepted rotation
				# rather than changing what was decoded.
				for i in times_rot.size():
					anim.rotation_track_insert_key(rt, times_rot[i],
						(rotations[i] as Quaternion).normalized())
			tracks += 1

	return {"animation": anim, "bound": bound, "tracks": tracks,
		"unbound_names": unbound, "affine_tracks": affine_tracks}


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
	_affine_tracks = built["affine_tracks"]
	_affine_required = _affine_rest_required
	for bone: int in _affine_tracks:
		for ss: Basis in _affine_tracks[bone]["keys"]:
			if not ss.is_equal_approx(_affine_rest_scales[bone]):
				_affine_required = true
				break
	if not _affine_required and _skeleton.has_meta(&"affine_global_poses"):
		_skeleton.remove_meta(&"affine_global_poses")
	_capture_affine_pose()
	return true


## Row-major SS payload; do not extract a scale vector or orthogonalize it.
static func _scale_shear_basis(values: PackedFloat32Array) -> Basis:
	return Basis(Vector3(values[0], values[3], values[6]),
		Vector3(values[1], values[4], values[7]), Vector3(values[2], values[5], values[8]))


func _capture_affine_pose() -> void:
	if not _affine_required:
		return
	# skeleton_updated precedes restoration of modifier-written placement.
	_affine_time = _anim_player.current_animation_position if _anim_player != null \
		and not _anim_player.current_animation.is_empty() else 0.0
	for bone in _skeleton.get_bone_count():
		_affine_positions[bone] = _skeleton.get_bone_pose_position(bone)
		_affine_rotations[bone] = _skeleton.get_bone_pose_rotation(bone)
		if _skeleton.get_bone_parent(bone) < 0:
			# Apply the same external placement delta to the untouched affine
			# rest, rather than replacing its shear with a decomposed root.
			_affine_roots[bone] = _skeleton.get_bone_pose(bone) \
				* _affine_rest_pose_inverse[bone] * _affine_rests[bone]


static func _blend_scale_shear(a: Basis, b: Basis, amount: float) -> Basis:
	return Basis(a.x.lerp(b.x, amount), a.y.lerp(b.y, amount), a.z.lerp(b.z, amount))


func _sample_scale_shear(track: Dictionary, time: float, rest: Basis) -> Basis:
	var times: PackedFloat32Array = track["times"]
	var keys: Array[Basis] = track["keys"]
	if times.is_empty():
		return rest
	if time <= times[0] or times.size() == 1:
		return keys[0]
	var last := times.size() - 1
	if time >= times[last]:
		return keys[last]
	var upper := times.bsearch(time, false)
	var lower := upper - 1
	var mode: int = track["mode"]
	if mode == 0:
		return keys[lower]
	if mode == 2:
		var before := maxi(lower - 1, 0)
		var after := mini(upper + 1, last)
		var weights := _quad_weights(times[before], times[lower],
			times[upper], times[after], time)
		var a := keys[before]
		var b := keys[lower]
		var c := keys[upper]
		return Basis(a.x * weights.x + b.x * weights.y + c.x * weights.z,
			a.y * weights.x + b.y * weights.y + c.y * weights.z,
			a.z * weights.x + b.z * weights.y + c.z * weights.z)
	return _blend_scale_shear(keys[lower], keys[upper],
		(time - times[lower]) / (times[upper] - times[lower]))


## Called at frame_pre_draw before crop, sockets, shadows or skin consumption.
## LGP 0x08074996 multiplies R by all nine SS elements; 0x08074F9C then
## composes the parent. Godot's GPU palette accepts the resulting full matrix.
func prepare_render() -> void:
	if _affine_required and _skeleton != null:
		for bone in _skeleton.get_bone_count():
			var local := _affine_rests[bone]
			var parent := _skeleton.get_bone_parent(bone)
			if parent < 0:
				local = _affine_roots[bone]
			elif _affine_tracks.has(bone):
				var track: Dictionary = _affine_tracks[bone]
				var rotation := _affine_rotations[bone] if track["rotation"] \
					else _affine_rest_rotations[bone]
				local.basis = Basis(rotation) \
					* _sample_scale_shear(track, _affine_time, _affine_rest_scales[bone])
				if track["position"]:
					local.origin = _affine_positions[bone]
			affine_global_poses[bone] = local if parent < 0 \
				else affine_global_poses[parent] * local
		_skeleton.set_meta(&"affine_global_poses", affine_global_poses)
		for mesh in _affine_meshes:
			if not is_instance_valid(mesh) or not mesh.is_inside_tree():
				continue
			var reference := mesh.get_skin_reference()
			if reference == null:
				continue
			var skin := reference.get_skin()
			var palette := reference.get_skeleton()
			for bind in skin.get_bind_count():
				var bone := skin.get_bind_bone(bind)
				var bone_name := skin.get_bind_name(bind)
				if not bone_name.is_empty():
					bone = _skeleton.find_bone(bone_name)
				RenderingServer.skeleton_bone_set_transform(palette, bind,
					affine_global_poses[bone] * skin.get_bind_pose(bind))
		if _blob_shadow != null:
			_blob_shadow.refresh_pose()
		for attachment in _affine_sockets:
			if is_instance_valid(attachment):
				attachment.transform = affine_global_poses[attachment.bone_idx]
	for attachment in _affine_sockets:
		if not is_instance_valid(attachment):
			continue
		for child in attachment.get_children():
			if child is ModelView:
				child.prepare_render()


func _enter_tree() -> void:
	if _standalone_render and not RenderingServer.frame_pre_draw.is_connected(prepare_render):
		RenderingServer.frame_pre_draw.connect(prepare_render)


func _exit_tree() -> void:
	if RenderingServer.frame_pre_draw.is_connected(prepare_render):
		RenderingServer.frame_pre_draw.disconnect(prepare_render)


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


## True while a clip is loaded and playing. Read by E1's Checkpoint via
## main._anim_clip_state().
func is_playing() -> bool:
	return _anim_player != null and not _anim_player.current_animation.is_empty() \
		and _anim_player.is_playing()


## The playing clip's current position, or NAN when nothing is playing. THE
## ONLY sanctioned clock read: capture-side, never drives gameplay.
func anim_time() -> float:
	if _anim_player == null or _anim_player.current_animation.is_empty():
		return NAN
	return _anim_player.current_animation_position


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
		names.append((b["name"] as PackedByteArray).get_string_from_ascii().strip_edges())
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


## True when every component of `t` is a real number. A non-finite transform is
## not merely a misplaced object: it poisons the instance's AABB, and the
## renderer then stops presenting frames entirely, which reads as the whole run
## hanging rather than as anything to do with this mesh.
static func _is_finite_transform(t: Transform3D) -> bool:
	for v: Vector3 in [t.basis.x, t.basis.y, t.basis.z, t.origin]:
		if not (is_finite(v.x) and is_finite(v.y) and is_finite(v.z)):
			return false
	return true
