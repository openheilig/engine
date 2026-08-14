extends "res://check.gd"
## Deterministic normal-mode input check: project a click onto a known adjacent
## open cell, route it through IsoCamera's conversion and Sim's PathWindow, and
## verify the actor's cell changes through Movement.sweep.
##
## Run:
##   godot --headless --path godot-port --script res://clickmove_check.gd

const VIEWPORT_SIZE := Vector2(1024.0, 768.0)


func _init() -> void:
	super()
	var install := Sacred.find_install()
	if install == "":
		printerr("clickmove_check: no install found; pass --install=/path/to/install")
		finish(1)
		return
	var world := Sacred.World.new(install.path_join("world"))
	if not world.is_open():
		printerr("clickmove_check: cannot open world")
		finish(1)
		return

	var walk := Walkable.new(world)
	var spawn := _find_adjacent_open(walk)
	if spawn == Vector2i(-1, -1):
		printerr("clickmove_check: no adjacent open cells found")
		finish(1)
		return

	var target := spawn + Vector2i(1, 0)
	var camera_world := IsoCamera.cell_to_world(Vector2(spawn) + Vector2(0.5, 0.5))
	var target_world := IsoCamera.cell_to_world(Vector2(target) + Vector2(0.5, 0.5))
	var click := VIEWPORT_SIZE * 0.5 + Vector2(
		target_world.x - camera_world.x,
		-(target_world.y - camera_world.y))
	var converted_world := IsoCamera.viewport_to_world(click, VIEWPORT_SIZE,
		camera_world, VIEWPORT_SIZE.y)
	var converted := IsoCamera.world_to_cell(converted_world)
	var goal := Vector2i(floori(converted.x), floori(converted.y))

	var registry := ActorRegistry.new()
	var sim := Sim.new()
	sim.walk = walk
	var path_window := PathWindow.new(walk)
	sim.path_window = path_window
	var player_id := registry.spawn(0, Vector2(spawn) + Vector2(0.5, 0.5), 100, 100)
	sim.focus_actor_id = player_id
	sim.pending_goal_actor_id = player_id
	sim.pending_goal = goal
	var before: Vector2 = registry.get_actor(player_id).cell
	for _i in 16:
		sim.tick_once(registry, before)
	var after: Vector2 = registry.get_actor(player_id).cell

	var pass_ := goal == target and after != before and after.x > before.x
	print("clickmove_check\tspawn=%d,%d\ttarget=%d,%d\tclick=%.3f,%.3f\tgoal=%d,%d\tbefore=%.6f,%.6f\tafter=%.6f,%.6f\tverdict=%s" % [
		spawn.x, spawn.y, target.x, target.y, click.x, click.y, goal.x, goal.y,
		before.x, before.y, after.x, after.y, "PASS" if pass_ else "FAIL"])
	finish(0 if pass_ else 1)


func _find_adjacent_open(walk: Walkable) -> Vector2i:
	for sector: Vector2i in [Vector2i(64, 39), Vector2i(4, 37), Vector2i(52, 51)]:
		var origin := sector * Sacred.SECT
		for y in Sacred.SECT:
			for x in Sacred.SECT - 1:
				var cell := origin + Vector2i(x, y)
				if walk.is_open(cell.x, cell.y) and walk.is_open(cell.x + 1, cell.y):
					return cell
	return Vector2i(-1, -1)
