extends "res://checks/check.gd"
## class_select_check.gd -- G1: every one of the eight classes resolves its
## own start template by CharacterType, opens its startcode, and builds a
## session with derived level-1 HP. The Seraphim default is untouched.

func _init() -> void:
	super()
	var fails := 0
	var install := Sacred.find_install()
	assert(not install.is_empty(), "retail install is required")
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
		if dir == "type_npc_seraphim":
			seraphim_hp = s.player_hp_max

	# The default new game stays the Seraphim at her known 119 HP.
	var dflt := GameSession.new_game(install, Vector2(3236.5, 2511.5))
	expect(dflt.hero_level == 1, "default stays level 1")
	expect(dflt.player_hp_max == 119 or dflt.player_hp_max == seraphim_hp,
		"default HP %d drifted from the Seraphim's %d"
			% [dflt.player_hp_max, seraphim_hp])

	print("class_select_check\tOK\tclasses=%d\tseraphim_hp=%d"
		% [tmpl.size(), seraphim_hp])
	finish(1 if fails > 0 else 0)
