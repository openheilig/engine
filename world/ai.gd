class_name HostileBrain
extends RefCounted
## B1 foundation: the simplest hostile AI that is driven by the recovered
## combat kernels rather than invented numbers. Three states — idle,
## approaching, attacking — with a cooldown. The target is the hero by
## default; faction/acquire logic arrives later.
##
## PORT DECISIONS, named in the source and visible in the check:
##   attack_range = 1.8 cells (retail's reach unobserved)
##   attack_cooldown = 2.0 s  (retail's cadence unobserved)
## Both are constructor parameters so an evidence-backed replacement is a
## call-site change, not a rewrite.
##
## Damage uses the recovered Combat kernels (resolve + damage) with the
## attacker's real AT and the defender's real PA — the same numbers the
## encounter computes from templates and creature definitions.

var actor_id: int = 0
var target_id: int = 0
var attack_range: float = 1.8
var attack_cooldown: float = 2.0
var cooldown_remaining: float = 0.0
var attack_count: int = 0
## Called when the brain's attack kills the target (hp reaches 0). The
## session connects this to award XP, drop loot, advance the quest — the
## B1→C2→C3 wiring point.
var on_target_killed: Callable = Callable()
## B2: when valid, the swing is delegated entirely (e.g. Encounter.strike,
## which owns to-hit, damage, kill and quest completion). The brain keeps
## range/cooldown pacing and the kill callback never fires from a delegated
## swing — the delegate owns its own kill follow-up.
var attack_delegate: Callable = Callable()


func setup(hostile_id: int, target: int, range_cells: float, cooldown_s: float) -> void:
	actor_id = hostile_id
	target_id = target
	attack_range = range_cells
	attack_cooldown = cooldown_s
	cooldown_remaining = 0.0
	attack_count = 0


## One sim tick. Moves toward the target if out of range (walkable-check
## steering: try the direct heading first, then ±30°, ±60°, ±90° offsets —
## the first walkable direction wins). Attacks if in range and the cooldown
## has expired. Dead targets are never attacked.
## The sim's sweep moves every in-radius actor, so setting the hostile's
## heading is sufficient for movement.
func step(sim: Sim, reg: ActorRegistry, dt: float) -> void:
	var actor := reg.get_actor(actor_id)
	var target := reg.get_actor(target_id)
	if actor == null or target == null:
		return
	if (target.flags & ActorState.FLAG_ALIVE) == 0:
		return
	if (actor.flags & ActorState.FLAG_ALIVE) == 0:
		return

	var dist := actor.cell.distance_to(target.cell)
	if dist > attack_range:
		_approach(sim, reg, actor, target)
		cooldown_remaining = maxf(0.0, cooldown_remaining - dt)
		return

	# In range: stop, cooldown, swing.
	actor.heading = Vector2.ZERO
	cooldown_remaining -= dt
	if cooldown_remaining > 0.0:
		return
	cooldown_remaining = attack_cooldown
	if attack_delegate.is_valid():
		# The delegate owns to-hit, damage, kill and its own follow-up.
		attack_delegate.call()
		return
	_attack(reg, actor, target)


## Walkable-check steering: the direct heading to the target is tried
## first; if the next step would be blocked, ±30° / ±60° / ±90° offsets
## are tried in order. This is NOT full A* — it's a local avoidance behavior
## that gets around simple walls and corners. The upgrade path is giving
## each hostile its own PathWindow (expensive for crowds).
func _approach(sim: Sim, reg: ActorRegistry, actor: ActorState, target: ActorState) -> void:
	var dir := target.cell - actor.cell
	if dir.length_squared() < 0.0001:
		return
	var direct_angle := dir.angle()
	var step_size := Movement.CELLS_PER_TICK if Movement.CELLS_PER_TICK > 0 else 0.05
	# Try the direct heading, then offset angles.
	for offset in [0.0, PI / 6.0, -PI / 6.0, PI / 3.0, -PI / 3.0, PI / 2.0, -PI / 2.0]:
		var angle: float = direct_angle + offset
		var heading := Vector2.from_angle(angle)
		var next := actor.cell + heading * step_size
		if sim.walk != null and sim.walk.is_open(int(next.x), int(next.y)):
			actor.heading = heading
			return
	# All directions blocked: stop (the hostile is wedged — a real A* would
	# find a path around, but that requires a per-actor PathWindow).
	actor.heading = Vector2.ZERO


## One attack: the recovered to-hit + damage kernels. The attacker's AT and
## the defender's PA come from the meta fields the composition root sets
## from the encounter's derived values; raw damage likewise. A miss is a
## no-op; a hit subtracts the damage from the target's current HP pool via
## the same round-the-truncation retail uses.
func _attack(reg: ActorRegistry, actor: ActorState, target: ActorState) -> void:
	var at: float = actor.get_meta("at", 10.0)
	var pa: float = target.get_meta("pa", 10.0)
	var raw: float = actor.get_meta("raw_damage", 1.0)
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var r := Combat.resolve(at, pa, rng)
	attack_count += 1
	if not r["hit"]:
		return
	var dmg := Combat.damage(
		PackedFloat32Array([raw]), PackedFloat32Array(),
		PackedByteArray(), 1, 1)
	target.hp = maxi(0, target.hp - roundi(dmg[0]))
	if target.hp == 0:
		target.flags &= ~ActorState.FLAG_ALIVE
		if on_target_killed.is_valid():
			on_target_killed.call(target_id, actor_id)
