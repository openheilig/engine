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
##              The HERO is retail's too, now: `templates/hero01.ptx` is the
##              new-game Seraphim, so her level, skills and attributes are read
##              (row 955). So is the hostile's LEVEL -- the start sector's band
##              clamping her level, with balance.bin's OffLevel/LevelKap for the
##              difficulty (rows 956, 958).
##
##              The two RATINGS are retail's now too (row 959): base attack is
##              `0.5*(STR+DEX)`, base defence `0.2*STR + 0.8*DEX`, over the six
##              attributes already read for each side.
##
##   PLACEHOLDER  the hostile's HIT POINTS and the damage per blow. HP is in no
##              table read so far and the resolution step (damage against
##              resistance) is undecoded, so there is deliberately no formula
##              here to be wrong about. Experience is NOT a placeholder:
##              `exp = A + level*B` is retail's own comment and both terms are
##              in creature.pak.
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
## Silver -- retail's first of four (Silver / Gold / Platinum / Niob). A
## constant until there is a difficulty selector, and named rather than passed
## as a bare 1 so the choice is visible.
const DIFFICULTY := 1

## THE RATINGS ARE NO LONGER INVENTED EITHER (row 959). The base both
## multipliers multiply is `0.5*(STR+DEX)` for attack and `0.2*STR + 0.8*DEX`
## for defence -- see Combat.base_attack -- and STR/DEX are the first and third
## of the six attributes this port already reads for both sides: from the hero
## template for her, from creature.pak for the hostile.
##
## THE MULTIPLIERS ARE 1.0 HERE, and that is a reading rather than a shortcut.
## They start at 1.0 in cCreatureHero::CalcResults and are raised only by skills
## whose balance family carries an AW or VW triplet. A new Seraphim knows Magic
## Lore and Weapon Lore -- families MK and WK -- and neither does. So at level 1
## she genuinely has no skill contributing to either rating.
##
## `ProzAW[difficulty]` scales a NON-HERO's ratings; retail ships
## [1.0, 1.5, 2.5, 4.5] and Silver is the identity.
const HERO_MULT := 1.0
const FOE_MULT := 1.0
## ponytail: HIT POINTS ARE STILL A PLACEHOLDER. HP is in no table read so far
## and the resolution step is undecoded, so this is a duration knob and nothing
## claims otherwise.
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
## The two ratings, computed rather than chosen. See the constants above.
var hero_at := 0.0
## The hero's two regeneration rates, keyed by Regen.SPELL / Regen.COMBAT_ART.
var hero_regen := {}
## The combat arts she starts with, in retail's own record layout, each with a
## live `remaining` this class ticks. Read from the template, not granted here:
## a new Seraphim owns exactly what `templates/hero01.ptx` says she owns.
var hero_arts: Array[Dictionary] = []
var _art_uses := 0
var foe_pa := 0.0
var proz_aw := 1.0              ## ProzAW[difficulty]; applies to the hostile only
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
			# The same two attributes, and the hostile DOES take ProzAW -- it is
			# not one of the eight playable classes.
			if foe_base.size() >= 3:
				foe_pa = Combat.rating(
					Combat.base_defence(foe_base[0], foe_base[2]), FOE_MULT, proz_aw)
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
		# STR and DEX are the FIRST and THIRD attributes: the struct reads +0x10
		# and +0x14 of six u16 at +0x10..+0x1A, which in creature.pak's own order
		# (STK, RES, GES, REPHY, REMAG, CHARISMA) are Strength and Dexterity.
		# A hero takes no ProzAW factor -- the getters gate it on type-id > 0x10
		# and the playable classes are 1..9.
		hero_at = Combat.rating(
			Combat.base_attack(h.attribute("STK"), h.attribute("GES")), HERO_MULT)
		# REGENERATION (rows 1043-1046). Sacred charges TIME for a combat art,
		# not mana, and the two rates come from the two attributes the same
		# template already carries: REPHY drives combat arts, REMAG spells.
		#
		# ponytail: bonus = 1.0, which is a bare creature with no item or buff
		# adding to it. The accumulated bonus is what `sub_820E04C` builds out
		# of equipment, and the port equips nothing yet -- when it does, that
		# aggregate replaces the literal and nothing else here changes.
		hero_regen = Regen.rates(1.0, h.attribute("REPHY"), h.attribute("REMAG"))
		hero_arts = h.combat_arts_list()
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
	# Silver, retail's own first difficulty. The two adjustments come from
	# balance.bin's OffLevel/LevelKap (row 958) rather than defaulting to zero,
	# which would cap a levelled hero at the band's own high bound instead of
	# tracking her -- 4 rather than 30 at this sector.
	var bal = Sacred.Balance.new(install)
	foe_level = Sacred.SpawnLevels.level_at_difficulty(
		hero_level, band, rng, bal, DIFFICULTY)
	proz_aw = bal.proz_aw(DIFFICULTY)


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
## `art_id` spends a combat art on this swing. Zero is a plain attack.
##
## SPENDING IS ALL IT DOES, AND THAT IS DELIBERATE. Retail's art records carry
## a second coefficient pair that READS like a damage multiplier for the attack
## moves -- 1.80 + 0.20 a level for HARDHIT against 0.75 + 0.05 for ATTACKE --
## but the same field is a 24-second duration on a shapeshift art, so the
## reading is not recovered and nothing multiplies damage by it. An art costs
## its regeneration and changes nothing else until that is read out of
## `sub_81FAC30`. See research/engine/combat-formulas.md.
##
## A NOT-READY ART IS REFUSED AND THE SWING DOES NOT HAPPEN, which is retail's
## own behaviour: `sub_8218774` gates the use on the same field.
func strike(rng: RandomNumberGenerator, art_id := 0) -> Dictionary:
	var out := {"hit": false, "roll": -1.0, "chance": 0.0, "killed": false,
		"art": 0, "refused": false}
	if _registry == null or foe_id == 0:
		return out
	var foe := _registry.get_actor(foe_id)
	if foe == null or foe.hp <= 0:
		return out
	if art_id != 0:
		if not use_art(art_id):
			out["refused"] = true
			return out
		out["art"] = art_id
		_art_uses += 1
	# Retail's to-hit takes no levels -- the level difference is a DAMAGE effect
	# and is applied below instead (combat-formulas.md, row 1036).
	var r := Combat.resolve(hero_at, foe_pa, rng)
	_attacks += 1
	out["hit"] = r["hit"]
	out["roll"] = r["roll"]
	out["chance"] = r["chance"]
	if not r["hit"]:
		return out
	_hits += 1
	# ponytail: physical channel only, and the hostile's armour and resistance
	# go in as zero because nothing puts them on an actor yet -- there is no
	# inventory and ActorState carries no armour field. Zero armour is retail's
	# own no-armour branch rather than an invented number, so this is the real
	# formula with honest inputs. Wire the other three channels and the
	# creature-info resist column when inventory lands.
	var dmg := Combat.damage(
		PackedFloat32Array([float(HERO_DAMAGE)]), PackedFloat32Array(),
		PackedByteArray(), hero_level, foe_level)
	# Retail keeps damage in float and its hp arithmetic is not recovered, so
	# rounding rather than truncating is the neutral choice. At zero armour the
	# curve returns 0.9999, so this is HERO_DAMAGE either way.
	foe.hp = maxi(0, foe.hp - roundi(dmg[0]))
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


