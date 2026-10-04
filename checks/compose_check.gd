extends "res://checks/check.gd"
## compose_check.gd -- the ONE runnable check for EQUIPMENT COMPOSITION: does a
## character carry the weapon startcode says it carries, on the right hand?
##
##   godot --headless --path . --script res://checks/compose_check.gd
##
## Until 2026-08-15 every NPC in the port stood unarmed. main.gd said why, and
## the reason was honest: "nothing has measured whether a WEAPON shares the
## skeleton, or which bone it would hang from if it does not." Both halves are
## measured now, and neither answer was the expected one.
##
## IT DOES NOT SHARE THE SKELETON. The first instrument tried was equip_check's
## -- local rest agreement against the body, which CONFIRMED armour sharing a
## wearer's rig (R1.4). On hands it returned median_own = median_cross = 1.0000:
## the control scored exactly as well as the subject, so the instrument was
## measuring nothing. The cause is visible the moment the bone NAMES are printed
## instead of their positions -- a weapon carries 3..16 bones of its own and
## shares only __Root and the socket names with a body. A weapon is a rigid prop
## on a moving socket, not a second garment, and any "it shares the rig" result
## would have been the degenerate comparison talking.
##
## THE SOCKET IS NAMED ON BOTH SIDES. Census over all 1571 rigged entries:
##   Bone_weapon_01 <- Bip01 R Hand  235 |  Bone_weapon_01 <- __Root  206
##   Bone_weapon_02 <- Bip01 L Hand  192 |  Bone_weapon_02 <- __Root  176
## Two disjoint populations under one pair of names -- "where I hold it" on a
## body, "where it is held" on a weapon -- and ZERO entries where _01 hangs off
## a left hand or _02 off a right one. That disjointness is what makes the dock
## a reading rather than a convention someone guessed.
##
## WHICH HAND IS WHICH, and the control that decides it. startcode's tag-0x02
## occurrences 1 and 2 are the two hand slots. If they are really main and off,
## the two must hold DIFFERENT things:
##   shields are 58.8% of slot 2 and 10.5% of slot 1        -- 5.6x, a rate
##   all 272 slot-2 meshes carry Bone_weapon_02, while 97   -- structural, and
##     of 839 slot-1 meshes do not (the polearms)              exact
## The second is the load-bearing one: zero items sit in the off hand without an
## off-hand grip, which a slot assignment the other way round could not produce.
const CLASSES := [
	"type_npc_daemonin", "type_npc_darkelve", "type_npc_elve",
	"type_npc_gladiator", "type_npc_magician", "type_npc_seraphim",
	"type_npc_vampirelady", "type_npc_zwerg",
]
const WEARER_01 := 235       ## entries whose Bone_weapon_01 is a child of Bip01 R Hand
const WEARER_02 := 192
const WEAPON_01 := 206       ## entries whose Bone_weapon_01 is a child of __Root
const SHIELD_SEPARATION := 3.0
const DOCK_EPS := 0.001
## Armed NPCs to build through the whole live chain. Bounded because each one
## builds a real rig: enough to cover several bodies and both hands, not a
## crowd benchmark.
const ROSTER := 24

## Preloaded by PATH, not by class_name: main.gd is a scene script and this
## check wants only its constants, never an instance of it.
const MainScript := preload("res://main.gd")

## Every mapped playable class must build through PlayerView; name resolution
## alone cannot establish that a body renders.
##
## RAISED FROM 5 TO 6 when MAGICIAN.GRN's build was repaired, and FROM 6 TO 7
## on 2026-08-17 (row 1009), both in the direction that block asks for.
## DUNKELELVE.GRN's refusal was the two size-10 FormMeshBone lists competing
## for the meshes needing 9 and 10, which no counting or geometric rule could
## separate -- and the file states the answer itself, in each FormMesh's
## payload int, a 1-based all-mesh reference Models._pair_by_reference reads.
## The eighth mapping is class 6's native VLADY_D.GRN day body, named by
## items.pak record 6. vampire_body_check pins its production start and skins.
const CLASS_BODIES_BUILD := 8
const CLASS_BODIES_UNBUILT: Array[String] = []

