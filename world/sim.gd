class_name Sim
extends RefCounted
## The single fixed-tick accumulator over the actor registry.
##
## main.gd's _advance_sim() is the ONLY Sim.advance call site outside
## godot-port/world/ -- a hard constraint, not a style preference: it is
## what makes "one tick loop" a greppable fact rather than a claim
## (`/usr/bin/grep -rn 'advance(' godot-port --include=*.gd | /usr/bin/grep
## -v '^godot-port/world/'` must find exactly one line).
##
## Nothing in this file references a node type, the scene tree or the
## camera: `focus` arrives as a plain Vector2 in cell space, so this class
## has no dependency on how, or whether, anything is drawn.

## ponytail: 30 Hz is a PLACEHOLDER. No measurement of retail Sacred's own
## tick rate has been made -- the upgrade path is a retail capture through
## install/shim/autopilot.c. Do not read this as a measured constant. It is
## also the DEFAULT tick rate; per-instance tick_hz (below) is what --tickhz=
## on main.gd actually overrides. TICK_DT is sized for that default only --
## any caller that needs to drive advance() by an exact tick count (the
## --actor-probe route, for instance) MUST feed in this instance's own
## tick_dt(), not this class constant, or the delta fed to advance() and the
## delta the accumulator drains it at will disagree the moment --tickhz
## differs from 30, and the promised "exactly N ticks" silently breaks.
const TICK_HZ := 30
const TICK_DT := 1.0 / float(TICK_HZ)

## Bounds catch-up so a 186 ms worst-case sector build (see PROJECT.md
## "Performance") cannot spiral into an unbounded tick burst.
const MAX_CATCHUP_TICKS := 5

## Three activity radii, all in cells, all with a real consumer (R10.2,
## R10.4). `R_SIM < R_RENDER < R_LOAD` is checked at runtime in `_init()`
## below -- `assert()` alone is not enough, because it is stripped out of
## release builds and this relation must hold in every build.
##
## ponytail: none of the three numbers is measured against retail -- they
## are chosen only to (a) satisfy the ordering relation and (b) sit outside
## the streamer's actual footprint, `IsoCamera.visible_cells(load_margin)`
## with `load_margin = 64.0` (main.gd) at the widest of `IsoCamera`'s three
## `ZOOM_SCALES` steps. `load_margin` is NOT changed here -- it is
## load-bearing for the image-cache sizing and for the
## `28672 quads, 63 textures` load-path invariant. The upgrade path for all
## three is a retail capture that measures Sacred's own real activity
## radius; until then these are placeholders with a checked shape, not
## recovered constants.
const R_SIM := 96.0      ## actors inside this TICK. Consumed by tick_once().
const R_RENDER := 128.0  ## actors inside this are eligible for a view node.
						  ## Reported now as a band count; view/actor_view.gd
						  ## (a later phase) is its second consumer.
const R_LOAD := 160.0    ## the documented outer bound: terrain inside this is
						  ## expected resident, so an actor inside R_SIM can
						  ## assume its ground already exists.

var tick: int = 0
var dropped: int = 0
## Per-instance tick rate, defaulting to TICK_HZ. main.gd's --tickhz=N
## overrides this via the constructor, already clamped to [1, 240] before it
## ever reaches the division in tick_dt() -- see main.gd's CLI parsing and
## threat T-01-02.
var tick_hz: int = TICK_HZ
var _accum: float = 0.0

## Phase 4 additive members -- neither is read anywhere inside advance(),
## its accumulator drain loop, or the dropped-tick report; both are
## consumed only from tick_once(), below.

## Navmesh lookup for _step_actor's collision sweep. Unset (null) by
## default: main.gd's --actor-probe route never assigns one, so an actor
## there simply does not move, which is the "do not reinstate the old
## placeholder kinematics as a fallback" instruction -- not moving is not a
## fallback, it is what "no navmesh available" means.
var walk: Walkable = null

## Building swap derivation. Unset (null) by default: no derivation occurs and
## there is never a camera/caller-focus fallback. When assigned, tick_once()
## supplies only the focus actor's own cell.
var interior: Interior = null

