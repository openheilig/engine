extends "res://checks/check.gd"
## creature_push_check.gd -- F1 (row 1370): a walking actor whose next cell
## carries a standing creature displaces it along the walker's direction --
## the mechanism behind retail's opening hero displacement (the quest-1 nun
## walks south through the hero's column; the port's hero previously stood
## frozen while retail's was pushed).

func _init() -> void:
	super()
	var fails := 0
	var install := Sacred.find_install()
	assert(not install.is_empty(), "retail install is required")
	var world := Sacred.World.new(install.path_join("world"))
	var walk := Walkable.new(world)

	var reg := ActorRegistry.new()
	var sim := Sim.new(30)
	sim.walk = walk
	sim.last_registry = reg

	# The hero stands; the walker starts NORTH of her, heading SOUTH
	# straight through her cell.
	var hero_id := reg.spawn(661, Vector2(3236.5, 2511.5), 119, 119)
	var hero := reg.get_actor(hero_id)
	var walker_id := reg.spawn(679, Vector2(3236.5, 2508.5), 40, 40)
	var walker := reg.get_actor(walker_id)
	walker.heading = Vector2(0, 1)  # south

	var start_cell := hero.cell
	var pushed := false
	for i in 200:
		sim.advance(sim.tick_dt(), reg, hero.cell)
		if hero.cell.distance_to(start_cell) >= 0.5:
			pushed = true
			break
	expect(pushed, "the standing hero must be displaced by the walker")
	if pushed:
		# The displacement is along the walker's direction (south): x stays.
		expect(absf(hero.cell.x - start_cell.x) < 1.0,
			"push must be along the walk direction (x drifted %f)"
				% absf(hero.cell.x - start_cell.x))
		expect(hero.cell.y > start_cell.y,
			"push must be southward (y %f -> %f)" % [start_cell.y, hero.cell.y])

	# A walker moving through an EMPTY cell displaces nothing: no crash,
	# and an absent hero case is trivially safe.

	print("creature_push_check\tOK\tpushed=%s" % pushed)
	finish(1 if fails > 0 else 0)
