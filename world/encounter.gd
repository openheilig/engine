class_name Encounter
extends RefCounted
## The MVP loop, assembled out of measured data: the hero starts where retail
## starts her, a hostile stands where retail's script puts it, and a real quest
## from vectoren.bin opens when she arrives and closes when the hostile dies.
##
## WHAT IS RETAIL'S AND WHAT IS OURS, stated here because the difference
## matters more than the demo:
##
##   RETAIL'S   the start cell (StartPosition, opcode 45); the hostile's body
##              and cell (startcode.bin op-1 record at the named position
##              `monster107`); its creature CLASS and therefore its hostility
##              (the 16x16 matrix in the executable); quest 74's title and both
##              of its hook bodies, executed as bytecode.
##
##   OURS       that killing this particular hostile completes this particular
##              quest. Quest 74's Trigger hook is ZERO BYTES -- retail drives
##              entry and exit from outside the quest, and nothing recovered so
##              far says what from. So the link below is the port's, and it is
##              in one place, named, rather than spread through the engine.
##
##   PLACEHOLDER  every combat STAT. creature.pak exposes only an id and a
##              class; no shipped table has been shown to carry AT, PA or a
##              level, so the four numbers fed to the recovered to-hit formula
##              are invented. The FORMULA is retail's; the numbers are not.
##
## Nothing here touches the scene tree, a node or a thread (R10.1).

const TREE := "bin/type_npc_seraphim"
const QUEST := 74               ## "Kampf gegen den Dämon"
## The startcode position naming the hostile. `auftrag107` (its quest-giver)
## stands five cells away; both are measured, not chosen.
const FOE_PLACE := "monster107"
## The NPC standing five cells from the hostile. Retail's own label -- German
## "Auftrag" is a commission or errand -- and its op-1 record carries a `res:`
## name slot, so it is the encounter's NPC without anything here choosing one.
const GIVER_PLACE := "auftrag107"
const HERO_CLASS := 1           ## Held, the faction matrix's own enum

## ponytail: PLACEHOLDER STATS, every one. Sized only so neither side is
## certain to win: at equal ratings the recovered formula returns exactly 50.
## The upgrade path is balance.bin plus the creature-struct offsets named in
## combat-formulas.md's `## Open`, not a different number here.
const HERO_AT := 120
const HERO_LEVEL := 5
const FOE_PA := 100
const FOE_LEVEL := 4
const FOE_HP := 40
## ponytail: damage per landed blow is a PLACEHOLDER TOO, and a flat one --
## the resolution step (damage against resistance) is undecoded, so there is
## deliberately no formula here to be wrong about.
const HERO_DAMAGE := 7

var found := false
var foe_id: int = 0             ## ActorRegistry id, 0 when nothing spawned
var foe_cell := Vector2i(-1, -1)
var foe_body := ""              ## the .GRN the hostile wears
var foe_class := 0
var hostile := false            ## per the faction matrix, not per our opinion
var giver_cell := Vector2i(-1, -1)
var giver_body := ""
var giver_name := ""            ## the op-1 `res:` slot, resolved when it can be
var log: QuestLog = null
var title := ""

var _vm: ScriptVM = null
var _code := PackedByteArray()
var _vec = null
var _registry: ActorRegistry = null
var _attacks := 0
var _hits := 0


## `registry` may be null, in which case no actor is spawned and the encounter
## is data-only -- which is what a gate wants when it is checking the quest
## rather than the world.
func _init(install: String, registry: ActorRegistry, items, creatures, factions) -> void:
	var dir := install.path_join(TREE)
	_vec = Sacred.Vectoren.new(dir)
	if not _vec.found or not _vec.has_quest(QUEST):
		push_warning("Encounter: quest %d is not in %s" % [QUEST, TREE])
		return
	_code = FileAccess.get_file_as_bytes(dir.path_join("funkcode.bin"))
	if _code.is_empty():
		push_warning("Encounter: funkcode.bin is unreadable")
		return
	_vm = ScriptVM.new()
	log = QuestLog.new()
	title = _vec.title_of(QUEST)
	_registry = registry

	# The hostile, found by the NAME retail gave its position rather than by a
	# cell typed here. If the label ever moves, this finds it at its new cell.
	var sc := Sacred.Startcode.new(dir)
	for n in sc.npcs:
		if n["place"] == GIVER_PLACE:
			giver_cell = n["cell"]
			giver_body = items.name_of(n["body"]) if items != null else ""
			giver_name = n["name"]
			continue
		if n["place"] != FOE_PLACE:
			continue
		foe_cell = n["cell"]
		foe_body = items.name_of(n["body"]) if items != null else ""
		if creatures != null:
			foe_class = creatures.class_of(n["body"])
		if factions != null and foe_class != 0:
			hostile = factions.hostile(HERO_CLASS, foe_class)
		if registry != null and foe_cell.x >= 0:
			foe_id = registry.spawn(n["body"], Vector2(foe_cell) + Vector2(0.5, 0.5),
				FOE_HP, FOE_HP)
		break
	found = foe_cell.x >= 0


