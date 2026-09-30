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


func setup(hostile_id: int, target: int, range_cells: float, cooldown_s: float) -> void:
	actor_id = hostile_id
	target_id = target
	attack_range = range_cells
	attack_cooldown = cooldown_s
	cooldown_remaining = 0.0
	attack_count = 0


## One sim tick. Moves toward the target if out of range (by setting the
## hostile's heading — the sim's sweep moves all in-radius actors); attacks
## if in range and the cooldown has expired. Dead targets are never
## attacked.
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
		# Approach: set heading toward the target. The sim's sweep moves
		# every in-radius actor, not just the focus, so this works for the
		# hostile without touching the hero's own path window.
		var dir := target.cell - actor.cell
		if dir.length_squared() > 0.0001:
			actor.heading = dir.normalized()
		cooldown_remaining = maxf(0.0, cooldown_remaining - dt)
		return

	# In range: stop, cooldown, swing.
	actor.heading = Vector2.ZERO
	cooldown_remaining -= dt
	if cooldown_remaining > 0.0:
		return
	cooldown_remaining = attack_cooldown
	_attack(reg, actor, target)


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
