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
		hero_hp = ActorStats.max_hp(stk, rephy, stk, rephy,
			hero.level if hero.level > 0 else 1)
	s.player_hp = hero_hp
	s.player_hp_max = hero_hp
	s.player_cell = spawn_cell
	s.player_id = s.registry.spawn(_hero_record_id(install_path), spawn_cell, hero_hp, hero_hp)
	return s


## Commands enter here -- the one path. v1 carries movement; combat/art
## commands arrive with B1/B2 through the same door.
func move_command(goal: Vector2i) -> void:
	sim.pending_goal_actor_id = player_id
	sim.pending_goal = goal
	sim.pending_goal_tick = -1


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


func _as_session_dict() -> Dictionary:
	return {"registry": registry, "quest_log": quest_log,
		"player_id": player_id, "tick": tick, "tick_hz": tick_hz}


func snapshot() -> Dictionary:
	var snap := SaveState.snapshot(_as_session_dict())
	snap[SCHEMA_KEY_ITEMS] = items.snapshot()
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
