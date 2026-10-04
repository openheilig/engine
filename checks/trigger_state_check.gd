extends "res://checks/check.gd"
## trigger_state_check.gd -- W2: trigger states persist through the session
## save/load roundtrip. A door opened or a storey entered before saving must
## still be open/entered after loading -- retail saves the whole trigger
## state table, and a world whose doors reset on load is a different world.
const ModManifest := preload("res://formats/mod_manifest.gd")

func _init() -> void:
	super()
	var fails := 0
	var install := Sacred.find_install()
	assert(not install.is_empty(), "retail install is required")
	var profile := ModManifest.new(install)
	if not expect(Sacred.Pak.configure_profile(profile) == "", profile.error_text()):
		finish(1)
		return

	var world := Sacred.World.new(install.path_join("world"))
	var statics := Sacred.Statics.new(Sacred.Pak.new(install.path_join("world/static.pak")))
	var triggers := preload("res://formats/triggers.gd").new(install.path_join("world/triggers.pak"))

	var s := GameSession.new_game(install, Vector2(3236.5, 2511.5))
	s.sim.interior = Interior.new(world, statics, triggers)

	# Open something: set bit 1 on the chapel's parent trigger (the storey
	# select), and an arbitrary second trigger through the raw setter.
	var cell := Vector2i(3236, 2511)
	var parent: Dictionary = s.sim.interior.parent_for_cell(Vector2(cell))
	assert(not parent.is_empty(), "chapel parent must resolve")
	var t1: int = parent["trigger"]
	s.sim.interior.triggers.set_bits(t1, 2)
	var t2 := 0
	s.sim.interior.triggers.set_bits(t2, 0x20)
	var state1: int = s.sim.interior.triggers.state(t1)

	# Roundtrip.
	var snap := s.snapshot()
	expect(snap.get("trigger_states") is PackedInt32Array,
		"snapshot must carry trigger_states")
	var s2 := GameSession.new_game(install, Vector2(3236.5, 2511.5))
	s2.sim.interior = Interior.new(world, statics,
		preload("res://formats/triggers.gd").new(install.path_join("world/triggers.pak")))
	if s2.restore(snap) != "":
		fails += 1
		printerr("restore failed")
	expect(s2.sim.interior.triggers.state(t1) == state1,
		"chapel trigger state %d did not survive (got %d)"
			% [state1, s2.sim.interior.triggers.state(t1)])
	expect(s2.sim.interior.triggers.state(t2) == 0x20,
		"raw trigger state did not survive (got %d)"
			% s2.sim.interior.triggers.state(t2))
	# And an untouched trigger stays at its authored value in both.
	expect(s2.sim.interior.triggers.state(5) == s.sim.interior.triggers.state(5),
		"untouched trigger drifted")

	print("trigger_state_check\tOK\tt1=%d" % state1)
	finish(1 if fails > 0 else 0)