## Uriel's Legacy (bin/sets.bin record 6) on its own Seraphim: all seven
## garments bind, one blade docks in the main hand and the second is refused
## because SERAPHIM names no off-hand socket.
##
## WAS 5 WORN / 2 REFUSED, the two refusals being SERABOOTS01 and SERASHOULDER01
## "because their vertex weights do not decode". They decode now -- the garment
## total is unchanged at 7, so nothing appeared or vanished, two pieces simply
## moved from the refused column to the worn one. Raised deliberately, the same
## way CLASS_BODIES_BUILD above was: this file's own convention is that a decoder
## repair must move the pinned number by hand, never silently. Only the BINDING
## is measured here; that the two now look right on the body is UNVERIFIED.
const URIEL_WORN := 7
const URIEL_WORN_REFUSED := 0
const URIEL_ARMED := 1
const URIEL_ARM_REFUSED := 1
## THE CONTROL. Offered the same seven garments, a body they were not cut for
## must take NONE. This is the assertion the first version of attach_skinned
## failed: binding by bone name alone, GLADIATOR scored 5 worn / 2 refused --
## identical to the Seraphim's own score, i.e. the test measured nothing.
const URIEL_CROSS_WORN := 0


func _init() -> void:
	super()
	var install := Sacred.find_install()
	var models := Sacred.Models.new(Sacred.Pak.new(install.path_join("pak/models.pak")))
	var items := Sacred.Items.new(Sacred.Pak.new(install.path_join("pak/items.pak")))
	var tp := Sacred.Pak.new(install.path_join("pak/texture.pak"))

	# THE TWO POPULATIONS. One pair of names, two disjoint meanings, no overlap.
	var wearer := {ModelView.SOCKET_MAIN: 0, ModelView.SOCKET_OFF: 0}
	var weapon := {ModelView.SOCKET_MAIN: 0, ModelView.SOCKET_OFF: 0}
	var crossed := 0
	for e in models.count():
		if models.kind_of(e) == Sacred.Models.KIND_MOTION:
			continue
		var bl := models.bones(e)
		var names := PackedStringArray()
		for x in bl:
			names.append((x["name"] as PackedByteArray).get_string_from_utf8())
		for i in bl.size():
			var nm := names[i]
			if nm != ModelView.SOCKET_MAIN and nm != ModelView.SOCKET_OFF:
				continue
			var pe: int = bl[i]["parent_effective"]
			var pn := names[pe] if pe >= 0 and pe < names.size() else "<root>"
			if pn.ends_with("Hand"):
				wearer[nm] += 1
				# A socket on the WRONG hand would break the whole mapping.
				if pn != ModelView.SOCKET_HAND[nm]:
					crossed += 1
			elif pn == "__Root":
				weapon[nm] += 1
	assert(crossed == 0,
		"%d sockets hang off the wrong hand -- _01 is not the right hand" % crossed)
	assert(wearer[ModelView.SOCKET_MAIN] == WEARER_01 and wearer[ModelView.SOCKET_OFF] == WEARER_02,
		"wearer sockets are %d/%d, expected %d/%d" % [
			wearer[ModelView.SOCKET_MAIN], wearer[ModelView.SOCKET_OFF], WEARER_01, WEARER_02])
	assert(weapon[ModelView.SOCKET_MAIN] == WEAPON_01,
		"%d weapon-side _01 grips, expected %d" % [weapon[ModelView.SOCKET_MAIN], WEAPON_01])

	# THE SLOT CONTROL. Two slots must hold different things, or they are one.
	var filled := {1: 0, 2: 0}
	var shields := {1: 0, 2: 0}
	var no_off_grip := {1: 0, 2: 0}
	for cls in CLASSES:
		var sc = Sacred.Startcode.new(install.path_join("bin").path_join(cls))
		for npc in sc.npcs:
			for slot in [1, 2]:
				var id: int = npc["main" if slot == 1 else "off"]
				if id == 0:
					continue
				var nm := items.name_of(id).to_upper()
				if nm == "":
					continue
				filled[slot] += 1
				if nm.contains("SHIELD"):
					shields[slot] += 1
				var e := models.index_of(nm)
				if e < 0:
					continue
				var has_off := false
				for b in models.bones(e):
					if (b["name"] as PackedByteArray).get_string_from_utf8() == ModelView.SOCKET_OFF:
						has_off = true
				if not has_off:
					no_off_grip[slot] += 1
	assert(filled[1] > 500 and filled[2] > 100,
		"only %d/%d hand slots are filled -- nothing to test" % [filled[1], filled[2]])
	var r1 := float(shields[1]) / float(filled[1])
	var r2 := float(shields[2]) / float(filled[2])
	assert(r2 > SHIELD_SEPARATION * r1,
		"shields are %.3f of slot 2 against %.3f of slot 1 -- the two slots do not separate, so calling one the off hand is a guess" % [r2, r1])
	# The exact half: an item in the OFF hand always has an off-hand grip. An
	# item in the MAIN hand often does not, which is what makes this a fact
	# about the slots and not about the corpus.
	assert(no_off_grip[2] == 0,
		"%d off-hand items carry no Bone_weapon_02 -- slot 2 is not the off hand" % no_off_grip[2])
	assert(no_off_grip[1] > 0,
		"every main-hand item also has an off-hand grip, so the constraint above is vacuous")

	# THE DOCK ITSELF. Build a body, hang a sword on it, and check the grip
	# lands on the socket -- in the SKELETON's own space, which is where both
	# ends of the alignment are expressed.
	var body_name := "GLADIATOR.GRN"     # carries BOTH sockets, so nothing falls back
	var bi := models.index_of(body_name)
	assert(bi >= 0, "%s is not in models.pak" % body_name)
	var pv := PlayerView.new(models, body_name, tp)
	assert(pv.node != null, "%s did not build" % body_name)
	var skel: Skeleton3D = pv.node.get_node_or_null("Skeleton")
	assert(skel != null, "%s built without a skeleton" % body_name)

	var docked := 0
	var placements: Array[Vector3] = []
	for pair in [["SWORD.GRN", 1], ["SHIELD_KITE.GRN", 2]]:
		var mesh: String = pair[0]
		var slot: int = pair[1]
		assert(pv.equip(models, mesh, slot), "%s did not dock in slot %d" % [mesh, slot])
		docked += 1
		var socket: String = ModelView.SOCKET_MAIN if slot == 1 else ModelView.SOCKET_OFF
		var att: BoneAttachment3D = null
		for c in skel.get_children():
			if c is BoneAttachment3D and String(c.name).begins_with("Socket_%s" % socket):
				att = c
		assert(att != null, "%s docked but built no attachment for %s" % [mesh, socket])
		assert(att.bone_idx == skel.find_bone(socket),
			"%s attached to bone %d (%s), not to %s" % [
				mesh, att.bone_idx, skel.get_bone_name(att.bone_idx), socket])
		# THE GEOMETRY MUST MOVE TO THE HAND. Checking that the grip lands on the
		# socket would be vacuous -- the dock transform is DEFINED as the grip's
		# inverse, so that identity holds however wrong the rest of it is. What
		# is not vacuous is where the MESH ends up, which comes from the vertex
		# data and not from the transform being tested:
		#
		#   placed   the weapon's own AABB carried through the dock must CONTAIN
		#            the socket, i.e. the character is holding it
		#   undocked the same AABB without the dock must NOT, i.e. the transform
		#            did real work rather than being identity
		#
		# This is what caught the first version, which composed the piece's
		# coordinate basis into the dock and applied it twice -- the grip still
		# satisfied its own identity while the sword hung 18.8 units off the hand.
		var piece: ModelView = att.get_child(0)
		var pm: MeshInstance3D = piece.get_node_or_null("Mesh")
		if pm == null:
			pm = piece.get_node_or_null("Skeleton/Mesh")
		assert(pm != null and pm.mesh != null, "%s docked without a mesh" % mesh)
		var socket_at := skel.get_bone_global_rest(att.bone_idx).origin
		var raw := pm.mesh.get_aabb()
		var placed := (att.transform * piece.transform) * raw
		assert(placed.grow(DOCK_EPS).has_point(socket_at),
			"%s is docked but its geometry does not reach the socket -- box %s, socket %s" % [
				mesh, placed, socket_at])
		# The dock must be a real move, of exactly the grip's own offset. This is
		# the magnitude the double-basis version got wrong (18.8 where the grip
		# offset is 13.5), while still satisfying its own grip identity.
		var grip: Variant = piece.socket_rest(socket)
		assert(grip != null, "%s lost the grip it docked by" % mesh)
		var moved := (att.transform * piece.transform).origin.distance_to(socket_at)
		assert(absf(moved - (grip as Transform3D).origin.length()) < DOCK_EPS,
			"%s moved %.4f from its socket, but its grip sits %.4f from its own origin" % [
				mesh, moved, (grip as Transform3D).origin.length()])
		assert(moved > 1.0, "%s's grip is at its own origin, so the dock moved nothing" % mesh)
		placements.append(placed.get_center())

	# THE CONTROL THAT SEPARATES THE TWO HANDS. Everything above would still
	# hold if attach_socket ignored the socket name and always used one bone.
	# The SAME mesh docked to the other hand must therefore land somewhere
	# else, and specifically the two hands apart -- measured from the skeleton,
	# not from anything the dock computed.
	var lh := skel.find_bone(ModelView.SOCKET_OFF)
	var rh := skel.find_bone(ModelView.SOCKET_MAIN)
	assert(lh >= 0 and rh >= 0, "%s does not carry both sockets" % body_name)
	var hands_apart := skel.get_bone_global_rest(lh).origin.distance_to(
		skel.get_bone_global_rest(rh).origin)
	assert(hands_apart > 1.0, "the two sockets are %.4f apart -- one hand, not two" % hands_apart)
	assert(pv.equip(models, "SWORD.GRN", 2), "SWORD did not dock in the off hand")
	var off_at := Vector3.ZERO
	for c in skel.get_children():
		if c is BoneAttachment3D and String(c.name) == "Socket_%s_%d" % [
				ModelView.SOCKET_OFF, models.index_of("SWORD.GRN")]:
			var p2: ModelView = c.get_child(0)
			var m2: MeshInstance3D = p2.get_node_or_null("Mesh")
			if m2 == null:
				m2 = p2.get_node_or_null("Skeleton/Mesh")
			off_at = ((c.transform * p2.transform) * m2.mesh.get_aabb()).get_center()
	assert(off_at != Vector3.ZERO, "the off-hand SWORD built no attachment")
	# NOT equal to hands_apart, and deliberately not asserted as such: the two
	# sockets differ in ORIENTATION as well as position, and SWORD's own two
	# grips are 1.65 apart, so the placement difference is not a pure
	# translation of the hand separation. What must hold is that the same mesh
	# goes somewhere clearly different -- half the hand separation is the floor,
	# against a version that ignored the socket name entirely and would score 0.
	var apart := off_at.distance_to(placements[0])
	assert(apart > 0.5 * hands_apart,
		"the same sword in the two hands lands only %.4f apart against %.4f between the hands -- the socket name is not selecting the bone" % [
			apart, hands_apart])
	docked += 1

	# and the refusal must work, or every polearm ends up inside a character:
	# PIKE has only a main-hand grip and must not dock in an off hand.
	assert(not pv.equip(models, "PIKE.GRN", 2),
		"PIKE docked in the off hand it has no grip for")
	assert(pv.equipped() == docked,
		"%d pieces docked, %d counted" % [docked, pv.equipped()])
	assert(pv.equipped_refused() == 0,
		"%s carries both sockets, so nothing should have been refused" % body_name)

	# THE REFUSAL, on a body that needs it, and WHY the hand is not a stand-in.
	# Substituting Bip01 L/R Hand for a missing socket was tried and withdrawn:
	# it is justified on POSITION (~1e-6 on the bodies carrying both) but a dock
	# uses the whole transform, and over the 441 wearer sockets the rotation
	# relative to the parent hand is 0-15 deg on 299, 30-60 on 13, and 90-180 on
	# 107. Right two thirds of the time, a quarter-turn or worse for a quarter of
	# the corpus, with no way to tell which from a body that has no socket -- and
	# on SOLDIER it laid a kite shield flat across the character's chest.
	var spread := _rotation_spread(models)
	assert(spread["far"] > 50,
		"only %d wearer sockets sit 90+ deg from their hand -- if the hand really does stand in, this refusal can be reconsidered" % spread["far"])
	assert(spread["near"] > spread["far"],
		"most sockets now disagree with their hand (%d near, %d far)" % [spread["near"], spread["far"]])
	# main.gd's class -> body-mesh map must actually resolve. It is READ from
	# main.gd rather than restated here, so a name edited there and nowhere
	# else fails this gate instead of silently drawing PlayerView's fallback
	# Gladiator for a Seraphim run. Distinctness matters as much as existence:
	# all classes mapping to one mesh satisfies every per-entry lookup and is
	# exactly what a copy-paste slip produces.
	var seen_models := {}
	for cls in MainScript.CLASS_MODEL:
		var mn: String = MainScript.CLASS_MODEL[cls]
		var mi := models.index_of(mn)
		assert(mi >= 0, "main.gd maps %s to %s, which models.pak does not carry" % [cls, mn])
		assert(models.kind_of(mi) == Sacred.Models.KIND_MESH,
			"%s (%s) is not a mesh entry -- an animation clip cannot be a body" % [mn, cls])
		seen_models[mn] = true
	assert(seen_models.size() == MainScript.CLASS_MODEL.size(),
		"class body meshes collapsed: %d distinct over %d classes" % [
			seen_models.size(), MainScript.CLASS_MODEL.size()])

	# RESOLVING IS NOT BUILDING, and the first version of this block asserted
	# only the former -- which passed a map containing two names that produce no
	# body at all. DUNKELELVE.GRN and MAGICIAN.GRN are correctly NAMED and fail
	# in the mesh decoder, so the map is right and the renderer is short. Pinned
	# as a measured count so both directions are caught: a regression that
	# breaks a third, and a decoder fix that repairs one of these (at which
	# point this number should be raised deliberately, not silently).
	var built := 0
	var unbuilt: Array[String] = []
	for cls in MainScript.CLASS_MODEL:
		var mn: String = MainScript.CLASS_MODEL[cls]
		var bv := PlayerView.new(models, mn, tp)
		if bv.node != null:
			built += 1
			bv.node.free()
		else:
			unbuilt.append(mn)
	unbuilt.sort()
	assert(built == CLASS_BODIES_BUILD,
		"class bodies that build moved: want %d, got %d (failing: %s)" % [
			CLASS_BODIES_BUILD, built, unbuilt])
	assert(unbuilt == CLASS_BODIES_UNBUILT,
		"a DIFFERENT set of class bodies fails to build: %s, expected %s" % [
			unbuilt, CLASS_BODIES_UNBUILT])
	# START_CLASS's own body must be one that works, or the default run draws
	# nothing. This is the assertion that would have caught pointing START_CLASS
	# at the magician.
	assert(not unbuilt.has(MainScript.CLASS_MODEL[MainScript.START_CLASS]),
		"START_CLASS %s maps to %s, which does not build" % [
			MainScript.START_CLASS, MainScript.CLASS_MODEL[MainScript.START_CLASS]])

	# ARMOUR COMPOSITION, driven the way main.gd drives it: sets.bin record 6 ->
	# items.pak records -> .GRN names, so this tests the real chain and not a
	# list of names typed here. A piece that declares vertex weights is a
	# garment; one that does not is a prop for a hand.
	var sets := Sacred.Sets.new(install)
	assert(sets.found, "bin/sets.bin did not decode -- the outfit chain cannot be tested")
	var uriel: Array[String] = []
	var blades: Array[String] = []
	for rec in sets.members_of(MainScript.START_SET):
		var nm: String = items.name_of(rec)
		var e := models.index_of(nm)
		assert(e >= 0, "set %d member %d names %s, which models.pak does not carry" % [
			MainScript.START_SET, rec, nm])
		if models.has_mesh_weights(e):
			uriel.append(nm)
		else:
			blades.append(nm)
	assert(uriel.size() == 7 and blades.size() == 2,
		"set %d split into %d garments and %d props, expected 7 and 2" % [
			MainScript.START_SET, uriel.size(), blades.size()])

	var base_material_names := models.material_names(models.index_of("SERAPHIM.GRN"))
	var shoes_mat := base_material_names.find("shoes")
	assert(shoes_mat >= 0,
		"SERAPHIM.GRN no longer names a `shoes` base material -- boot hiding has no decoded target")
	var dressed := PlayerView.new(models, "SERAPHIM.GRN", tp, PackedStringArray(["shoes"]))
	assert(dressed.node != null, "SERAPHIM.GRN did not build for the outfit test")
	var dressed_body := dressed.node as ModelView
	assert(not dressed_body.surface_material.has(shoes_mat),
		"the dressed SERAPHIM still emits material %d (`shoes`) under its worn boots" % shoes_mat)
	for g in uriel:
		dressed.wear(models, g)
	var hand := 1
	for w in blades:
		dressed.equip(models, w, hand)
		hand += 1
	assert(dressed.worn() == URIEL_WORN and dressed.worn_refused() == URIEL_WORN_REFUSED,
		"Uriel's Legacy on its own Seraphim: %d worn / %d refused, expected %d / %d" % [
			dressed.worn(), dressed.worn_refused(), URIEL_WORN, URIEL_WORN_REFUSED])
	assert(dressed.equipped() == URIEL_ARMED and dressed.equipped_refused() == URIEL_ARM_REFUSED,
		"Uriel's blades: %d docked / %d refused, expected %d / %d" % [
			dressed.equipped(), dressed.equipped_refused(), URIEL_ARMED, URIEL_ARM_REFUSED])
	dressed.node.free()

	# THE CROSS-CHARACTER CONTROL, and it is the load-bearing half of this
	# block. See URIEL_CROSS_WORN: without the geometric fit test, these two
	# score exactly what the Seraphim scores.
	for other in ["GLADIATOR.GRN", "DWARF.GRN"]:
		var wrong := PlayerView.new(models, other, tp)
		assert(wrong.node != null, "%s did not build for the control arm" % other)
		for g in uriel:
			wrong.wear(models, g)
		assert(wrong.worn() == URIEL_CROSS_WORN,
			"%s wore %d of the Seraphim's %d garments -- the fit test has stopped discriminating"
				% [other, wrong.worn(), uriel.size()])
		assert(wrong.worn_refused() == uriel.size(),
			"%s refused %d of %d, so some piece neither bound nor was refused"
				% [other, wrong.worn_refused(), uriel.size()])
		wrong.node.free()

	# SERAPHIM carries Bone_weapon_01 and NOT _02, which is the ordinary case:
	# only 192 of 1571 entries carry the off-hand socket at all. Its main hand
	# docks and its off hand is refused. It is also START_CLASS's body, so this
	# block is now testing the rig the default run actually draws.
	var sv := PlayerView.new(models, "SERAPHIM.GRN", tp)
	assert(sv.node != null, "SERAPHIM.GRN did not build")
	var sskel: Skeleton3D = sv.node.get_node("Skeleton")
	assert(sskel.find_bone(ModelView.SOCKET_MAIN) >= 0
		and sskel.find_bone(ModelView.SOCKET_OFF) < 0,
		"SERAPHIM no longer has exactly one of the two sockets -- pick another subject")
	assert(sv.equip(models, "SWORD.GRN", 1), "SERAPHIM could not carry a sword")
	assert(not sv.equip(models, "SHIELD_KITE.GRN", 2),
		"SERAPHIM took a shield in an off hand it names no socket for")
	assert(sv.equipped() == 1 and sv.equipped_refused() == 1,
		"SERAPHIM docked %d and refused %d, expected 1 and 1" % [
			sv.equipped(), sv.equipped_refused()])

	# THE LIVE WIRING, on the real cast. This is main.gd's _build_npcs minus the
	# scene tree: the same Startcode -> Items -> PlayerView -> equip chain over
	# real NPC records. It is here because the defect this check was written
	# alongside -- PlayerView reading a material_override that ModelView had
	# stopped setting -- lived for two commits precisely because every gate
	# tested a layer and none tested the seam where the layers meet.
	var roster_built := 0
	var roster_hands := 0
	var roster_refused := 0
	var roster_nosocket := 0
	var sc_g = Sacred.Startcode.new(install.path_join("bin/type_npc_gladiator"))
	for rec in sc_g.npcs:
		if roster_built >= ROSTER:
			break
		var bn := items.name_of(rec["body"])
		if bn == "" or models.index_of(bn) < 0:
			continue
		if rec["main"] == 0 and rec["off"] == 0:
			continue
		var npc := PlayerView.new(models, bn, tp)
		if npc.node == null:
			continue
		roster_built += 1
		for slot in [1, 2]:
			var held := items.name_of(rec["main" if slot == 1 else "off"])
			if held == "":
				continue
			if npc.equip(models, held, slot):
				roster_hands += 1
			else:
				roster_refused += 1
		roster_nosocket += npc.equipped_refused()
		npc.node.free()
	assert(roster_built == ROSTER,
		"only %d of %d armed gladiator-class NPCs built" % [roster_built, ROSTER])
	# Every hand these records name must actually be drawable. A refusal here is
	# not a shrug: it would mean the roster carries an item whose grip the body
	# has no socket for, which the slot census above says cannot happen.
	# NOT zero, and that is the finding rather than a defect: SOLDIER and almost
	# every other NPC body names no socket at all, so the cast cannot be armed
	# from the body mesh alone. The socket turns up on ARMOUR instead
	# (DAEMONIA_ARMOR01_GLOVES carries one), which is the open lead. What must
	# hold is that nothing is quietly approximated.
	assert(roster_refused + roster_hands > 0, "the roster carries no hands at all")
	assert(roster_refused == roster_nosocket,
		"%d hands were refused but only %d for want of a socket -- something else is failing" % [
			roster_refused, roster_nosocket])

	print("compose_check\tOK\twearer=%d/%d\tweapon=%d/%d\tcrossed=%d\tslot1=%d (%.3f shields)\tslot2=%d (%.3f shields)\tno_off_grip=%d/%d\tdocked=%d\troster=%d\thands=%d\trefused=%d\tno_socket=%d" % [
		wearer[ModelView.SOCKET_MAIN], wearer[ModelView.SOCKET_OFF],
		weapon[ModelView.SOCKET_MAIN], weapon[ModelView.SOCKET_OFF], crossed,
		filled[1], r1, filled[2], r2, no_off_grip[1], no_off_grip[2], docked,
		roster_built, roster_hands, roster_refused, roster_nosocket])
	finish(0)


## How many wearer sockets sit NEAR their parent hand's orientation and how many
## sit far from it. Read straight from the bone rests, so the refusal above is
## justified by the corpus at run time rather than by a number in a comment.
func _rotation_spread(models: Sacred.Models) -> Dictionary:
	var near := 0
	var far := 0
	for e in models.count():
		if models.kind_of(e) == Sacred.Models.KIND_MOTION:
			continue
		var bl := models.bones(e)
		if bl.is_empty():
			continue
		var names := PackedStringArray()
		for x in bl:
			names.append((x["name"] as PackedByteArray).get_string_from_utf8())
		for i in bl.size():
			if not names[i].begins_with("Bone_weapon"):
				continue
			var pe: int = bl[i]["parent_effective"]
			if pe < 0 or not names[pe].ends_with("Hand"):
				continue
			var q := (bl[i]["rest"] as Transform3D).basis.get_rotation_quaternion().normalized()
			if rad_to_deg(2.0 * acos(clampf(absf(q.w), -1.0, 1.0))) < 15.0:
				near += 1
			else:
				far += 1
	return {"near": near, "far": far}
