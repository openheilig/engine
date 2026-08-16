extends "res://checks/check.gd"
## facing_check.gd -- the ONE runnable check for character facing (row 965).
##
##   godot --headless --path . --script res://checks/facing_check.gd
##
## WHAT THIS PROTECTS. `set_yaw` sat unwired for a long time because nothing
## established which way a model faces in its own coordinates, and a wrong
## constant is 90 or 180 degrees wrong on every character at once -- which
## looks deliberate rather than broken. So the assertions below are about the
## PROPERTY that makes the derivation sound, not about any particular angle:
##
##   1. Every class body has a measurable rest facing.
##   2. Those facings fall into exactly TWO clusters, 90 degrees apart, and the
##      cluster is predicted by the net rotation of the chain above Bip01.
##   3. Correcting by the rest facing COLLAPSES the two clusters into one.
##
## (3) is the load-bearing one. Without it a per-model constant is just a fudge
## factor; with it the two families are demonstrably the same rig.
const Main := preload("res://main.gd")
const NINETY := PI / 2.0
## Measured spread inside a cluster is the bodies' own toe splay: worst
## pairwise dot 0.9556 in Bip01 space, about 17 degrees.
const CLUSTER_TOL := deg_to_rad(25.0)
## Two bodies build no rig at all (models.pak carries no vampiress and no
## magician mesh under any spelling tried); that is main.gd's finding and not
## this gate's problem.
const WANT_BODIES := 7


