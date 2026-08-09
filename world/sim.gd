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

## Per-tick output hook, invoked at the very end of tick_once(), after the
## actor loop. OUTPUT-ONLY by contract (T-04-08): it must never mutate reg,
## any ActorState, or this Sim -- doing so would make the tick no longer a
## pure function of its inputs, and the whole point of Phase 4 is that two
## runs driven by the same recorded input produce the same state. Invalid
## (Callable()) by default, so tick_once() costs nothing extra when unset.
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
	if focus_actor_id != ActorRegistry.INVALID_ID:
		var focus_actor := reg.get_actor(focus_actor_id)
		if focus_actor != null:
			effective_focus = focus_actor.cell
	for id: int in reg.in_radius(effective_focus, R_SIM):
		_step_actor(reg.get_actor(id))
	if output_hook.is_valid():
		output_hook.call(tick, dropped)


## Must NOT touch hp -- leaving hp untouched by the tick is what makes
## "state survived the unload" an unconfounded assertion in the
## --actor-probe. Phase 4 collision movement: when `walk` is unset, nothing
## moves -- this is the "no navmesh available" case, not a fallback to the
## old placeholder kinematics, which no longer exists.
func _step_actor(a: ActorState) -> void:
	a.ticks_simulated += 1
	if walk != null:
		a.cell = Movement.sweep(a.cell, a.heading * Movement.CELLS_PER_TICK, walk)


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
