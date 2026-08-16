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
##   PLACEHOLDER  the two RATINGS and the hostile's hit points. creature.pak
##              is fully read now (row 949) and its six base attributes are
##              real -- the Ghoul's are STK 35, RES 35, GES 25, REPHY 40,
##              REMAG 0, CHARISMA 50 -- but nothing recovered says which
##              attribute becomes the attack rating and which the defence
##              rating, and HP is in no table at all. So the ATTRIBUTES are
##              read and the two ratings they feed are still invented.
##              Experience is NOT a placeholder: `exp = A + level*B` is
##              retail's own comment and both terms are in the file.
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

## THE LEVELS ARE NO LONGER INVENTED. The hero's is read from retail's own
## new-game character (`templates/hero01.ptx`, row 955) and the hostile's from
## the clamp `Sacred.SpawnLevels.level_for` transcribes (row 956), applied to
## the start sector's own band. The constants here are only the fallback for an
## install missing those files.
const HERO_LEVEL_FALLBACK := 1
const FOE_LEVEL_FALLBACK := 1
## Retail's Seraphim, picked by CharacterType rather than by filename: type 1
## is Seraphim in the executable's class table (sub_815B3A2) and in global.res's
## slot list, independently. See Sacred.Hero.
const HERO_TYPE := 1
const TEMPLATES := 8

## ponytail: THE TWO RATINGS ARE STILL PLACEHOLDERS -- but it is now possible
## to say exactly WHY, which is the difference between a gap and an excuse.
##
## `sub_81F596E` accumulates attack and defence at creature-struct +0xE6 and
## +0xEA, both initialised to 1.0 by cCreatureHero::CalcResults, and each of
## the eight skill slots multiplies in through the recovered curve
## (Combat.skill_rating). A rating is therefore `base x product of skill
## curves`, and it is the BASE that is unrecovered.
##
## For THIS encounter the base is not merely half the answer, it is all of it:
## a new Seraphim knows Magic Lore and Weapon Lore, balance families MK and WK,
## and neither carries an AW or a VW triplet. At level 1 no skill she has feeds
## either rating, so both are entirely base.
const HERO_AT := 120
const FOE_PA := 100
const FOE_HP := 40
## The kernel applied to a real attribute, reported so the difference between
## "read" and "invented" is visible in the status line rather than only in a
## comment. WHICH attribute feeds which rating is the missing half.
const FOE_KERNEL_ATTR := 2      ## Creatures.B_GES
## ponytail: damage per landed blow is a PLACEHOLDER TOO, and a flat one --
## the resolution step (damage against resistance) is undecoded, so there is
## deliberately no formula here to be wrong about.
const HERO_DAMAGE := 7

var found := false
## Read from retail, not chosen. hero_level is the template's; foe_level is the
## band clamp applied to it; band is the start sector's own.
var hero_level := HERO_LEVEL_FALLBACK
var foe_level := FOE_LEVEL_FALLBACK
var band := Vector2i(-1, -1)
var hero_class := ""            ## the class name global.res gives HERO_TYPE
var hero_skills: Array[Dictionary] = []
var hero_attrs := PackedInt32Array()
var foe_id: int = 0             ## ActorRegistry id, 0 when nothing spawned
var foe_cell := Vector2i(-1, -1)
var foe_body := ""              ## the .GRN the hostile wears
var foe_class := 0
var hostile := false            ## per the faction matrix, not per our opinion
var giver_cell := Vector2i(-1, -1)
var giver_body := ""
var giver_name := ""            ## the op-1 `res:` slot, resolved when it can be
var foe_base := PackedInt32Array()   ## the six BASE attributes, read from creature.pak
var foe_exp := 0                ## experience awarded on the kill, exp = A + level*B
var foe_speed := Vector2i.ZERO
var awarded_exp := 0            ## banked when the hostile dies
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
	_read_hero(install)

	# The hostile, found by the NAME retail gave its position rather than by a
	# cell typed here. If the label ever moves, this finds it at its new cell.
	var sc := Sacred.Startcode.new(dir)
	_read_level(install, sc)
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
			foe_base = creatures.base_all(n["body"])
			foe_exp = creatures.experience(n["body"], foe_level)
			foe_speed = creatures.speed(n["body"])
		if factions != null and foe_class != 0:
			hostile = factions.hostile(HERO_CLASS, foe_class)
		if registry != null and foe_cell.x >= 0:
			foe_id = registry.spawn(n["body"], Vector2(foe_cell) + Vector2(0.5, 0.5),
				FOE_HP, FOE_HP)
		break
	found = foe_cell.x >= 0