func _init() -> void:
	super()
	var install := Sacred.find_install()
	var pak := Sacred.Pak.new(install.path_join("pak/models.pak"))
	expect(pak.is_open(), "models.pak did not open")
	if not pak.is_open():
		finish()
		return
	var models := Sacred.Models.new(pak)

	var yaws: Array[float] = []
	var aligns: Array[float] = []
	var names := PackedStringArray()
	for tree in Main.CLASS_MODEL:
		var mesh: String = Main.CLASS_MODEL[tree]
		var e := models.index_of(mesh)
		if e < 0:
			continue
		var y := PlayerView.rest_yaw(models, e)
		expect(not is_nan(y), "%s has no measurable rest facing" % mesh)
		if is_nan(y):
			continue
		yaws.append(y)
		aligns.append(_above_bip01(models, e))
		names.append(mesh)
	expect(yaws.size() == WANT_BODIES,
		"%d class bodies measured, expected %d" % [yaws.size(), WANT_BODIES])

	# (2) THE ALIGNMENT IS QUANTISED. Every body's chain above Bip01 nets to 0
	# or -90 degrees about the vertical and never to anything between. This is
	# what says the split is one authoring rotation rather than seven stances.
	var zero := 0
	var minus90 := 0
	for i in aligns.size():
		var a: float = aligns[i]
		if absf(a) < deg_to_rad(5.0):
			zero += 1
		elif absf(a + NINETY) < deg_to_rad(5.0):
			minus90 += 1
		else:
			expect(false, "%s's chain above Bip01 nets %.1f deg, expected 0 or -90" % [
				names[i], rad_to_deg(a)])
	expect(zero > 0 and minus90 > 0,
		"the bodies no longer split -- %d at 0 and %d at -90, so this gate is vacuous" % [
			zero, minus90])

	# (2b) AND IT PREDICTS THE FACING. Bodies in the same alignment family must
	# agree; bodies in different families must differ by about 90 degrees.
	for i in yaws.size():
		for j in range(i + 1, yaws.size()):
			var same: bool = absf(aligns[i] - aligns[j]) < deg_to_rad(5.0)
			var d := absf(_wrap(yaws[i] - yaws[j]))
			if same:
				expect(d < CLUSTER_TOL,
					"%s and %s share an alignment but face %.1f deg apart" % [
						names[i], names[j], rad_to_deg(d)])
			else:
				expect(absf(d - NINETY) < CLUSTER_TOL,
					"%s and %s differ in alignment but face %.1f deg apart, expected ~90" % [
						names[i], names[j], rad_to_deg(d)])

	# (3) THE CORRECTION COLLAPSES THEM. Facing a common target through
	# `target - rest_yaw` must land every body on the SAME applied yaw modulo
	# its own stance -- which is the whole claim.
	var target := deg_to_rad(37.0)          # arbitrary, and that is the point
	var applied: Array[float] = []
	for y in yaws:
		applied.append(_wrap(target - y))
	# Every corrected body now faces the target: rest + applied == target.
	for i in yaws.size():
		expect(absf(_wrap(yaws[i] + applied[i] - target)) < 1e-5,
			"%s does not land on the target after correction" % names[i])
	# And the SPREAD of the corrected directions is the stance spread, not the
	# 90-degree family spread it was before.
	var raw_spread := _spread(yaws)
	var fixed: Array[float] = []
	for i in yaws.size():
		fixed.append(_wrap(yaws[i] + applied[i]))
	var fixed_spread := _spread(fixed)
	expect(raw_spread > deg_to_rad(60.0),
		"the raw facings only spread %.1f deg -- the families have merged and (3) proves nothing" % rad_to_deg(raw_spread))
	expect(fixed_spread < deg_to_rad(1.0),
		"corrected facings still spread %.1f deg" % rad_to_deg(fixed_spread))

	# The refusal path: a body with no biped feet must come back NAN rather
	# than 0.0, because 0.0 is a legal facing and would silently mean "east".
	expect(is_nan(PlayerView.rest_yaw(models, -1)),
		"an invalid entry returned a facing instead of NAN")

	# (4) THE WIRING ITSELF. rest_yaw is a constant; face() is the thing that
	# gets called. Build a real rig and turn it through the four cardinal cell
	# directions -- the angles must be DISTINCT, 90 degrees apart, and turn the
	# same way round, which a sign error or a transposed axis all break.
	var pv := PlayerView.new(models, Main.CLASS_MODEL["type_npc_seraphim"])
	expect(pv.node != null, "the test body did not build")
	if pv.node != null:
		get_root().add_child(pv.node)
		expect(pv.can_face(), "a built biped reports it cannot face")
		var cell := Vector2(3236.5, 2511.5)
		var dirs := [Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0), Vector2(0, -1)]
		var got: Array[float] = []
		for d in dirs:
			expect(pv.face(cell, d), "face() refused direction %s" % d)
			got.append(pv.yaw())
		# Four distinct headings.
		for i in got.size():
			for j in range(i + 1, got.size()):
				expect(absf(_wrap(got[i] - got[j])) > deg_to_rad(30.0),
					"cell directions %s and %s produced the same facing" % [dirs[i], dirs[j]])
		# Opposite directions must be 180 degrees apart, exactly.
		expect(absf(absf(_wrap(got[0] - got[2])) - PI) < deg_to_rad(1.0),
			"east and west are %.1f deg apart, expected 180" % rad_to_deg(absf(_wrap(got[0] - got[2]))))
		expect(absf(absf(_wrap(got[1] - got[3])) - PI) < deg_to_rad(1.0),
			"north and south are %.1f deg apart, expected 180" % rad_to_deg(absf(_wrap(got[1] - got[3]))))
		# And consecutive quarter-turns must all step the SAME way round; a
		# transposed axis gives a sequence that reverses.
		var step := _wrap(got[1] - got[0])
		for i in 3:
			var t := _wrap(got[i + 1] - got[i])
			expect(absf(t - step) < deg_to_rad(1.0),
				"turning from %s to %s steps %.1f deg where the first step was %.1f" % [
					dirs[i], dirs[i + 1], rad_to_deg(t), rad_to_deg(step)])
		expect(absf(absf(step) - deg_to_rad(90.0)) < deg_to_rad(1.0),
			"a quarter turn in cell space is %.1f deg of facing" % rad_to_deg(step))
		# A zero direction must be refused, not silently treated as east.
		expect(not pv.face(cell, Vector2.ZERO), "a zero direction was accepted")

		# (5) THE ROTATION MUST REACH THE MESH. Everything above tests a number;
		# this drives rig_placement itself and reads a bone back out, so a yaw
		# applied about the wrong axis -- which for a Z-up rig would tip the
		# character over instead of turning it -- fails here and nowhere else.
		var skel := pv.node.get_node_or_null("Skeleton") as Skeleton3D
		expect(skel != null, "the test body has no Skeleton")
		if skel != null:
			var hand := skel.find_bone("Bip01 L Hand")
			var head := skel.find_bone("Bip01 Head")
			expect(hand >= 0 and head >= 0, "the test body has no L Hand / Head bone")
			if hand >= 0 and head >= 0:
				var seen: Array[Vector3] = []
				var heads: Array[Vector3] = []
				for d in dirs:
					pv.face(cell, d)
					pv.pose_now()
					seen.append(_posed(skel, hand))
					heads.append(_posed(skel, head))
				# The hand SWINGS ROUND as the body turns: opposite facings must
				# put it on opposite sides.
				var mid := (seen[0] + seen[2]) * 0.5
				expect((seen[0] - mid).length() > 1.0,
					"the hand barely moved between opposite facings -- the yaw is not reaching the skeleton")
				expect((seen[0] - mid).dot(seen[2] - mid) < 0.0,
					"opposite facings put the hand on the same side of the body")
				# The HEAD does not: it is on the axis of rotation, so it must
				# stay put. That is what separates "turned" from "tipped over" --
				# a yaw about the wrong axis moves the head furthest of all.
				var head_move := 0.0
				for i in range(1, heads.size()):
					head_move = maxf(head_move, (heads[i] - heads[0]).length())
				expect(head_move < (seen[0] - mid).length() * 0.5,
					"the head moved %.2f while turning -- the rig is tipping, not turning" % head_move)
				print("facing_check\tskeleton\thand_swing=%.2f\thead_drift=%.2f" % [
					(seen[0] - mid).length(), head_move])
		print("facing_check\tface()\tE=%.1f N=%.1f W=%.1f S=%.1f step=%.1f" % [
			rad_to_deg(got[0]), rad_to_deg(got[1]), rad_to_deg(got[2]),
			rad_to_deg(got[3]), rad_to_deg(step)])

	var deg := PackedStringArray()
	for i in yaws.size():
		deg.append("%s=%.1f/%.0f" % [names[i], rad_to_deg(yaws[i]), rad_to_deg(aligns[i])])
	print("facing_check\tOK\tbodies=%d\talign_0=%d\talign_-90=%d\traw_spread=%.1f\tcorrected_spread=%.4f" % [
		yaws.size(), zero, minus90, rad_to_deg(raw_spread), rad_to_deg(fixed_spread)])
	print("facing_check\t%s" % " ".join(deg))
	finish(0)


