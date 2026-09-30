extends "res://checks/check.gd"
## hostile_ai_check.gd -- B1 foundation: a hostile actor with combat stats
## approaches the hero, attacks when in range, and the hero's HP drops.
## Uses the recovered Combat kernels with real derived inputs (not the
## invented constants the --fight demo uses). The attack range is a PORT
## DECISION for the unobserved retail range, named as such.

const ATTACK_RANGE := 1.8   ## cells; a port decision (retail's reach unobserved)
const ATTACK_CD := 2.0      ## seconds between swings; port decision


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
	sim.path_window = PathWindow.new(walk)

	# Hero: derived HP, stands still.
	var hero_id := reg.spawn(1, Vector2(3236.5, 2511.5), 119, 119)
	# Hostile: derived from the creature definition the encounter reads
	# (type 295, GHUL, level 2 -- the quest-74 foe), placed 5 cells away.
	var foe_id := reg.spawn(107, Vector2(3241.5, 2509.5), 134, 134)
	var hero := reg.get_actor(hero_id)
	var foe := reg.get_actor(foe_id)
	sim.focus_actor_id = hero_id

	# Combat stats from the encounter's derived values (recovered kernels).
	foe.set_meta("at", 23.5)
	foe.set_meta("pa", 25.8)
	foe.set_meta("raw_damage", 7.0)

	var brain := HostileBrain.new()
	brain.setup(foe_id, hero_id, ATTACK_RANGE, ATTACK_CD)

	# --- approach phase: hostile moves toward the hero ---
	var start_dist := foe.cell.distance_to(hero.cell)
	for i in 600:
		sim.advance(sim.tick_dt(), reg, hero.cell)
		brain.step(sim, reg, 1.0 / 30.0)
		if foe.cell.distance_to(hero.cell) <= ATTACK_RANGE:
			break
	var approach_dist := foe.cell.distance_to(hero.cell)
	if approach_dist > start_dist:
		fails += 1
		printerr("hostile did not approach: %f -> %f" % [start_dist, approach_dist])
	expect(approach_dist <= ATTACK_RANGE + 0.5,
		"hostile must close to attack range (got %f)" % approach_dist)

	# --- attack phase: hero HP drops after enough in-range ticks ---
	var hp_before := hero.hp
	for i in 300:
		sim.advance(sim.tick_dt(), reg, hero.cell)
		brain.step(sim, reg, 1.0 / 30.0)
	var hp_after := hero.hp
	if hp_after >= hp_before:
		fails += 1
		printerr("hero HP did not drop: %d -> %d" % [hp_before, hp_after])
	expect(hp_after < hp_before, "in-range hostile must damage the hero")

	# --- dead hero: hostile stops attacking ---
	hero.hp = 0
	hero.flags &= ~ActorState.FLAG_ALIVE
	var swings_after_death := 0
	for i in 100:
		sim.advance(sim.tick_dt(), reg, hero.cell)
		var pre := brain.attack_count
		brain.step(sim, reg, 1.0 / 30.0)
		if brain.attack_count > pre:
			swings_after_death += 1
	expect(swings_after_death == 0, "hostile must not attack a dead target")

	print("hostile_ai_check\tOK\tapproach=%f->%f\thp=%d->%d"
		% [start_dist, approach_dist, hp_before, hp_after])
	finish(1 if fails > 0 else 0)
