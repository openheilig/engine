class_name GameSession
extends RefCounted
## S0: the ONE owner of authoritative session state. Plain RefCounted --
## not an autoload, not an event bus: the composition root constructs it
## once and hands it to whatever needs it. Views, HUD and audio consume
## committed state through it; nothing presentation-side writes back.
##
## WHAT IT OWNS TODAY (v1, grows with each state owner per the plan):
##   install/start_template/start_class  content identity
##   registry + player_id + player_cell/hp/hp_max  the hero, derived
##   quest_log  quest state, entered ids, cast handles
##   sim        the fixed-tick accumulator this session advances
##   tick       the session's own clock mirror (SaveState persists it)
##
## WHAT DELIBERATELY IS NOT HERE YET: campaign/difficulty selection (no UI),
## inventory/items (C2), triggers (W2), effects (B2). Adding a field before
## its owner exists would be a placeholder wearing a state's clothes.
##
## new_game() is the single derivation path: the hero's spawn cell arrives
## from the caller (walkable resolution stays with the composition root,
## which owns the camera and world readers); the HP derivation, registry
## spawn, quest-hook run and cast construction happen HERE, so every caller
## -- rendered, renderless, headless check -- gets identical state. That is
## the S0 acceptance: same inputs, same state, view-independent.

const START_CLASS := "type_npc_seraphim"
## The template file START_CLASS creates from. Same placeholder posture as
## main.gd's own constant: a class-selection UI replaces both. (Types are
## NOT file order -- hero02.ptx is the type-9 template.)
const START_TEMPLATE := "hero01.ptx"
## bin/ tree for the class's script bytecode and start position.
const START_SET := 6
## SaveState schema v2: v1's state plus the item instances. SaveState.SCHEMA
## stays at 1 (its own actor/quest contract); the session carries the
## version because it composes the fragments.
const SCHEMA := 2
const SCHEMA_KEY_ITEMS := "items"

var install := ""
var start_class := START_CLASS
var start_template := START_TEMPLATE
var registry: ActorRegistry
var quest_log: QuestCast
var sim: Sim
var items: ItemInstances
var player_id: int = ActorRegistry.INVALID_ID
var player_cell := Vector2.ZERO
var player_hp := 0
var player_hp_max := 0
var hero_level: int = 1
var hero_xp: int = 0
var hero_skill_points: int = 0
var hero_base_stk: int = 0
var hero_base_rephy: int = 0
var tick := 0
var tick_hz: int = Sim.TICK_HZ


## Derives the new-game state at `spawn_cell`. `walk` may be null in
## renderless construction; the hero's own admission is not re-checked here
## because the composition root already resolved the cell against it --
## re-checking with a second Walkable would make the state depend on which
## caller remembered to bind one.
static func new_game(install_path: String, spawn_cell: Vector2) -> GameSession:
	var s := GameSession.new()
	s.install = install_path
	s.registry = ActorRegistry.new()
	s.quest_log = QuestCast.new()
	s.sim = Sim.new(s.tick_hz)
	s.items = ItemInstances.new()

	# Hero max HP: the transcribed sub_81F4FFA base over the template's
	# (STK, REPHY) pair -- live-witnessed on two classes (119, 147;
	# checks/hero_hp_check.gd re-derives the join from the templates).
	var hero_hp := 100
	var hero := Sacred.Hero.new(install_path.path_join("templates/" + s.start_template))
	if hero.found and hero.attributes().size() >= 4:
		var stk: int = hero.attributes()[0]
		var rephy: int = hero.attributes()[3]
		s.hero_base_stk = stk
		s.hero_base_rephy = rephy
		hero_hp = ActorStats.max_hp(stk, rephy, stk, rephy,
			hero.level if hero.level > 0 else 1)
	s.player_hp = hero_hp
	s.player_hp_max = hero_hp
	s.player_cell = spawn_cell
	s.player_id = s.registry.spawn(_hero_record_id(install_path), spawn_cell, hero_hp, hero_hp)
	return s


## Commands enter here -- the one path. v1 carries movement, item
## pickup/drop. Combat/art commands arrive with B1/B2 through the same door.
func move_command(goal: Vector2i) -> void:
	sim.pending_goal_actor_id = player_id
	sim.pending_goal = goal
	sim.pending_goal_tick = -1


