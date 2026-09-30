extends "res://checks/check.gd"
## Exercises main.gd's actual door transition, not a copied destination algorithm.
## The authored OZELT1 doorway must enter/leave its parent trigger; a raw zero
## state must survive standing still rather than being reconstructed as bit1.

func _init() -> void:
	super()
	var install := Sacred.find_install()
	assert(not install.is_empty(), "retail install is required")
	var world := Sacred.World.new(install.path_join("world"))
	var statics := Sacred.Statics.new(Sacred.Pak.new(install.path_join("world/static.pak")))
	var triggers := preload("res://formats/triggers.gd").new(install.path_join("world/triggers.pak"))
	var interior := Interior.new(world, statics, triggers)
	var registry := ActorRegistry.new()
	var outside := Vector2(3420.5, 1826.5)
	var door := Vector2i(3422, 1844)
	var actor_id := registry.spawn(1, outside, 100, 100)
	var actor := registry.get_actor(actor_id)
	var sim := Sim.new(30)
	sim.focus_actor_id = actor_id
	sim.interior = interior
	var app = load("res://main.gd").new()
	app._world = world
	app._shadow_statics = statics
	app._registry = registry
	app._sim = sim
	app._player_id = actor_id
	var parent := interior.parent_for_cell(door)
	assert(not parent.is_empty(), "authored doorway must resolve its parent")
	var trigger: int = parent["trigger"]
	interior.replace_state(trigger, 1)
	expect(not app._door_transition(Vector2i(outside)), "an outside non-door click must not teleport")
	expect(actor.cell == outside, "refused transition must preserve actor position")
	expect(app._door_transition(door), "production doorway must enter")
	sim.tick_once(registry, actor.cell)
	expect(interior.state(trigger) == 2, "entry selects first authored storey")
	var child_cell := interior.cell_data(Vector2i(actor.cell), interior.support_ref())
	expect(not child_cell.is_empty() and (child_cell[31] & 15) == Sacred.Regions.FLOOR,
		"entry destination must be the authored child's floor")

	actor.cell = Vector2(door) + Vector2(0.5, 0.5)
	expect(interior.replace_state(trigger, 0), "raw state zero is valid")
	sim.tick_once(registry, actor.cell)
	expect(interior.state(trigger) == 0, "stationary doorway must preserve external raw zero")
	interior.replace_state(trigger, 2)
	expect(app._door_transition(door), "production doorway must exit")
	sim.tick_once(registry, actor.cell)
	expect(interior.state(trigger) == 1 and interior.support_ref() == 0,
		"exit restores exterior state and releases child support")
	app.free()
	finish(0)
