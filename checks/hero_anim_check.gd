extends "res://checks/check.gd"
## hero_anim_check.gd -- the ONE runnable check for PlayerView.animate.
##
##   godot --headless --path . --script res://checks/hero_anim_check.gd
##
## WHAT THIS PROTECTS. Every playable body was built and then left standing in
## its bind pose, because PlayerView had no path to play_clip at all -- the
## machinery existed and only the opt-in modes (--creatures, --npcs, --grn=)
## ever reached it. A rest-pose hero is the loudest way a screenshot says "not
## Sacred", and nothing in this directory would have noticed.
##
## Playback must change the skeleton over time; action changes and refusals
## must preserve their observable contracts. Native poses need not agree with
## model rest at t=0. Rest-distance and "splay" thresholds previously enforced
## an invented retargeting rule (finding 1247), so they are not acceptance
## criteria here. Native pose comparisons are the rendering oracle.
## The class->body map lives in main.gd, which has no class_name; preloading it
## reaches its constants without instancing the scene root.
const Main := preload("res://main.gd")
const AT_BIND := 0.02        ## radians, for "has this bone moved at all"
const SAMPLES := 12


func _init() -> void:
	super()
	var install := Sacred.find_install()
	var models_pak = Sacred.Pak.new(install.path_join("pak/models.pak"))
	expect(models_pak.is_open(), "models.pak did not open")
	if not models_pak.is_open():
		finish()
		return
	var models = Sacred.Models.new(models_pak)
	var root := Node3D.new()
	get_root().add_child(root)

	var animated := 0
	var tested := 0
	var rows := PackedStringArray()
	# Every class body main.gd can spawn as the player. The hole in the map --
	# no vampiress rig in models.pak -- is main.gd's finding, not this gate's
	# problem: a name that does not build is skipped and counted.
	for tree in Main.CLASS_MODEL:
		var mesh: String = Main.CLASS_MODEL[tree]
		var pv := PlayerView.new(models, mesh)
		if pv.node == null:
			rows.append("%s\tno rig" % mesh)
			continue
		root.add_child(pv.node)
		tested += 1
		var want := PackedInt32Array([pv.model_index])
		var rigs = Sacred.Rigs.new(models, want)
		var ok := pv.animate(models, rigs)
		# THE CLIP MUST BE A RESTING ONE. A standing hero playing an attack on
		# a loop is the failure this replaced, and it passes every other
		# assertion here -- it binds, it moves bones, it does not splay.
		var acts: PackedStringArray = rigs.actions_of(pv.model_index)
		var chosen := rigs.rest_clip(pv.model_index)
		var chosen_act := Sacred.Rigs.action_of(models.entry_name(chosen)) if chosen >= 0 else ""
		if acts.has("IDLE") or acts.has("FIDLE") or acts.has("WALK"):
			expect(Sacred.Rigs.REST_ACTIONS.has(chosen_act),
				"%s stands playing a %s clip, expected one of %s" % [
					mesh, chosen_act, Sacred.Rigs.REST_ACTIONS])
		var mv := pv.node as ModelView
		if not ok:
			rows.append("%s\tclip=%d\trefused" % [mesh, rigs.clip_for(pv.model_index)])
			continue
		animated += 1
		expect(mv.anim_length > 0.0, "%s plays a zero-length clip" % mesh)

		mv.freeze_anim(0.0)
		var initial: Array[Transform3D] = []
		var skel := _skel(mv)
		for bone in skel.get_bone_count():
			initial.append(skel.get_bone_pose(bone))
		var moved := 0.0
		for i in SAMPLES:
			mv.freeze_anim(mv.anim_length * float(i) / float(SAMPLES))
			moved = maxf(moved, _frac_moved(mv, initial))
		expect(moved > 0.0,
			"%s never changes pose across the clip" % mesh)
		rows.append("%s\tclip=%d\taction=%s\tscore=%.3f\tlen=%.2fs\tmoved=%.0f%%\thas=%s" % [
			mesh, chosen, chosen_act, pv.clip_score(rigs),
			mv.anim_length, 100.0 * moved, acts])

	for r in rows:
		print(r)
	expect(tested > 0, "no class body built, so nothing was tested")
	expect(animated > 0, "not one class body animates")

	# THE CONTROL. The same body, built and NOT animated, must stay at rest --
	# otherwise "moved" above is measuring something other than the clip.
	var ctrl := PlayerView.new(models, Main.CLASS_MODEL["type_npc_seraphim"])
	expect(ctrl.node != null, "the control body did not build")
	if ctrl.node != null:
		root.add_child(ctrl.node)
		var cmv := ctrl.node as ModelView
		expect(_frac_moved(cmv) == 0.0,
			"an un-animated rig is already off its rest pose, so the measurement is not the clip")

	# THE SWITCH. Everything above proves a body can play ONE clip; this proves
	# it can CHANGE clip, which is what a character does and a statue does not.
	# Asserted on the clip INDEX and on anim_length, never on the fact that
	# play_action returned true -- returning true while playing the same clip
	# is precisely the bug a "it switched" check has to be able to fail on, and
	# is exactly the bug this gate caught on its first run.
	#
	# THE BODY IS CHOSEN, NOT NAMED. The obvious pick is the Seraphim, since
	# she is who a retail start spawns -- and she is the one class body that
	# resolves NO WALK clip (row 1053), so pinning this gate to her would make
	# it fail on a defect in Sacred.Rigs' matching rather than on the switching
	# it exists to test. The bodies that lack a walk are printed instead, so
	# the gap stays visible without being asserted here.
	var no_walk := PackedStringArray()
	var sw: PlayerView = null
	var sw_name := ""
	var srigs = null
	for tree in Main.CLASS_MODEL:
		var mesh: String = Main.CLASS_MODEL[tree]
		var cand := PlayerView.new(models, mesh)
		if cand.node == null:
			continue
		var crigs = Sacred.Rigs.new(models, PackedInt32Array([cand.model_index]))
		var cw: int = crigs.clip_for_action(cand.model_index, "WALK")
		if cw < 0:
			no_walk.append(mesh)
			cand.node.free()
			continue
		if sw == null:
			sw = cand
			sw_name = mesh
			srigs = crigs
		else:
			# Only the first WALK-capable body drives the switch assertions.
			# Candidates are not scene children yet, so release them explicitly.
			cand.node.free()
	print("hero_anim_walkgap\tno_walk=%s" % [no_walk])
	expect(sw != null, "not one class body resolves a WALK clip, so switching is untestable")
	if sw != null:
		root.add_child(sw.node)
		expect(sw.animate(models, srigs), "the switching body would not animate at all")
		var rest_clip: int = srigs.rest_clip(sw.model_index)
		var walk: int = srigs.clip_for_action(sw.model_index, "WALK")
		expect(walk != rest_clip, "WALK and rest are the same clip -- a switch is unobservable")
		var smv := sw.node as ModelView
		var rest_len := smv.anim_length

		expect(sw.play_action(models, srigs, "WALK"), "play_action refused WALK")
		expect(sw.action == "WALK", "play_action left action=%s after WALK" % sw.action)
		expect(smv.anim_length != rest_len,
			"the rig reports the same %.2fs clip after switching to WALK" % rest_len)
		expect(smv.anim_length > 0.0, "the WALK clip bound zero-length")

		# BACK, because a one-way switch is half a state machine.
		expect(sw.play_action(models, srigs, "IDLE"), "play_action refused IDLE")
		expect(is_equal_approx(smv.anim_length, rest_len),
			"switching back to IDLE landed on a %.2fs clip, not the %.2fs rest clip" % [
				smv.anim_length, rest_len])

		# THE REFUSAL, and the reason this gate is not just three asserts: an
		# action this body has no clip for must leave it where it is, not fall
		# back through rest_clip onto some other action's.
		var absent := ""
		for a in Sacred.Rigs.ACTIONS:
			var ac: int = srigs.clip_for_action(sw.model_index, a)
			if a != "IDLE" and ac < 0:
				absent = a
				break
		if absent != "":
			expect(not sw.play_action(models, srigs, absent),
				"play_action claimed to play %s, which this body has no clip for" % absent)
			expect(sw.action == "IDLE",
				"a refused %s still moved the body off IDLE (now %s)" % [absent, sw.action])
		print("hero_anim_switch\tbody=%s\trest=%d/%.2fs\twalk=%d\trefused=%s" % [
			sw_name, rest_clip, rest_len, walk,
			absent if absent != "" else "(body has every action)"])


	# finish() quits immediately; it does not run a frame that could flush
	# queue_free(). Free the private scene synchronously so meshes, materials,
	# skeletons and animation libraries release their RenderingServer RIDs.
	root.free()
	print("hero_anim_check\tOK\tbodies=%d\tanimated=%d" % [tested, animated])
	finish(0)




## Pose changes against a sampled frame, or rest for the unanimated control.
func _frac_moved(mv: ModelView, reference: Array[Transform3D] = []) -> float:
	var sk := _skel(mv)
	if sk == null or sk.get_bone_count() == 0:
		return 0.0
	var n := 0
	for b in sk.get_bone_count():
		var before := reference[b] if not reference.is_empty() else sk.get_bone_rest(b)
		var after := sk.get_bone_pose(b)
		if before.origin.distance_to(after.origin) > 0.00001 or before.basis.get_rotation_quaternion().angle_to(
				after.basis.get_rotation_quaternion()) > AT_BIND:
			n += 1
	return float(n) / float(sk.get_bone_count())


func _skel(mv: ModelView) -> Skeleton3D:
	for c in mv.get_children():
		if c is Skeleton3D:
			return c as Skeleton3D
	return null


