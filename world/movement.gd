class_name Movement
extends RefCounted
## Cell-space kinematics: axis-separated sweep against a Walkable navmesh
## (R3.2 -- explicitly not Godot 3D physics, not NavigationServer3D).
##
## Pure geometry, `static`, no instance state -- the same shape
## Sacred.slot_uv and IsoCamera.cell_to_world/world_to_cell already use for
## a coordinate-space function that owns no data of its own.

## MEASURED from retail on 2026-08-17 (row 1013), replacing the 4.0 placeholder
## that made the port's hero cover ground ~2.7x faster than the game it copies.
##
## The measurement, run twice through install/shim/autopilot.c: load the
## harness save, click-walk the hero along a single iso axis over open grass,
## capture the framebuffer every 500 ms, and phase-correlate consecutive
## frames -- the camera tracks the player, so its total scroll IS the walk.
## Two independent runs of the same route landed at (277,139) and (275,138)
## screen px net -- a pure 2:1 iso-axis ratio, 5.77 cells at the 48 px/cell
## x-step -- over ~4.1 s of visible motion: 1.4-1.6 cells/s. The zoom step
## was pinned from the same frames by sprite height (~133 px = the
## nominal-zoom humanoid). 1.5 is the midpoint.
##
## KNOWN LIMITS, stated rather than hidden: the walking interval is bracketed
## by 500 ms sampling (about +-0.15 cells/s), the camera follows with a
## catch-up dead-zone so only TOTALS are trusted and never per-window rates,
## and memory reads could not confirm it -- the heap layout is not
## reproducible across runs, so SACRED_WATCH's row-812 offset read the click
## DESTINATION here, not the player. A tighter number wants a per-run offset
## re-derivation inside one process life.
const CELLS_PER_TICK := 1.5 / float(Sim.TICK_HZ)


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
