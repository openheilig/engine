class_name Movement
extends RefCounted
## Cell-space kinematics: axis-separated sweep against a Walkable navmesh
## (R3.2 -- explicitly not Godot 3D physics, not NavigationServer3D).
##
## Pure geometry, `static`, no instance state -- the same shape
## Sacred.slot_uv and IsoCamera.cell_to_world/world_to_cell already use for
## a coordinate-space function that owns no data of its own.

## ponytail: 4.0 cells/sec is UNMEASURED -- no retail capture of Sacred's
## own player speed exists yet (same placeholder posture sim.gd's TICK_HZ
## comment states this class about its own 30 Hz). The upgrade path is a
## retail capture through install/shim/autopilot.c, the same route that
## measured IsoCamera's three ZOOM_SCALES steps. Do not read this as a
## recovered constant. It replaces the deleted Sim.STEP_CELLS_PER_TICK,
## which was itself a placeholder never meant to survive Phase 4.
const CELLS_PER_TICK := 4.0 / float(Sim.TICK_HZ)


## Moves `from` by `delta`, resolved one axis at a time -- x against the
## unchanged y, then y against the now-resolved x -- so a diagonal move
## against a wall corner slides along the open axis instead of stopping
## dead. Resolving x before y is a decision, recorded here rather than left
## implicit, the way ActorRegistry.in_radius's inclusive boundary is
## recorded at actor_registry.gd:95. `delta` is already the per-tick
## movement -- callers wanting CELLS_PER_TICK-scaled motion from a heading
## multiply before calling; a zero `delta` returns `from` unchanged.
##
## Point collision (D-11): the actor's cell position is tested directly
## against the DESTINATION cell (floori of the moved-to coordinate) -- no
## radius. Walkable only classifies whole cells, so a blocked axis rejects
## that axis' move in full; there is no partial-cell sliding within a
## blocked cell.
##
## ponytail: a point clips diagonal corners a real body could not pass
## through. The upgrade path is a collision radius -- it needs a measured
## constant, not a placeholder, and does not change the recording format,
## because the recording carries intent rather than resolved geometry
## (D-01).
static func sweep(from: Vector2, delta: Vector2, walk: Walkable) -> Vector2:
	var pos := from
	if delta.x != 0.0:
		var moved_x := Vector2(pos.x + delta.x, pos.y)
		# floori, not int: truncation toward zero is wrong on the negative
		# side of the origin, and the bug would stay invisible until
		# something crossed it.
		if walk.is_open(floori(moved_x.x), floori(moved_x.y)):
			pos.x = moved_x.x
	if delta.y != 0.0:
		var moved_y := Vector2(pos.x, pos.y + delta.y)
		if walk.is_open(floori(moved_y.x), floori(moved_y.y)):
			pos.y = moved_y.y
	return pos