## Per-tick output hook, invoked at the very end of tick_once(), after the
## actor loop, as `call(tick, dropped, astar_event)`. `astar_event` is the
## Dictionary path_window.track() returned this tick ({} on a tick where the
## window neither recentred nor recomputed a path). OUTPUT-ONLY by contract
## (T-04-08): it must never mutate reg, any ActorState, or this Sim -- doing
## so would make the tick no longer a pure function of its inputs, and the
## whole point of Phase 4 is that two runs driven by the same recorded input
## produce the same state. Invalid (Callable()) by default, so tick_once()
## costs nothing extra when unset.
var output_hook: Callable = Callable()

## When set (!= ActorRegistry.INVALID_ID), tick_once() derives its focus
## from that actor's own cell instead of the caller-supplied focus.
## Unset by default, so --actor-probe's caller-supplied-focus behaviour is
## byte-for-byte unchanged. This is not decoration: --record='s one
## advance() call can run several ticks, which would otherwise hold one
## frame's camera focus across all of them, while --replay= recomputes
## focus per tick_once() call -- a silent divergence in which actors
## in_radius() selects, in the one phase whose purpose is detecting
## divergence.
var focus_actor_id: int = ActorRegistry.INVALID_ID

## Plan 04-02 additive members -- the optional path window and its three
## single-shot "pending" fields. Like `walk`/`output_hook`/`focus_actor_id`
## above, none of these is read inside advance()'s accumulator drain loop or
## the dropped-tick report; all are consumed only from tick_once() and
## _step_actor(), below.

## Optional sliding AStarGrid2D window for the focus actor (world/path_window.gd).
## Unset (null) by default -- main.gd's --actor-probe route never assigns
## one, matching `walk`'s own "no navmesh available" posture: an unset
## path_window means no path-following happens, not a fallback.
var path_window: PathWindow = null

## Single-shot goal request: consumed (and reset to INVALID_ID/NO_GOAL) on
## the very next tick_once() call after being set, mirroring how `nudge`/
## `skip` mutate state immediately before one specific tick's tick_once()
## call in Replay.replay(). Only ever applies to the actor named by
## focus_actor_id -- "one request, one goal, one path", no queue.
var pending_goal_actor_id: int = ActorRegistry.INVALID_ID
var pending_goal: Vector2i = PathWindow.NO_GOAL

## Tick this request is FOR. -1 (the default) keeps the original "consumed on
## the very next tick_once()" contract, which is what Replay.replay() relies on
## -- it drives exactly one tick per call, so "next tick" and "tick N" are the
## same thing there. A caller that cannot know which tick will run next sets
## this instead, and the request then fires on the tick that carries this
## number and no other.
##
## Why this exists (04-REVIEW CR-01). main.gd used to decide BEFORE calling
## advance() whether the upcoming tick was the goal tick, testing
## `pre_tick + 1 == GOAL_REQUEST_TICK`. But advance() runs up to
## MAX_CATCHUP_TICKS ticks per call, so after a slow frame the goal tick could
## be the second or third tick of the burst -- the test then failed and the
## goal was applied ZERO times, while the recorder, which range-tests every
## tick it ran, still wrote the goal line. Replay obeyed the recording, the
## live run had not, and the two diverged: a false failure in the project's
## only determinism gate. Comparing against Sim's OWN counter here removes the
## disagreement by construction, because the counter and the recorder are now
## reading the same number.
var pending_goal_tick: int = -1

## Single-shot window-origin offset, consumed the same way as the goal
## fields above. Zero in normal operation; Task 3's origin perturbation is
## the only writer, and it always sources the offset from the composition
## root (main.gd), never from anything inside world/.
var pending_origin_offset: Vector2i = Vector2i.ZERO

## Index into path_window.current_path() the focus actor is currently
## walking toward. Reset to 1 (never 0 -- path[0] is the actor's own
## from-cell, already reached) whenever track() reports a fresh recompute.
var _path_step: int = 1


func _init(hz: int = TICK_HZ) -> void:
	tick_hz = clampi(hz, 1, 240)
	if not (R_SIM < R_RENDER and R_RENDER < R_LOAD):
		push_error("Sim: radius ordering violated -- R_SIM=%.1f R_RENDER=%.1f R_LOAD=%.1f, expected R_SIM < R_RENDER < R_LOAD" % [R_SIM, R_RENDER, R_LOAD])


## Public: the instance's actual per-tick delta, honoring any --tickhz=
## override in effect. Callers that need advance() to consume an exact tick
## count -- main.gd's --actor-probe route is the one that matters today --
## must feed this in, not the class constant TICK_DT, which stays sized for
## the DEFAULT tick rate only.
func tick_dt() -> float:
	return 1.0 / float(tick_hz)


