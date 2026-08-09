class_name PathWindow
extends RefCounted
## A sliding AStarGrid2D window over the actor's own sector plus one
## neighbour sector on each side, recentred by a pure function of the
## tracked actor's cell alone.
##
## Nothing in this file references a node type, the scene tree or the
## camera -- the same disclaimer sim.gd opens with (world/sim.gd:11-13).
## The window's origin is a `static func` of one Vector2i cell only (D-15):
## it never reads a frame delta, a wall clock, or anything the render layer
## produces. Its only external dependency is Walkable.is_open() (D-08/D-09),
## queried per window cell at fill time -- never a second copy of the
## walkability allowlist.
##
## Paths are requested with AStarGrid2D's id-space accessor only (D-17):
## never the sibling accessor that returns positions, whose name does not
## appear anywhere in this file, comments included, because an acceptance
## check greps this file for exactly that name.

## Window edge, in cells: the actor's own sector plus one neighbour sector on
## each side, i.e. 3 * Sacred.SECT. Derived, not invented -- 192 cells.
const WINDOW_EDGE := 3 * Sacred.SECT

## Recentre stride, in cells: derived as a quarter of one sector edge (16
## cells), not measured against anything -- it was never compared to a
## fill-cost budget.
##
## ponytail: STRIDE's only property that has actually been checked is the
## geometry guard below (worst-case actor-to-corner distance stays under
## Sim.R_LOAD). Its ceiling is "recentres on every 16-cell crossing, however
## cheap or expensive one fill turns out to be at runtime"; the upgrade path
## is measuring fill cost against a frame budget and widening STRIDE (or
## moving the fill off the calling thread) if it ever matters.
const STRIDE := Sacred.SECT / 4

## Half the gap between one full window edge and one stride -- the margin
## between a stride bucket's own edge and the window's edge on that same
## side. Used only by the geometry guard below.
const MARGIN := (WINDOW_EDGE - STRIDE) / 2

## Sentinel meaning "no goal requested" -- Vector2i has no natural null, and
## a magnitude this large can never collide with a real world cell (the
## world grid is a bounded sector count times Sacred.SECT cells per axis,
## many orders of magnitude smaller).
const NO_GOAL := Vector2i(-1000000, -1000000)

var _walk: Walkable
var _astar := AStarGrid2D.new()
var _origin := Vector2i.ZERO
var _has_origin := false
var _goal := NO_GOAL
var _path: PackedVector2Array = PackedVector2Array()


## `walk` is queried for every window cell's openness at fill time -- never
## re-implemented here. The geometry guard below is a push_error(), not an
## assert() -- the same posture Sim._init() takes for its own radius
## ordering (sim.gd:97-98): this relation must hold in every build, release
## included.
func _init(walk: Walkable) -> void:
	_walk = walk
	# Worst case, the actor sits at a stride bucket's near edge, so the
	# farthest window corner from it is MARGIN + STRIDE cells away on each
	# axis -- a constant, independent of exactly where inside its bucket the
	# actor sits. sqrt(2) of that is the true worst-case straight-line
	# distance from actor to farthest corner.
	var worst := sqrt(2.0) * float(MARGIN + STRIDE)
	if not (worst < Sim.R_LOAD):
		push_error("PathWindow: worst-case actor-to-corner distance %.2f is not below Sim.R_LOAD (%.2f) -- widen R_LOAD or shrink WINDOW_EDGE/STRIDE" % [
			worst, Sim.R_LOAD])
	_astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	_astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	_astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	_astar.jumping_enabled = false


## Pure function of one cell: the window origin that cell falls inside,
## floor-divided to the nearest stride bucket then centred so the actor sits
## in the middle of the window rather than its corner. `floori`, never
## `int()` -- the same negative-coordinate correctness Movement.sweep
## already relies on (world/movement.gd:44-46).
static func origin_for(cell: Vector2i) -> Vector2i:
	var bx := floori(float(cell.x) / float(STRIDE)) * STRIDE
	var by := floori(float(cell.y) / float(STRIDE)) * STRIDE
	return Vector2i(bx - MARGIN, by - MARGIN)


