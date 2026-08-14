extends "res://checks/check.gd"
## anim_freeze_check.gd -- the ONE runnable check for the frozen-player contract
## (autoresearch row 784).
##
##   godot --headless --path godot-port --script anim_freeze_check.gd
##
## WHAT THIS PROTECTS. play_clip() starts PLAYBACK. Reading a posed skeleton
## after seek(0) but on a LATER frame reads that later frame, because the
## AnimationMixer advanced in between -- silently, with plausible numbers. Four
## rows of findings were built on exactly that artefact and all had to be
## withdrawn: 43 meshes "off bind", a wolf "model defect proven across five
## clips", nine "real suspects". Frozen, the same rig measured 0.0109 worst-case
## where running measured 0.5259.
##
## The contract: seek_anim() leaves the player RUNNING (--creatures relies on
## that to desynchronise loops), freeze_anim() parks it, and sample_bone_pose()
## refuses to answer while the player is advancing. This check pins all three.
## It deliberately does NOT try to measure a pose -- that needs frames, and a
## check that needed frames is what could not exist when this bug was live.
const MESH := "BEAR.GRN"
const CLIP := "BEAR_WALK_BH.GRN"


func _init() -> void:
	super()
	var install := Sacred.find_install()
	assert(install != "", "no retail install found; pass --install=/path/to/install")
	var models := Sacred.Models.new(Sacred.Pak.new(install.path_join("pak/models.pak")))
	var mi := models.index_of(MESH)
	var ci := models.clip_index_of(CLIP)
	assert(mi >= 0 and ci >= 0, "%s or %s missing" % [MESH, CLIP])

	var mv = load("res://view/model_view.gd").new()
	root.add_child(mv)
	assert(mv.setup(models, mi), "%s built no rig" % MESH)

	# 1. Before any clip, nothing is frozen and nothing claims to be.
	assert(not mv.anim_frozen, "a rig with no clip reports itself frozen")

	# 2. play_clip starts playback, and that is NOT a frozen state.
	assert(mv.play_clip(models, ci), "play_clip refused %s" % CLIP)
	assert(not mv.anim_frozen,
		"play_clip left the rig reporting frozen -- a pose read after it would be a read of a later frame")

	# 3. freeze_anim parks it.
	mv.freeze_anim(0.0)
	assert(mv.anim_frozen, "freeze_anim did not park the player")

	# 4. seek_anim UN-parks it. This is the direction that matters: --creatures
	#    seeks to desynchronise and must keep animating, so seek must never be
	#    mistaken for a freeze.
	mv.seek_anim(0.25)
	assert(not mv.anim_frozen, "seek_anim left the rig reporting frozen -- seek is not a freeze")

	# 5. THE GUARD ITSELF, both directions. Refusing returns IDENTITY, so the
	#    refusal is observable: while the player advances the reader must give
	#    nothing back, and once parked it must answer with a real pose. Asserting
	#    only the frozen half would pass against a reader with no guard at all.
	mv.seek_anim(0.25)
	assert(not mv.anim_frozen, "the rig re-parked itself")
	assert(mv.sample_bone_pose("Bip01 Spine") == Transform3D.IDENTITY,
		"sample_bone_pose answered while the player was advancing -- the guard is gone")
	mv.freeze_anim(0.0)
	assert(mv.anim_frozen, "freeze_anim did not re-park the player")
	assert(mv.sample_bone_pose("Bip01 Spine") != Transform3D.IDENTITY,
		"sample_bone_pose returned nothing while parked -- the guard now refuses everything")

	print("anim_freeze_check: play_clip runs, freeze_anim parks, seek_anim un-parks, and sample_bone_pose is guarded")
	finish(0)