## Adds `delta` to the accumulator and runs whole ticks while it holds at
## least one tick's worth, up to MAX_CATCHUP_TICKS. Returns the number of
## ticks run. delta == 0.0 runs zero ticks and mutates nothing. Any whole
## ticks still pending after the cap are DROPPED, never silently absorbed --
## reported on stdout as "sim\tdropped=<n>\ttick=<tick>".
func advance(delta: float, reg: ActorRegistry, focus: Vector2) -> int:
	if delta == 0.0:
		return 0
	_accum += delta
	var dt := tick_dt()
	var ran := 0
	while ran < MAX_CATCHUP_TICKS and _accum >= dt:
		_accum -= dt
		tick_once(reg, focus)
		ran += 1
	if _accum >= dt:
		var excess := int(_accum / dt)
		dropped += excess
		_accum -= excess * dt
		print("sim\tdropped=%d\ttick=%d" % [excess, tick])
	return ran


## Iterates reg.in_radius(focus, R_SIM) -- ascending id order -- calling
## _step_actor on each. in_radius compares squared distance with `<=`
## (actor_registry.gd), so an actor at EXACTLY R_SIM cells from focus IS
## ticked -- a decision, not an accident; `<` is equally defensible and is
## recorded here so it is not silently inferred from the code later.
##
## When focus_actor_id is set, `focus` is ignored and this tick's focus is
## that actor's own cell instead -- read AFTER `tick` is incremented but
## BEFORE any actor steps, so every actor in this same tick (including the
## focus actor itself) is selected against its pre-step position, matching
## in_radius's existing precedent of reading position once per call rather
## than per actor visited.
func tick_once(reg: ActorRegistry, focus: Vector2) -> void:
	tick += 1
	var effective_focus := focus
	var tracked: ActorState = null
	if focus_actor_id != ActorRegistry.INVALID_ID:
		tracked = reg.get_actor(focus_actor_id)
		if tracked != null:
			effective_focus = tracked.cell

	# Single-shot goal/origin-offset consumption -- reset before track() runs
	# so a re-entrant call (none exists today, but the contract is "consumed
	# on the very next tick_once()") can never see stale state.
	var astar_event: Dictionary = {}
	if path_window != null and tracked != null:
		var goal_this_tick := PathWindow.NO_GOAL
		# pending_goal_tick < 0 means "the next tick", whichever that is (the
		# original contract, still used by Replay.replay()). Otherwise the
		# request is FOR a numbered tick and waits, unconsumed, until `tick`
		# reaches it -- so a catch-up burst that runs several ticks in one
		# advance() call still fires it on the right one. See CR-01 above.
		var due := pending_goal_tick < 0 or pending_goal_tick == tick
		if due and pending_goal_actor_id == tracked.id and pending_goal != PathWindow.NO_GOAL:
			goal_this_tick = pending_goal
		var offset := pending_origin_offset
		if due:
			pending_goal_actor_id = ActorRegistry.INVALID_ID
			pending_goal = PathWindow.NO_GOAL
			pending_goal_tick = -1
		pending_origin_offset = Vector2i.ZERO

		var from_cell := Vector2i(floori(tracked.cell.x), floori(tracked.cell.y))
		var t0 := Time.get_ticks_usec()
		astar_event = path_window.track(from_cell, goal_this_tick, offset)
		if not astar_event.is_empty():
			_path_step = 1   # path[0] is the from-cell itself, already reached
			if bool(astar_event.get("filled", false)):
				print("path_window\tfill_us=%d\ttick=%d" % [Time.get_ticks_usec() - t0, tick])

	for id: int in reg.in_radius(effective_focus, R_SIM):
		_step_actor(reg.get_actor(id))
	# Derive after movement so this tick's dump observes the cell the actor
	# actually reached. The source is still the focus actor itself -- never
	# effective_focus's caller value, camera state, or streaming state.
	if interior != null and tracked != null:
		interior.derive(tracked.cell)
	if output_hook.is_valid():
		output_hook.call(tick, dropped, astar_event)