## Advance every art's clock by `dt` seconds. THE CALLER OWNS THE FRAME (R10.1)
## -- this class has no `_process`, and a replay that hands the same deltas back
## reproduces the same clocks.
func regenerate(dt: float) -> void:
	for a in hero_arts:
		var rate: float = hero_regen.get(a["kind"], 0.0)
		a["remaining"] = Regen.tick(a["remaining"], a["total"], dt, rate, a["mult"])


## Is this art usable right now? Retail's own test, through Regen.
func art_ready(art_id: int) -> bool:
	for a in hero_arts:
		if a["id"] == art_id:
			return Regen.ready(a["remaining"])
	return false


## Spend an art: put its whole clock back on. `sub_8218774` reads the same
## field to refuse a second use before it has run down.
func use_art(art_id: int) -> bool:
	for a in hero_arts:
		if a["id"] == art_id and Regen.ready(a["remaining"]):
			a["remaining"] = a["total"]
			return true
	return false


## The arts she owns, in template order -- what a caller passes to strike().
func art_ids() -> PackedInt32Array:
	var out := PackedInt32Array()
	for a in hero_arts:
		out.append(a["id"])
	return out


## What the art slots would draw, 0 just used and 1 ready (row 1043).
func art_fractions() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for a in hero_arts:
		out.append(Regen.fraction(a["remaining"], a["total"]))
	return out


func is_complete() -> bool:
	return log != null and log.is_done(QUEST)


func foe_hp() -> int:
	if _registry == null or foe_id == 0:
		return 0
	var a := _registry.get_actor(foe_id)
	return a.hp if a != null else 0


## One tab-separated status line, in the shape main.gd's other fact lines use.
func status_line() -> String:
	return "encounter\thero=%s\tlvl=%d\tskills=%s\tband=%s\tfoe_lvl=%d\tAT=%.1f\tPA=%.1f\tprozAW=%.2f\thit=%.1f%%\tk=%.3f\n" % [
		hero_class, hero_level, hero_skills, band, foe_level, hero_at, foe_pa,
		proz_aw, Combat.hit_chance(hero_at, foe_pa) * 100.0,
		-log(1.0 - Combat.A5_BASE * Combat.level_term(hero_level, foe_level)) / log(2.0)] \
		+ "encounter\tquest=%d\ttitle=%s\tnpc=%s@%d,%d\tfoe=%s@%d,%d\tclass=%d\thostile=%s\thp=%d\tswings=%d\thits=%d\tlines=%d\tdone=%s" % [
		QUEST, title, giver_body, giver_cell.x, giver_cell.y,
		foe_body, foe_cell.x, foe_cell.y, foe_class, hostile,
		foe_hp(), _attacks, _hits, log.lines.size() if log != null else 0, is_complete()] \
		+ "\tregen_art=%.2f\tregen_spell=%.2f\tarts=%s\tready=%s\tart_uses=%d" % [
			hero_regen.get(Regen.COMBAT_ART, 0.0),
			hero_regen.get(Regen.SPELL, 0.0),
			art_ids(), art_fractions(), _art_uses] \
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
