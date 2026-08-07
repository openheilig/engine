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
## on main.gd actually overrides, so the class constant stays a fixed
## reference point that callers such as the --actor-probe route can drive
## deterministically regardless of any override in effect.
const TICK_HZ := 30
const TICK_DT := 1.0 / float(TICK_HZ)

## Bounds catch-up so a 186 ms worst-case sector build (see PROJECT.md
## "Performance") cannot spiral into an unbounded tick burst.
const MAX_CATCHUP_TICKS := 5

## Simulation radius: actors farther than this from `focus` are not ticked.
## Plan 02 promotes this into the three-radius set r_sim < r_render < r_load;
## until then it is a single module constant here.
const R_SIM := 96.0

const STEP_CELLS_PER_TICK := 0.01

var tick: int = 0
var dropped: int = 0
## Per-instance tick rate, defaulting to TICK_HZ. main.gd's --tickhz=N
## overrides this via the constructor, already clamped to [1, 240] before it
## ever reaches the division in _tick_dt() -- see main.gd's CLI parsing and
## threat T-01-02.
var tick_hz: int = TICK_HZ
var _accum: float = 0.0


func _init(hz: int = TICK_HZ) -> void:
	tick_hz = clampi(hz, 1, 240)


func _tick_dt() -> float:
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
	var dt := _tick_dt()
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
## _step_actor on each.
func tick_once(reg: ActorRegistry, focus: Vector2) -> void:
	tick += 1
	for id: int in reg.in_radius(focus, R_SIM):
		_step_actor(reg.get_actor(id))


## ponytail: deterministic placeholder kinematics, purely so a tick has an
## observable effect to verify against. Phase 4 replaces this with
## cell-space kinematics on the decoded navmesh. Must NOT touch hp --
## leaving hp untouched by the tick is what makes "state survived the
## unload" an unconfounded assertion in the --actor-probe.
func _step_actor(a: ActorState) -> void:
	a.ticks_simulated += 1
	a.cell += a.heading * STEP_CELLS_PER_TICK