## Must NOT touch hp -- leaving hp untouched by the tick is what makes
## "state survived the unload" an unconfounded assertion in the
## --actor-probe. Phase 4 collision movement: when `walk` is unset, nothing
## moves -- this is the "no navmesh available" case, not a fallback to the
## old placeholder kinematics, which no longer exists.
##
## Plan 04-02: when this IS the focus actor and path_window has an active
## goal, `a.heading` is overridden for this tick alone from the next path
## cell (never stored back into a.heading -- the next tick recomputes it the
## same way) -- driven through the same Movement.sweep collision sweep every
## other actor uses, so path-following gets identical collision behaviour to
## keyboard/scripted movement rather than a second movement code path.
##
## `a.facing` IS written back, unlike `a.heading`, and it is written from the
## RESOLVED delta -- i.e. after the path override above, not from the intent.
## That is the whole reason it is a second field: the resolved delta is the only
## quantity here that describes the direction the body actually travelled, so
## click-to-move (which never touches heading), scripted intent and replay all
## turn an actor the same way. Held across a zero delta, because a character
## that stopped walking is still facing where it stopped, not at its mesh rest
## orientation -- see world/actor_state.gd's `facing` header for the seed.
func _step_actor(a: ActorState) -> void:
	a.ticks_simulated += 1
	if walk == null:
		return
	var delta := a.heading * Movement.CELLS_PER_TICK
	if path_window != null and a.id == focus_actor_id and path_window.has_goal():
		delta = _path_delta(a)
	if delta.length_squared() > 0.0:
		a.facing = delta
	a.cell = Movement.sweep(a.cell, delta, walk)


## One tick's travel toward the next unreached point in path_window's
## current path. Advances _path_step (and clears the goal on the final
## point) when `a` is already within one tick's travel of the current
## target -- "within one tick's travel" measured the same way Movement.sweep
## measures a step, i.e. against Movement.CELLS_PER_TICK. Returns
## Vector2.ZERO (no movement this tick) once the path is exhausted or empty
## (an empty path means the goal was outside the window or closed, D-17).
func _path_delta(a: ActorState) -> Vector2:
	var path := path_window.current_path()
	if path.is_empty():
		return Vector2.ZERO
	if _path_step >= path.size():
		path_window.clear_goal()
		return Vector2.ZERO
	var target := Vector2(path[_path_step]) + Vector2(0.5, 0.5)
	if a.cell.distance_to(target) <= Movement.CELLS_PER_TICK:
		_path_step += 1
		if _path_step >= path.size():
			path_window.clear_goal()
			return Vector2.ZERO
		target = Vector2(path[_path_step]) + Vector2(0.5, 0.5)
	var dir := target - a.cell
	if dir.length() <= 0.0001:
		return Vector2.ZERO
	return dir.normalized() * Movement.CELLS_PER_TICK


## Simulation order over the full registry, nearest-to-`centre` first (R10.3).
## `Array.sort_custom` is heapsort and explicitly UNSTABLE in Godot 4.7 --
## two elements that compare equal can come out in either relative order,
## and that order is not even guaranteed consistent between runs of the same
## process. The comparator below ends its key in the actor id: ids are
## unique (ActorRegistry's own guarantee -- monotonic, never reused), so no
## two elements can ever compare equal, and heapsort's instability becomes
## structurally UNREACHABLE rather than merely unlikely. Any future
## simulation sort added anywhere in godot-port/world/ must end its key in
## the actor id for the same reason -- this is the one place that reasoning
## is spelled out; every later sort just follows the shape.
##
## dist_sq is compared with exact float equality, not is_equal_approx: an
## approximate primary comparison would silently merge two genuinely
## different distances into a tie and hand the outcome to the id, which is
## a different ordering rule than the one specified here.
##
## Combat's Phase 8 target selection is this function's first real consumer
## -- written correctly now rather than retrofitted.
func order_by_distance(reg: ActorRegistry, centre: Vector2) -> PackedInt64Array:
	var pairs: Array[Array] = []
	for id: int in reg.ids():
		var a := reg.get_actor(id)
		pairs.append([centre.distance_squared_to(a.cell), id])
	pairs.sort_custom(func(x: Array, y: Array) -> bool:
		var dx: float = x[0]
		var dy: float = y[0]
		if dx != dy:
			return dx < dy
		return int(x[1]) < int(y[1]))
	var out := PackedInt64Array()
	out.resize(pairs.size())
	for i in pairs.size():
		out[i] = pairs[i][1]
	return out