## Opens the quest by running its OWN OnEnter bytecode. False when the hook
## used an opcode ScriptVM will not execute -- which for this quest it does
## not, but a caller should still be told rather than assume.
func begin() -> bool:
	var h: Dictionary = _vec.hook(QUEST, Sacred.Vectoren.H_ON_ENTER)
	if h.is_empty() or not _vm.run(_code, h["offset"], h["length"], log):
		push_warning("Encounter: quest %d OnEnter refused opcode %d" % [QUEST, _vm.refused_op])
		return false
	log.mark_entered(QUEST)
	return true


## One swing at the hostile. Returns {hit, roll, chance, killed}; `killed` is
## true on the blow that takes it to zero, and that is the blow which runs the
## quest's OnExit.
##
## `rng` is the caller's, so a recorded run replays identically -- see
## Combat.resolve.
func strike(rng: RandomNumberGenerator) -> Dictionary:
	var out := {"hit": false, "roll": -1, "chance": 0, "killed": false}
	if _registry == null or foe_id == 0:
		return out
	var foe := _registry.get_actor(foe_id)
	if foe == null or foe.hp <= 0:
		return out
	var r := Combat.resolve(HERO_AT, FOE_PA, HERO_LEVEL, FOE_LEVEL, rng)
	_attacks += 1
	out["hit"] = r["hit"]
	out["roll"] = r["roll"]
	out["chance"] = r["chance"]
	if not r["hit"]:
		return out
	_hits += 1
	foe.hp = maxi(0, foe.hp - HERO_DAMAGE)
	if foe.hp == 0:
		foe.flags &= ~ActorState.FLAG_ALIVE
		out["killed"] = true
		_finish()
	return out


## Runs the quest's own OnExit. Called only from strike(), on the killing blow.
func _finish() -> void:
	var h: Dictionary = _vec.hook(QUEST, Sacred.Vectoren.H_ON_EXIT)
	if h.is_empty() or not _vm.run(_code, h["offset"], h["length"], log):
		push_warning("Encounter: quest %d OnExit refused opcode %d" % [QUEST, _vm.refused_op])


func is_complete() -> bool:
	return log != null and log.is_done(QUEST)


func foe_hp() -> int:
	if _registry == null or foe_id == 0:
		return 0
	var a := _registry.get_actor(foe_id)
	return a.hp if a != null else 0


## One tab-separated status line, in the shape main.gd's other fact lines use.
func status_line() -> String:
	return "encounter\tquest=%d\ttitle=%s\tnpc=%s@%d,%d\tfoe=%s@%d,%d\tclass=%d\thostile=%s\thp=%d\tswings=%d\thits=%d\tlines=%d\tdone=%s" % [
		QUEST, title, giver_body, giver_cell.x, giver_cell.y,
		foe_body, foe_cell.x, foe_cell.y, foe_class, hostile,
		foe_hp(), _attacks, _hits, log.lines.size() if log != null else 0, is_complete()]


## Resolves the NPC's `res:` name slot. Separate from _init because it needs a
## Sacred.Resources the caller already has, and because the slot's meaning is
## STILL UNVERIFIED -- checks/resources_check.gd showed the instrument cannot
## tell a name from a dialogue line here, so this returns whatever the slot
## holds without claiming it is a name.
func resolve_giver(res) -> String:
	if res == null or giver_name == "":
		return ""
	return res.resolve(giver_name)