## C3: awards XP and checks for level-up. When the accumulated XP crosses
## the Progression threshold for the current level, the hero levels up:
## level++, max HP recalculated from the template's (STK, REPHY) pair at
## the new level. The HP fraction is preserved (retail's own behaviour,
## observed at 0x8188FB3).
func award_xp(amount: int) -> void:
	hero_xp += amount
	var new_level := hero_level
	while hero_xp >= Progression.xp_threshold(new_level):
		new_level += 1
	if new_level > hero_level:
		var old_fraction := 1.0 if player_hp_max <= 0 \
			else float(player_hp) / float(player_hp_max)
		hero_level = new_level
		# One skill point per level (a port decision; retail's exact
		# per-level skill-point curve is un-decoded, the LEVELUP block
		# shows the field exists but its rate is a named next step).
		hero_skill_points += 1
		player_hp_max = ActorStats.max_hp(
			hero_base_stk, hero_base_rephy, hero_base_stk, hero_base_rephy,
			hero_level)
		player_hp = maxi(1, int(player_hp_max * old_fraction))
		var p := registry.get_actor(player_id)
		if p != null:
			p.hp = player_hp
			p.hp_max = player_hp_max


## C3: checks whether the hero has died (HP reached 0). Sets the death
## flag; `respawn_hero()` is the recovery path.
var hero_dead := false


## Call after each sim advance (or after combat damage). When the hero's
## HP reaches 0, clears FLAG_ALIVE and sets the death flag.
func check_hero_death() -> void:
	if hero_dead:
		return
	var p := registry.get_actor(player_id)
	if p == null:
		return
	if p.hp <= 0:
		p.hp = 0
		p.flags &= ~ActorState.FLAG_ALIVE
		hero_dead = true


## C3: respawns the hero at `cell` with full HP, clearing the death flag.
## The cell is the composition root's start cell; the session doesn't
## own it. Returns "" on success.
func respawn_hero(cell := Vector2.ZERO) -> String:
	if not hero_dead:
		return "hero is not dead"
	var p := registry.get_actor(player_id)
	if p == null:
		return "player_id %d does not resolve" % player_id
	p.flags |= ActorState.FLAG_ALIVE
	p.hp = player_hp_max
	if cell != Vector2.ZERO:
		p.cell = cell
		player_cell = cell
	hero_dead = false
	return ""


## Spawns a fresh item instance on the ground at `cell`. Returns the
## instance id (<= 0 on refusal -- items.pak definitions are not validated
## here; the definition reader owns that).
func spawn_item_ground(definition_id: int, cell: Vector2i) -> int:
	return items.spawn(definition_id, cell)


## C2 command: an actor picks up a GROUND instance. Transactional; returns
## "" or the reason.
func pickup_item(instance_id: int, by_actor: int = player_id) -> String:
	var i := items.instance(instance_id)
	if i == null:
		return "no instance %d" % instance_id
	if i.location != ItemInstances.Location.GROUND:
		return "instance %d is not on the ground" % instance_id
	if registry.get_actor(by_actor) == null:
		return "actor %d does not exist" % by_actor
	return items.transfer(instance_id, ItemInstances.Location.INVENTORY, by_actor)


## C2 command: an actor drops an owned instance onto the ground at `cell`.
## Transactional; returns "" or the reason.
func drop_item(instance_id: int, cell: Vector2i, by_actor: int = player_id) -> String:
	var i := items.instance(instance_id)
	if i == null:
		return "no instance %d" % instance_id
	if i.location != ItemInstances.Location.INVENTORY \
			and i.location != ItemInstances.Location.EQUIPPED:
		return "instance %d is not carried" % instance_id
	if i.owner_id != by_actor:
		return "instance %d is not owned by actor %d" % [instance_id, by_actor]
	return items.transfer(instance_id, ItemInstances.Location.GROUND, 0, -1, cell)


## C2, arrival-based pickup: clicking an item's cell routes a WALK to that
## cell plus a pending pickup that executes when the path completes. The
## goal and the pending id are one command; `after_tick` (called by the
## composition root after each sim advance) completes it.
const NO_PICKUP := 0
var pending_pickup_id: int = NO_PICKUP