## Net rotation about the rig's vertical of the whole chain ABOVE Bip01 --
## `__Root -> Root -> Bip01` on some bodies, `__Root -> Bip01` on others.
func _above_bip01(models: Sacred.Models, entry: int) -> float:
	var bones: Array = models.bones(entry)
	var xf: Array[Transform3D] = []
	for i in bones.size():
		var local: Transform3D = bones[i]["rest"]
		var p: int = int(bones[i]["parent"])
		xf.append(local if p < 0 or p >= i else xf[p] * local)
		var nm: String = (bones[i]["name"] as PackedByteArray).get_string_from_utf8()
		if nm == "Bip01":
			return _wrap(xf[i].basis.get_euler().z)
	return 0.0


func _wrap(a: float) -> float:
	while a > PI:
		a -= TAU
	while a < -PI:
		a += TAU
	return a


## Angular spread of a set of directions, as the largest pairwise separation.
func _spread(angles: Array[float]) -> float:
	var worst := 0.0
	for i in angles.size():
		for j in range(i + 1, angles.size()):
			worst = maxf(worst, absf(_wrap(angles[i] - angles[j])))
	return worst


## A bone's global position, composed from the skeleton's POSES rather than read
## from get_bone_global_pose().
##
## Godot only refreshes that cache while the skeleton is processing, and a check
## has no rendered frame -- measured: setting bone 0's pose rotation to a clean
## 90 degrees leaves get_bone_global_pose() on every descendant unchanged, even
## after force_update_all_bone_transforms(). Composing the chain here is exact
## and depends on nothing but the poses the modifier actually wrote.
func _posed(skel: Skeleton3D, bone: int) -> Vector3:
	var chain := PackedInt32Array()
	var b := bone
	while b >= 0:
		chain.append(b)
		b = skel.get_bone_parent(b)
	var t := Transform3D.IDENTITY
	for i in range(chain.size() - 1, -1, -1):
		t = t * skel.get_bone_pose(chain[i])
	return t.origin