## The hero retail would hand a new game. The eight templates are scanned for
## the one whose CharacterType is HERO_TYPE rather than a filename being
## assumed: `hero01.ptx` happens to be the Seraphim, but the file ORDER and the
## type enum are two different things and only the enum is documented.
func _read_hero(install: String) -> void:
	for i in TEMPLATES:
		var path := install.path_join("templates/hero%02d.ptx" % i)
		if not FileAccess.file_exists(path):
			continue
		var h = Sacred.Hero.new(path)
		if not h.found or h.character_type != HERO_TYPE:
			continue
		hero_level = h.level
		hero_skills = h.skills()
		hero_attrs = h.attributes()
		var res = Sacred.Resources.new(install.path_join("scripts/us/global.res"))
		hero_class = res.slot(h.class_slot())
		return
	push_warning("Encounter: no template carries CharacterType %d" % HERO_TYPE)


## The hostile's level, which retail derives from the HERO's level clamped into
## the start sector's band -- not sampled from it. See
## Sacred.SpawnLevels.level_for.
##
## The draw is seeded from the quest id so the demo is reproducible; a live
## game passes its own generator, which is why level_for takes one.
func _read_level(install: String, sc) -> void:
	var cell: Vector2i = sc.start_cell
	if cell.x < 0:
		return
	var sl = Sacred.SpawnLevels.new(install.path_join(TREE))
	if not sl.found:
		return
	band = sl.band_at_cell(cell)
	var rng := RandomNumberGenerator.new()
	rng.seed = QUEST
	foe_level = Sacred.SpawnLevels.level_for(hero_level, band, rng)


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
	var r := Combat.resolve(HERO_AT, FOE_PA, hero_level, foe_level, rng)
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
		awarded_exp = foe_exp
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
	return "encounter\thero=%s\tlvl=%d\tskills=%s\tband=%s\tfoe_lvl=%d\n" % [
		hero_class, hero_level, hero_skills, band, foe_level] \
		+ "encounter\tquest=%d\ttitle=%s\tnpc=%s@%d,%d\tfoe=%s@%d,%d\tclass=%d\thostile=%s\thp=%d\tswings=%d\thits=%d\tlines=%d\tdone=%s" % [
		QUEST, title, giver_body, giver_cell.x, giver_cell.y,
		foe_body, foe_cell.x, foe_cell.y, foe_class, hostile,
		foe_hp(), _attacks, _hits, log.lines.size() if log != null else 0, is_complete()] \
		+ "\tbase=%s\tspeed=%d,%d\texp=%d\tawarded=%d\tK(GES)=%.1f" % [
			foe_base, foe_speed.x, foe_speed.y, foe_exp, awarded_exp,
			Combat.stat_kernel(float(foe_base[FOE_KERNEL_ATTR])) if foe_base.size() > FOE_KERNEL_ATTR else 0.0]


## Resolves the NPC's `res:` name slot. Separate from _init because it needs a
## Sacred.Resources the caller already has, and because the slot's meaning is
## STILL UNVERIFIED -- checks/resources_check.gd showed the instrument cannot
## tell a name from a dialogue line here, so this returns whatever the slot
## holds without claiming it is a name.
func resolve_giver(res) -> String:
	if res == null or giver_name == "":
		return ""
	return res.resolve(giver_name)
