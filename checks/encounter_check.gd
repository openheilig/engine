extends "res://checks/check.gd"
## encounter_check.gd -- the ONE runnable check for the MVP loop: hero, start
## location, hostile, and a real quest that opens and closes.
##
##   godot --headless --path godot-port --script checks/encounter_check.gd
##
## THIS IS THE END-TO-END GATE, and it is here because every layer under it is
## already gated separately and none of those would notice the SEAMS coming
## apart: startcode's position labels, creature.pak's class column, the faction
## matrix in the executable, vectoren's hook indices, the bytecode interpreter
## and the recovered to-hit formula all have to agree for one swing to land and
## one quest to close.
##
## WHAT WOULD MAKE THIS PASS WITHOUT MEANING ANYTHING. A quest that completed
## on its own, or a hostile that was already dead. So the check asserts the
## ORDER: the quest is not complete before the killing blow and is complete
## after it, the hostile's hp strictly decreases only on landed blows, and the
## number of landed blows times the damage accounts for exactly the hp lost.
##
## The hostility assertion is the one that reaches furthest: the Ghoul is
## hostile to the hero because of a 16x16 byte matrix found by shape in the
## retail executable, joined through creature.pak's class column to an
## items.pak record index that startcode.bin names by a position label. Six
## readers, one boolean.
const SEED := 20260816
const MAX_SWINGS := 400
const FOE_BODY := "GHUL.GRN"
## Untoter (undead), NOT Monster -- the first version of this check asserted 2
## and the data said 5. A Ghoul is undead, so the table was right and the
## expectation was wrong; recorded here because "class 5" looks arbitrary
## without it.
const FOE_CLASS := 5
const QUEST_TITLE := "Kampf gegen den Dämon"
const WANT_LINES_OPEN := 3
const WANT_LINES_DONE := 4


func _init() -> void:
	super()
	var install := Sacred.find_install()
	assert(install != "", "no retail install found; pass --install=/path/to/install")
	var items := Sacred.Items.new(Sacred.Pak.new(install.path_join("pak/items.pak")))
	var creatures := Sacred.Creatures.new(install.path_join("pak"))
	var factions := Sacred.Factions.new(install)
	assert(factions.found, "the faction matrix was not found in the executable")
	var registry := ActorRegistry.new()

	var enc := Encounter.new(install, registry, items, creatures, factions)
	assert(enc.found, "the hostile at '%s' was not found in startcode" % Encounter.FOE_PLACE)
	assert(enc.foe_id != 0, "the hostile did not spawn into the registry")

	_placement(enc)
	_hostility(enc)
	_quest_opens(enc)
	_fight(enc, registry)

	print("encounter_check OK %s" % enc.status_line())
	finish(0)


## The hostile is the one retail put there, at the cell retail put it.
func _placement(enc) -> void:
	expect(enc.foe_body.to_upper() == FOE_BODY,
		"the hostile at '%s' wears %s, expected %s" % [Encounter.FOE_PLACE, enc.foe_body, FOE_BODY])
	# Near the Seraphim's own StartPosition, which is the point of choosing it.
	var start := Vector2i(3236, 2511)
	var fc: Vector2i = enc.foe_cell
	var d: int = absi(fc.x - start.x) + absi(fc.y - start.y)
	expect(d > 0 and d < 200,
		"the hostile is %d cells from the start position -- too far to be the start encounter" % d)


## Hostility is READ, through six layers, not asserted about a name.
func _hostility(enc) -> void:
	expect(enc.foe_class == FOE_CLASS,
		"the hostile's creature class is %d, expected %d" % [enc.foe_class, FOE_CLASS])
	expect(enc.hostile, "the faction matrix does not make this creature hostile to the hero")
	# The control: the matrix must not simply return true for everything, or
	# the assertion above would be free. A hero is not hostile to a hero.
	var install := Sacred.find_install()
	var f = Sacred.Factions.new(install)
	expect(not f.hostile(Encounter.HERO_CLASS, Encounter.HERO_CLASS),
		"the faction matrix calls the hero hostile to itself -- it is returning true for everything")


## The quest opens out of its own bytecode, and is NOT complete yet.
func _quest_opens(enc) -> void:
	expect(enc.title == QUEST_TITLE, "the quest is titled '%s', expected '%s'" % [enc.title, QUEST_TITLE])
	expect(enc.begin(), "the quest's OnEnter did not run")
	expect(enc.log.lines.size() == WANT_LINES_OPEN,
		"opening wrote %d quest-book lines, expected %d" % [enc.log.lines.size(), WANT_LINES_OPEN])
	expect(not enc.is_complete(), "the quest is already complete before the fight")
	expect(enc.log.is_running(Encounter.QUEST), "the quest is not running after OnEnter")


## The fight itself, with the accounting that makes a pass mean something.
func _fight(enc, registry) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var hp0: int = enc.foe_hp()
	expect(hp0 == Encounter.FOE_HP, "the hostile starts on %d hp, expected %d" % [hp0, Encounter.FOE_HP])
	var landed := 0
	var swings := 0
	var killed_at := -1
	var prev := hp0
	while swings < MAX_SWINGS and not enc.is_complete():
		var r: Dictionary = enc.strike(rng)
		swings += 1
		var now: int = enc.foe_hp()
		if r["hit"]:
			landed += 1
			expect(now < prev, "a landed blow did not reduce the hostile's hp")
		else:
			expect(now == prev, "a missed blow reduced the hostile's hp")
		# The quest must not close before the hostile is down.
		if enc.is_complete() and killed_at < 0:
			killed_at = swings
			expect(now == 0, "the quest completed while the hostile still had %d hp" % now)
			expect(bool(r["killed"]), "the completing swing did not report the kill")
		prev = now
	expect(killed_at > 0, "the hostile survived %d swings -- the fight never resolved" % swings)
	expect(enc.is_complete(), "the hostile died but the quest did not complete")
	expect(enc.log.is_done(Encounter.QUEST),
		"the quest state is %d, expected %d" % [
			enc.log.state_of(Encounter.QUEST), QuestLog.STATE_DONE])
	expect(enc.log.lines.size() == WANT_LINES_DONE,
		"the finished quest has %d book lines, expected %d" % [enc.log.lines.size(), WANT_LINES_DONE])
	expect(enc.log.autosaves == 1, "the quest requested %d autosaves, expected 1" % enc.log.autosaves)
	# THE ACCOUNTING. Landed blows times the damage must be exactly the hp
	# lost, with the final blow clamped at zero. This is what catches damage
	# being applied twice, or on a miss, or not at all.
	var spent := landed * Encounter.HERO_DAMAGE
	expect(spent >= hp0 and spent < hp0 + Encounter.HERO_DAMAGE,
		"%d landed blows at %d damage account for %d, but the hostile had %d hp" % [
			landed, Encounter.HERO_DAMAGE, spent, hp0])
	# Both outcomes have to occur, or the roll is not doing anything.
	expect(landed < swings, "every swing landed -- the to-hit roll is not being consulted")
	expect(landed > 0, "no swing landed at all")
	# The dead hostile is marked dead, not merely at zero.
	var foe: ActorState = registry.get_actor(enc.foe_id)
	expect(foe != null and (foe.flags & ActorState.FLAG_ALIVE) == 0,
		"the hostile is on 0 hp but still flagged alive")
	# Striking a corpse does nothing, and does not re-run OnExit.
	var before: int = enc.log.lines.size()
	enc.strike(rng)
	expect(enc.log.lines.size() == before, "striking a dead hostile ran the quest's OnExit again")
