extends "res://checks/check.gd"
## hero_death_check.gd -- C3: when the hostile kills the hero, the session
## detects it, marks the hero dead, and respawns at the start cell with
## restored HP (retail's death/recovery behaviour).

func _init() -> void:
	super()
	var fails := 0
	var install := Sacred.find_install()
	assert(not install.is_empty(), "retail install is required")

	var s := GameSession.new_game(install, Vector2(3236.5, 2511.5))
	var hero_id := s.player_id
	var hero := s.registry.get_actor(hero_id)

	# --- hero at 0 HP → session detects death ---
	var start_cell := Vector2(3236.5, 2511.5)
	hero.hp = 0
	s.check_hero_death()
	expect((hero.flags & ActorState.FLAG_ALIVE) == 0,
		"hero with 1 HP taking lethal damage must die")
	expect(s.hero_dead, "session must flag hero death")

	# --- respawn: hero returns to the start cell with restored HP ---
	s.respawn_hero()
	expect((hero.flags & ActorState.FLAG_ALIVE) != 0, "respawned hero must be alive")
	expect(hero.cell == start_cell, "respawned hero must be at the start cell")
	expect(hero.hp == s.player_hp_max, "respawned hero must have full HP")
	expect(not s.hero_dead, "hero death flag must clear on respawn")

	# --- non-lethal damage must NOT trigger death ---
	hero.hp = hero.hp_max - 1
	s.check_hero_death()
	expect((hero.flags & ActorState.FLAG_ALIVE) != 0,
		"hero above 0 HP must not die")
	expect(not s.hero_dead, "hero_dead flag must not set for non-lethal HP")

	print("hero_death_check\tOK")
	finish(1 if fails > 0 else 0)
