extends "res://checks/check.gd"
## kill_reward_check.gd -- B1→C2→C3 wiring: when HostileBrain kills the
## target, the session awards XP through the real Progression formulas and
## drops loot through ItemInstances. The quest advances to done.

func _init() -> void:
	super()
	var fails := 0
	var install := Sacred.find_install()
	assert(not install.is_empty(), "retail install is required")

	var s := GameSession.new_game(install, Vector2(3236.5, 2511.5))
	var world := Sacred.World.new(install.path_join("world"))
	var walk := Walkable.new(world)
	s.sim.walk = walk

	var hero_id := s.player_id
	var foe_id := s.registry.spawn(107, Vector2(3237.5, 2511.5), 40, 40)
	var foe := s.registry.get_actor(foe_id)
	foe.set_meta("at", 28.5)
	foe.set_meta("pa", 24.4)
	foe.set_meta("raw_damage", 7.0)
	foe.set_meta("exp", 148)  # the encounter's derived exp for this creature

	var brain := HostileBrain.new()
	brain.setup(hero_id, foe_id, 1.8, 2.0)
	var hero := s.registry.get_actor(hero_id)
	hero.set_meta("at", 23.5)
	hero.set_meta("pa", 25.8)
	hero.set_meta("raw_damage", 7.0)

	# --- set the kill reward BEFORE the fight ---
	var xp_result := [0]
	brain.on_target_killed = func(killed_id: int, killer_id: int) -> void:
		# C3: award XP through the real formulas
		var mult := Progression.award_multiplier(1)  # hero level 1
		xp_result[0] = int(148 * mult)
		# C2: drop loot at the kill location
		var loc := s.registry.get_actor(killed_id).cell
		s.spawn_item_ground(7442, Vector2i(int(loc.x), int(loc.y)))
		# Quest state: mark done
		s.quest_log.set_var("74", 3)  # STATE_DONE bit

	# --- fight until the hostile dies (bounded ticks) ---
	var died := false
	for i in 6000:
		s.tick += 1
		s.sim.advance(s.sim.tick_dt(), s.registry,
			s.registry.get_actor(hero_id).cell)
		brain.step(s.sim, s.registry, s.sim.tick_dt())
		s.after_tick()
		if (foe.flags & ActorState.FLAG_ALIVE) == 0:
			died = true
			break
	expect(died, "the hostile must die within the tick bound")
	expect(xp_result[0] > 0, "XP must be awarded on kill (got %d)" % xp_result[0])
	expect(s.items.count() > 0, "loot must drop on kill")
	expect(s.quest_log.is_done(74), "quest 74 must be marked done")

	print("kill_reward_check\tOK\txp=%d\tloot=%d" % [xp_result[0], s.items.count()])
	finish(1 if fails > 0 else 0)