func request_pickup(instance_id: int) -> String:
	var i := items.instance(instance_id)
	if i == null:
		return "no instance %d" % instance_id
	if i.location != ItemInstances.Location.GROUND:
		return "instance %d is not on the ground" % instance_id
	pending_pickup_id = instance_id
	move_command(Vector2i(i.cell.x, i.cell.y))
	return ""


## The composition root calls this after each sim advance. Consumes the
## pending pickup when the hero has arrived at the item's cell.
func after_tick() -> void:
	if pending_pickup_id == NO_PICKUP:
		return
	var i := items.instance(pending_pickup_id)
	if i == null:
		pending_pickup_id = NO_PICKUP
		return
	var hero := registry.get_actor(player_id)
	if hero == null:
		return
	if hero.cell.distance_to(Vector2(i.cell.x + 0.5, i.cell.y + 0.5)) <= 1.5:
		var err := pickup_item(pending_pickup_id)
		pending_pickup_id = NO_PICKUP
		if err != "":
			push_warning("arrival pickup refused: %s" % err)


func _as_session_dict() -> Dictionary:
	return {"registry": registry, "quest_log": quest_log,
		"player_id": player_id, "tick": tick, "tick_hz": tick_hz}


func snapshot() -> Dictionary:
	var snap := SaveState.snapshot(_as_session_dict())
	snap[SCHEMA_KEY_ITEMS] = items.snapshot()
	snap["hero_level"] = hero_level
	snap["hero_xp"] = hero_xp
	snap["hero_skill_points"] = hero_skill_points
	snap["hero_base_stk"] = hero_base_stk
	snap["hero_base_rephy"] = hero_base_rephy
	# W2: trigger states persist -- opened doors and selected storeys
	# survive save/load (retail saves the whole trigger state table).
	if sim != null and sim.interior != null:
		snap["trigger_states"] = sim.interior.triggers.snapshot_states()
	snap["schema"] = SCHEMA
	return snap


func restore(snap: Dictionary) -> String:
	if int(snap.get("schema", -1)) < SCHEMA:
		return "schema %s is older than %d" % [str(snap.get("schema")), SCHEMA]
	# SaveState validates its own v1 fragment contract; the session owns the
	# composite version. Normalize the copy handed down so the fragment
	# validator sees its own version, never the composite's.
	var fragment: Dictionary = snap.duplicate()
	fragment["schema"] = SaveState.SCHEMA
	var err := SaveState.restore(fragment, _as_session_dict())
	if err != "":
		return err
	# A v1 snapshot has no items array -- nothing to restore, nothing lost:
	# v1 saves predate item instances entirely. v2+ carries them.
	if int(snap.get("schema", 1)) >= SCHEMA:
		items = ItemInstances.from_snapshot(snap.get(SCHEMA_KEY_ITEMS, []))
	# C3: hero progression persists with the session.
	hero_level = maxi(1, int(snap.get("hero_level", 1)))
	hero_xp = maxi(0, int(snap.get("hero_xp", 0)))
	hero_skill_points = maxi(0, int(snap.get("hero_skill_points", 0)))
	hero_base_stk = int(snap.get("hero_base_stk", hero_base_stk))
	hero_base_rephy = int(snap.get("hero_base_rephy", hero_base_rephy))
	if sim != null and sim.interior != null \
			and snap.get("trigger_states") is PackedInt32Array:
		sim.interior.triggers.restore_states(snap["trigger_states"])
	var p := registry.get_actor(player_id)
	if p != null:
		player_cell = p.cell
		player_hp = p.hp
		player_hp_max = p.hp_max
	return ""


## The hero's RecordStore id: the first real static-art definition with
## tiles > 0, the same derivation main.gd's default path uses (transcribed
## here so renderless sessions match the rendered path exactly).
static func _hero_record_id(install_path: String) -> int:
	var items := Sacred.Items.new(Sacred.Pak.new(install_path.path_join("pak/items.pak")))
	var mixed := Sacred.Mixed.new(Sacred.Pak.new(install_path.path_join("pak/mixed.pak")))
	var records := RecordStore.new(items, mixed)
	var source := 1
	while source < records.count():
		var id := RecordStore.make_id(RecordStore.KIND_STATIC_ART, source)
		var d := records.def(id)
		if not d.is_empty() and int(d.get("tiles", 0)) > 0:
			return id
		source += 1
	push_error("GameSession: no mixed.pak entry with tiles > 0 found")
	return 0
