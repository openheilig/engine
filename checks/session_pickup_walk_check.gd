extends "res://checks/check.gd"
## session_pickup_walk_check.gd -- C2 wiring, arrival-based pickup: clicking
## an item's cell routes a pickup REQUEST through the session; the pickup
## executes when the hero's path completes at the item's cell, exactly as a
## walk command does. Bounded sim ticks; no wall-clock waits.

func _init() -> void:
	super()
	var fails := 0
	var install := Sacred.find_install()
	assert(not install.is_empty(), "retail install is required")

	var s := GameSession.new_game(install, Vector2(3236.5, 2511.5))
	var world := Sacred.World.new(install.path_join("world"))
	var walk := Walkable.new(world)
	s.sim.walk = walk
	s.sim.path_window = PathWindow.new(walk)
	s.sim.focus_actor_id = s.player_id

	# An item one cell away; the hero walks there and picks it up.
	var iid := s.spawn_item_ground(4748, Vector2i(3239, 2511))
	s.request_pickup(iid)
	expect(s.sim.pending_goal == Vector2i(3239, 2511),
		"pickup request must route a walk goal to the item's cell")
	expect(s.pending_pickup_id == iid, "pickup request must be pending")

	# Drive the sim until arrival or a generous tick bound.
	var arrived := false
	for i in 4000:
		s.tick += 1
		s.sim.advance(s.sim.tick_dt(), s.registry, s.registry.get_actor(s.player_id).cell)
		s.after_tick()
		var hero := s.registry.get_actor(s.player_id)
		if s.pending_pickup_id == 0 \
				and hero.cell.distance_to(Vector2(3239.5, 2511.5)) < 1.5:
			arrived = true
			break
	expect(arrived, "hero must arrive at the item's cell within the tick bound")
	var inst := s.items.instance(iid)
	if inst == null or inst.location != ItemInstances.Location.INVENTORY \
			or inst.owner_id != s.player_id:
		fails += 1
		printerr("arrival pickup failed: %s" % str(inst.to_dict() if inst else {}))

	# The request is consumed: a second after_tick must not re-trigger.
	var count_before: int = s.items.count()
	s.after_tick()
	expect(s.items.count() == count_before, "consumed pickup must not re-trigger")

	print("session_pickup_walk_check\tOK\tticks=%s" % ["bounded"])
	finish(1 if fails > 0 or not arrived else 0)