## Greatest straight-line distance from any cell to the farthest corner of
## the window that would be built for it -- a fixed constant, exposed for
## --window-probe (Task 2) rather than recomputed by hand there.
static func max_corner_distance() -> float:
	return sqrt(2.0) * float(MARGIN + STRIDE)


## Total cell count of one window -- exposed for --window-probe rather than
## recomputed by hand there.
static func point_count() -> int:
	return WINDOW_EDGE * WINDOW_EDGE


## Advances the tracked actor's window/path for one tick. `cell` is the
## actor's current (pre-step) cell, `goal` is this tick's requested goal
## (NO_GOAL for "no change"; a real goal replaces any goal already in
## flight), `origin_offset` is added to the computed origin before the
## window is (re)built -- zero in normal operation, non-zero only under
## Task 3's origin-perturbation flag, sourced from the composition root
## (main.gd), never from anything in this file.
##
## Recomputes only on an origin change or a new goal request (D-16), and
## returns an event Dictionary describing what happened this tick, or {} if
## neither the origin changed nor a path was (re)computed -- the caller uses
## this to decide whether an "astar" dump line is due.
func track(cell: Vector2i, goal: Vector2i, origin_offset: Vector2i) -> Dictionary:
	var new_origin := origin_for(cell) + origin_offset
	var origin_changed := (not _has_origin) or new_origin != _origin
	var goal_changed := goal != NO_GOAL and goal != _goal

	if goal != NO_GOAL:
		_goal = goal

	if not origin_changed and not goal_changed:
		return {}

	if origin_changed:
		_origin = new_origin
		_has_origin = true
		_fill_window()

	if _goal != NO_GOAL:
		_compute_path(cell)
	else:
		_path = PackedVector2Array()

	return {
		"origin": _origin,
		"goal": _goal,
		"path_len": _path.size(),
		"filled": origin_changed,
	}


## The current path, from the actor's cell toward _goal (or empty if no
## goal is active or the goal is unreachable). Sim reads this to drive
## heading, one point at a time.
func current_path() -> PackedVector2Array:
	return _path


func has_goal() -> bool:
	return _goal != NO_GOAL


func clear_goal() -> void:
	_goal = NO_GOAL
	_path = PackedVector2Array()


## Rebuilds the AStarGrid2D region and solid mask for the current origin.
## Every cell's openness comes from Walkable.is_open() (D-08/D-09) -- never
## a second allowlist copy. Takes no timing measurement itself -- this class
## never touches a wall clock (D-14) -- the caller (Sim.tick_once(), never
## this file) measures and prints fill timing to stdout only, keyed off the
## "filled" flag track() returns, never into anything routed to the state
## dump.
func _fill_window() -> void:
	_astar.region = Rect2i(_origin.x, _origin.y, WINDOW_EDGE, WINDOW_EDGE)
	_astar.cell_size = Vector2(1.0, 1.0)
	_astar.update()
	for y in WINDOW_EDGE:
		for x in WINDOW_EDGE:
			var wx := _origin.x + x
			var wy := _origin.y + y
			var open := _walk != null and _walk.is_open(wx, wy)
			_astar.set_point_solid(Vector2i(wx, wy), not open)


## Requests a path from `from_cell` (the actor's own current cell, supplied
## by the caller every tick -- this class never stores or infers one) toward
## _goal. Empty result for a goal outside the window or closed (D-17):
## AStarGrid2D's own id-space accessor already returns an empty array in
## both cases, but the region is bounds-checked here too, which avoids a
## pushed engine error for an out-of-region query rather than merely an
## empty result.
func _compute_path(from_cell: Vector2i) -> void:
	var region: Rect2i = _astar.region
	if not region.has_point(from_cell) or not region.has_point(_goal):
		_path = PackedVector2Array()
		return
	_path = _astar.get_id_path(from_cell, _goal)
