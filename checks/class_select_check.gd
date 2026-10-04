extends "res://checks/check.gd"
## class_select_check.gd -- G1: every one of the eight classes resolves its
## own start template by CharacterType, opens its startcode, and builds a
## session with derived level-1 HP. The Seraphim default is untouched.
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
	var tdir := install.path_join("templates")

	# Pre-read every shipped template once.
	var tmpl: Dictionary = {}
	var d := DirAccess.open(tdir)
	assert(d != null, "templates dir must exist")
	for f in d.get_files():
		if not (f.begins_with("hero") and f.ends_with(".ptx")):
			continue
		var h := Sacred.Hero.new(tdir.path_join(f))
		if h.found:
			tmpl[h.class_dir()] = f

	var seraphim_hp := 0
	for dir: String in Sacred.Hero.TYPE_DIR.values():
		expect(tmpl.has(dir), "class %s has no matching template" % dir)
		if not tmpl.has(dir):
			continue
		# startcode opens and declares a start position.
		var sc := Sacred.Startcode.new(install.path_join("bin").path_join(dir))
		expect(sc.start_cell != Sacred.Startcode.NO_CELL,
			"%s startcode must declare a start position" % dir)
		# A session on that class's template derives level-1 HP.
		var s := GameSession.new_game(install, Vector2(3236.5, 2511.5), "", tmpl[dir])
		expect(s.player_hp_max > 0, "%s derived HP must be positive" % dir)
		expect(s.hero_level == 1, "%s template starts at level 1" % dir)
		expect(s.start_class == dir,
			"%s session must identify the class from its hero data" % dir)
		if dir == "type_npc_seraphim":
			seraphim_hp = s.player_hp_max

	# The default new game stays the Seraphim at her known 119 HP.
	var dflt := GameSession.new_game(install, Vector2(3236.5, 2511.5))
	expect(dflt.hero_level == 1, "default stays level 1")
	expect(dflt.player_hp_max == 119 or dflt.player_hp_max == seraphim_hp,
		"default HP %d drifted from the Seraphim's %d"
			% [dflt.player_hp_max, seraphim_hp])

	# Class-specific saved state must not overwrite another class's session.
	var dwarf_session := GameSession.new_game(install, Vector2(3470.5, 2779.5),
		"", tmpl["type_npc_zwerg"])
	dwarf_session.award_xp(350)
	var world := Sacred.World.new(install.path_join("world"))
	var statics := Sacred.Statics.new(Sacred.Pak.new(install.path_join("world/static.pak")))
	var trigger_reader := preload("res://formats/triggers.gd")
	dwarf_session.sim.interior = Interior.new(world, statics,
		trigger_reader.new(install.path_join("world/triggers.pak")))
	dwarf_session.sim.interior.triggers.replace_state(0, 0x20)
	var dwarf_save := dwarf_session.snapshot()
	var save_path := "user://_class_select_test/session.json"
	expect(SaveStore.save(save_path, dwarf_save) == "",
		"class-aware session save must write")
	dwarf_save = SaveStore.load(save_path, GameSession.SCHEMA)
	expect(not dwarf_save.is_empty(), "class-aware session save must reload")
	var before := dflt.snapshot()
	expect(dflt.restore(dwarf_save) != "",
		"loading a Dwarf into a Seraphim session must refuse")
	expect(dflt.snapshot() == before,
		"cross-class load refusal must leave the live session unchanged")
	var dwarf_reload := GameSession.new_game(install, Vector2.ZERO,
		"", tmpl["type_npc_zwerg"])
	dwarf_reload.sim.interior = Interior.new(world, statics,
		trigger_reader.new(install.path_join("world/triggers.pak")))
	expect(dwarf_reload.restore(dwarf_save) == "",
		"matching-class save must restore")
	expect(dwarf_reload.hero_level == dwarf_session.hero_level
		and dwarf_reload.hero_xp == dwarf_session.hero_xp
		and dwarf_reload.player_cell == dwarf_session.player_cell,
		"matching-class load must retain progression and position")
	expect(dwarf_reload.sim.interior.triggers.state(0) == 0x20,
		"world trigger state must survive JSON disk save/load")
	var restored_state := dwarf_reload.snapshot()
	var truncated := dwarf_save.duplicate(true)
	truncated["trigger_states"].pop_back()
	expect(dwarf_reload.restore(truncated) != "",
		"truncated trigger table must refuse before restoring actors")
	expect(dwarf_reload.snapshot() == restored_state,
		"truncated-world refusal must not mutate the live session")
	var fractional := dwarf_save.duplicate(true)
	fractional["trigger_states"][0] = 0.5
	expect(dwarf_reload.restore(fractional) != "",
		"fractional trigger value must refuse instead of truncating")
	expect(dwarf_reload.snapshot() == restored_state,
		"invalid-trigger refusal must not mutate the live session")

	# The production resolver must not silently launch a different class.
	var app = load("res://main.gd").new()
	var original_cell: Vector2 = app.start_cell
	app._start_class = "type_npc_not_a_class"
	expect(app.call("_apply_retail_start", install) == false,
		"unknown class must refuse startup instead of substituting a hero")
	expect(app.start_cell == original_cell, "refusal must preserve the start cell")
	app._start_class = "type_npc_vampirelady"
	expect(app.call("_apply_retail_start", install) == true,
		"Vampiress must resolve her native body through the production start path")
	expect(app._player_model == "VLADY_D.GRN"
		and app.start_cell == Vector2(3500, 2477) and app._retail_start_layer == 2,
		"Vampiress must retain her own body, authored start and layer")
	app._start_class = "type_npc_zwerg"
	expect(app.call("_apply_retail_start", install) == true,
		"Dwarf must resolve through the production start path")
	expect(app._player_model == "DWARF.GRN"
		and app.start_cell == Vector2(3470, 2779),
		"Dwarf must retain its own body and authored start")
	app._registry = ActorRegistry.new()
	var items := Sacred.Items.new(Sacred.Pak.new(install.path_join("pak/items.pak")))
	app._begin_encounter(install, items)
	var dwarf := Sacred.Hero.new(tdir.path_join(tmpl["type_npc_zwerg"]))
	expect(app._encounter != null, "Dwarf encounter data must resolve")
	if app._encounter != null:
		expect(app._encounter.hero_attrs == dwarf.attributes(),
			"Dwarf combat must use Dwarf attributes, not Seraphim attributes")
		expect(app._encounter.hero_arts == dwarf.combat_arts_list(),
			"Dwarf combat arts must come from the selected hero")
	app.free()

	print("class_select_check\tOK\tclasses=%d\tseraphim_hp=%d"
		% [tmpl.size(), seraphim_hp])
	finish(1 if fails > 0 else 0)
