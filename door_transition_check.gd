extends "res://check.gd"
## General door-transition probe: verifies the footprint-derived crossing
## (main.gd `_door_transition` helpers) against the real OZELT1 footprint in
## both directions. Mirrors main.gd's logic so the production helpers and this
## probe share the same data model.

const SECT := 64

func _init() -> void:
	super()
	var install := Sacred.find_install()
	if install == "":
		print("door_transition_probe\tinstall=missing")
		finish(1)
		return
	var world := Sacred.World.new(install.path_join("world"))
	var statics := Sacred.Statics.new(Sacred.Pak.new(install.path_join("world/static.pak")))
	var items := Sacred.Items.new(Sacred.Pak.new(install.path_join("pak/items.pak")))
	var footprints := Sacred.Footprints.new(statics, items)
	var walk := Walkable.new(world)
	var interior := Interior.new(world, walk, footprints)
	var registry := ActorRegistry.new()
	var outside := Vector2(3420.5, 1826.5)
	var door_cell := Vector2i(3422, 1844)
	var actor_id := registry.spawn(1, outside, 100, 100)
	var actor := registry.get_actor(actor_id)
	var sim := Sim.new(30)
	sim.focus_actor_id = actor_id
	sim.walk = walk
	sim.interior = interior
	sim.tick_once(registry, actor.cell)

	var hit := _footprint_containing(world, footprints, door_cell)
	if hit.is_empty():
		print("door_transition_probe\tfootprint=missing")
		finish(1)
		return
	var footprint: Dictionary = hit["footprint"]
	var key: int = hit["key"]
	var door := _nearest_door_cell(footprint, door_cell)
	var dest_in := _interior_destination(footprint, door)
	var dest_out := _exterior_destination(interior, footprint, door, dest_in)
	print("door_transition_probe\tdoor=%d,%d\tinside=%d,%d\toutside=%d,%d" % [
		door.x, door.y, dest_in.x, dest_in.y, dest_out.x, dest_out.y])

	var results: Array[String] = []
	interior.derive(actor.cell)
	var inside0: bool = _interior_current(interior, key)
	actor.cell = Vector2(dest_in) + Vector2(0.5, 0.5)
	sim.tick_once(registry, actor.cell)
	var inside1: bool = _interior_current(interior, key)
	results.append("in=%s" % ("INTERIOR" if inside1 else "EXTERIOR"))
	actor.cell = Vector2(dest_out) + Vector2(0.5, 0.5)
	sim.tick_once(registry, actor.cell)
	var inside2: bool = _interior_current(interior, key)
	results.append("out=%s" % ("INTERIOR" if inside2 else "EXTERIOR"))

	print("door_transition_probe\t" + "\t".join(results))
	var ok: bool = (not inside0) and inside1 and (not inside2) and dest_out != Vector2i(-1, -1) and dest_in != Vector2i(-1, -1)
	print("door_transition_probe\tverdict=%s" % ("PASS" if ok else "FAIL"))
	finish(0 if ok else 1)


func _footprint_containing(world: Sacred.World, footprints: Sacred.Footprints,
		cell: Vector2i) -> Dictionary:
	var sx := int(floor(float(cell.x) / float(SECT)))
	var sy := int(floor(float(cell.y) / float(SECT)))
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var gx := sx + dx
			var gy := sy + dy
			if gx < 0 or gy < 0 or gx >= 100 or gy >= 100:
				continue
			if not world.has_sector(gx, gy):
				continue
			var resolved: Variant = footprints.resolve(world.sector(gx, gy), gx, gy)
			if resolved == null:
				continue
			for index: int in resolved:
				var fp: Dictionary = resolved[index]
				if Rect2i(fp["anchor"], fp["size"]).has_point(cell):
					return {"footprint": fp, "key": gx * 1000000 + gy * 1000 + index}
	return {}


func _nearest_door_cell(fp: Dictionary, cell: Vector2i) -> Vector2i:
	var source: Dictionary = fp["region"]
	var anchor: Vector2i = fp["anchor"]
	var size: Vector2i = fp["size"]
	var best := Vector2i(-1, -1)
	var best_dist := 1 << 30
	for y in size.y:
		for x in size.x:
			var cls := Sacred.Regions.cell_class(source, x, y)
			if cls != Sacred.Regions.DOOR and cls != Sacred.Regions.STEP:
				continue
			var d := Vector2i(x + anchor.x, y + anchor.y).distance_squared_to(cell)
			if d < best_dist:
				best_dist = d
				best = Vector2i(x + anchor.x, y + anchor.y)
	return best


func _interior_destination(fp: Dictionary, door: Vector2i) -> Vector2i:
	var source: Dictionary = fp["region"]
	var anchor: Vector2i = fp["anchor"]
	var size: Vector2i = fp["size"]
	var best := Vector2i(-1, -1)
	var best_dist := 1 << 30
	for y in size.y:
		for x in size.x:
			var cls := Sacred.Regions.cell_class(source, x, y)
			if cls != Sacred.Regions.FLOOR:
				continue
			var c := Vector2i(x + anchor.x, y + anchor.y)
			var d := c.distance_squared_to(door)
			if d < best_dist:
				best_dist = d
				best = c
	return best


## The nearest cell outside the footprint that ACTUALLY LEAVES the complex.
##
## "Actually" is the whole fix. The swap is EDGE-TRIGGERED over a GROUPED
## complex (rows 655/677), so whether a cell is exterior depends on where the
## hero came FROM, not on the cell alone: deriving a candidate in isolation can
## say EXTERIOR while arriving there from inside leaves the state INTERIOR.
## This models the real two-step -- derive at `from_inside`, then at the
## candidate -- which is exactly what the check itself then measures.
func _exterior_destination(interior: Interior, fp: Dictionary, door: Vector2i,
		from_inside: Vector2i) -> Vector2i:
	var anchor: Vector2i = fp["anchor"]
	var size: Vector2i = fp["size"]
	var centre := Vector2(anchor) + Vector2(size) * 0.5
	var outward := (Vector2(door) + Vector2(0.5, 0.5) - centre)
	if outward == Vector2.ZERO:
		return Vector2i(-1, -1)
	outward = outward.normalized()
	var max_distance := maxi(size.x, size.y) + 2 + Interior.APPROACH_CELLS
	var key := 53 * 1000000 + 28 * 1000 + 2
	var best := Vector2i(-1, -1)
	var candidates: Array[Array] = []
	for dy in range(-max_distance, max_distance + 1):
		for dx in range(-max_distance, max_distance + 1):
			var candidate := door + Vector2i(dx, dy)
			if Rect2i(anchor, size).has_point(candidate):
				continue
			var delta := Vector2(candidate - door)
			if delta.dot(outward) <= 0.0:
				continue
			candidates.append([dx * dx + dy * dy, candidate])
	# Nearest first, then the real transition test. Sorting before testing keeps
	# the number of derive() pairs to the few nearest cells rather than the
	# whole square.
	candidates.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	for entry: Array in candidates:
		var candidate: Vector2i = entry[1]
		interior.derive(Vector2(from_inside) + Vector2(0.5, 0.5))
		interior.derive(Vector2(candidate) + Vector2(0.5, 0.5))
		if not _interior_current(interior, key):
			best = candidate
			break
	return best


func _interior_current(interior: Interior, key: int) -> bool:
	return interior.current().get(key, Interior.State.EXTERIOR) == Interior.State.INTERIOR
