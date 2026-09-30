extends "res://checks/check.gd"
## xp_levelup_check.gd -- C3: XP accumulates on the session from kills;
## when it crosses a Progression threshold the hero levels up (level++,
## max HP recalculated via ActorStats). Verified against the live-observed
## threshold values (L=1→300, 2→1200, 3→3000).

func _init() -> void:
	super()
	var fails := 0
	var install := Sacred.find_install()
	assert(not install.is_empty(), "retail install is required")

	var s := GameSession.new_game(install, Vector2(3236.5, 2511.5))
	expect(s.hero_level == 1, "new hero starts at level 1")
	expect(s.hero_xp == 0, "new hero starts at 0 XP")

	# --- award XP below the first threshold: no level-up ---
	s.award_xp(150)
	expect(s.hero_xp == 150, "XP after first award: %d" % s.hero_xp)
	expect(s.hero_level == 1, "150 XP < threshold(1)=300, still level 1")

	# --- cross the first threshold: level up to 2 ---
	s.award_xp(200)
	expect(s.hero_xp == 350, "XP after second award: %d" % s.hero_xp)
	expect(s.hero_level == 2, "350 XP >= threshold(2)=1200? no: threshold(1)=300, so level 2")
	# threshold(1)=300: xp >= 300 means level >= 2. 350 >= 300 -> level 2.

	# --- max HP recalculates on level-up ---
	var expected_hp := ActorStats.max_hp(22, 22, 22, 22, 2)
	if s.player_hp_max != expected_hp:
		fails += 1
		printerr("max HP at level 2: want %d, got %d" % [expected_hp, s.player_hp_max])
	# Current HP also rises (retail preserves the fraction, but at full HP
	# the hero stays at max).
	if s.player_hp != s.player_hp_max:
		fails += 1
		printerr("full-HP hero should stay at max after level-up")

	# --- cross the second threshold: level 3 ---
	s.award_xp(10000)
	expect(s.hero_level >= 3, "XP %d should be past threshold(2)" % s.hero_xp)

	# --- save/load roundtrip preserves level and XP ---
	var snap := s.snapshot()
	var s2 := GameSession.new_game(install, Vector2(3236.5, 2511.5))
	expect(s2.hero_level == 1, "fresh session starts at level 1")
	if s2.restore(snap) != "":
		fails += 1
		printerr("restore failed")
	expect(s2.hero_level == s.hero_level, "level must survive roundtrip")
	expect(s2.hero_xp == s.hero_xp, "XP must survive roundtrip")
	expect(s2.player_hp_max == s.player_hp_max, "max HP must survive roundtrip")

	print("xp_levelup_check\tOK\tlevel=%d\txp=%d\thp_max=%d"
		% [s.hero_level, s.hero_xp, s.player_hp_max])
	finish(1 if fails > 0 else 0)
