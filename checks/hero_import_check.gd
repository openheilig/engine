extends "res://checks/check.gd"
## hero_import_check.gd -- P2: a RETAIL hero save (a .pax -- the install's
## own save/heroNN.pax are exactly that) imports into the session with its
## own level, XP, gold and skill points instead of the new-game defaults.

func _init() -> void:
	super()
	var fails := 0
	var install := Sacred.find_install()
	assert(not install.is_empty(), "retail install is required")

	# The retail hero saves shipped in the install.
	var hero_path := install.path_join("save/hero06.pax")
	assert(FileAccess.file_exists(hero_path), "install/save/hero06.pax must exist")
	var hero := Sacred.Hero.new(hero_path)
	assert(hero.found, "hero06.pax must read")
	expect(hero.level > 0, "imported hero level must be positive")

	# Import: the session takes the file's progression, not the template's.
	var s := GameSession.new_game(install, Vector2(3236.5, 2511.5), hero_path)
	expect(s.hero_level == hero.level,
		"imported level %d != hero's %d" % [s.hero_level, hero.level])
	expect(s.hero_xp == hero.experience, "imported XP mismatch")
	expect(s.hero_gold == hero.gold, "imported gold mismatch")
	expect(s.hero_skill_points == hero.level - 1,
		"skill points %d != level-1" % s.hero_skill_points)
	# Her HP derives from HER attribute pair at HER level (ActorStats).
	var a := hero.attributes()
	var expect_hp := ActorStats.max_hp(a[0], a[3], a[0], a[3], hero.level)
	expect(s.player_hp_max == expect_hp,
		"imported max HP %d != derived %d" % [s.player_hp_max, expect_hp])

	# And the default path is untouched: no hero path -> template defaults.
	var d := GameSession.new_game(install, Vector2(3236.5, 2511.5))
	expect(d.hero_level == 1 and d.hero_xp == 0 and d.hero_gold == 0,
		"default new game must stay level 1/0 XP/0 gold")

	# An UNREADABLE hero path falls back to the template, not a crash.
	var f := GameSession.new_game(install, Vector2(3236.5, 2511.5),
		install.path_join("save/does_not_exist.pax"))
	expect(f.hero_level == 1 and f.player_hp_max > 0,
		"missing hero file must fall back to the template")

	print("hero_import_check\tOK\tlevel=%d\txp=%d\tgold=%d\thp_max=%d"
		% [s.hero_level, s.hero_xp, s.hero_gold, s.player_hp_max])
	finish(1 if fails > 0 else 0)
