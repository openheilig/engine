extends "res://checks/check.gd"
## pax_check.gd -- Sacred.Pax framing AND Sacred.Hero, the new-game character.
##
##   godot --headless --path . --script res://checks/pax_check.gd
##
## THIS GATE USED TO BE PERMANENTLY RED. It demanded $SACRED_CHARS, a
## third-party eight-hero corpus that is not part of the retail install, so it
## failed on every machine that did not happen to have one. The install ships
## its own subjects and always did: `templates/hero00.ptx` .. `hero07.ptx` are
## `.pax` files in all but extension. Retail does not even parse them -- it
## copies the chosen one 512 bytes at a time into `Save/HeroNN.pax`
## (`cUI_Character::executeAction`, the fread/fwrite loop at 0x853FA45) -- so a
## template IS a savegame and reading it with Sacred.Pax is the correct thing,
## not a convenient one.
##
## $SACRED_CHARS is still honoured when set, as an EXTRA corpus.
##
## WHAT IT PINS. Every section must inflate to exactly its declared size
## (Sacred.Pax push_error()s otherwise), and the eight characters must be the
## eight retail classes -- distinct CharacterTypes, all level 1, all with the
## same purse, each with exactly two skills.
const EXPECT := 8
const START_LEVEL := 1
const START_GOLD := 5000
const START_SKILLS := 2
## CharacterType is a ONE-BASED index into the class-name list, and this table
## is the binary's own (`GetTypeName`, sub_815B3A2, over the 5624x68 record
## table at 0x8735AC0). It agrees entry-for-entry with global.res slot N-1,
## which is a second and independent route to the same map.
##
## 7 IS ABSENT ON PURPOSE. The table's entry 7 is `TYPE_NPC_VAMPN_DO_NOT_USE`
## and sub_8265BF6 opens with `if (charType == 7) charType = 6;`, so no
## template can carry it.
const TYPE_TREE := {
	1: "type_npc_seraphim", 2: "type_npc_gladiator", 3: "type_npc_magician",
	4: "type_npc_darkelve", 5: "type_npc_elve", 6: "type_npc_vampirelady",
	8: "type_npc_zwerg", 9: "type_npc_daemonin",
}
## Skill ids from research/formats/generated/skill-families.tsv.
const SK_WEAPON_LORE := 2
const SK_AGILITY := 8
const SK_VAMPIRISM := 20


func _init() -> void:
	super()
	var install := Sacred.find_install()
	var res := Sacred.Resources.new(install.path_join("scripts/us/global.res"))
	var seen_type := {}
	var rows := PackedStringArray()
	var heroes := {}
	for i in EXPECT:
		var path := install.path_join("templates/hero%02d.ptx" % i)
		var pax = Sacred.Pax.new(path)
		assert(pax.is_open(), "templates/hero%02d.ptx did not open" % i)
		var total := 0
		for t in pax.types:
			var b: PackedByteArray = pax.section(t)
			# A section that fails to inflate comes back empty; a real one never
			# is. This is the framing assertion the old gate made by printing.
			assert(b.size() > 0, "hero%02d section 0x%X decoded to nothing" % [i, t])
			total += b.size()

		var h = Sacred.Hero.new(path)
		assert(h.found, "hero%02d.ptx has no readable character stream" % i)
		assert(not seen_type.has(h.character_type),
			"CharacterType %d appears twice -- the templates are not one per class" % h.character_type)
		seen_type[h.character_type] = i
		heroes[h.character_type] = h
		assert(TYPE_TREE.has(h.character_type),
			"CharacterType %d is not one of the eight retail classes" % h.character_type)
		# The one-based slot must name the class. This ties the PAX field to
		# global.res without either being assumed.
		var cname := res.slot(h.class_slot())
		assert(cname != "", "CharacterType %d names no class" % h.character_type)

		assert(h.level == START_LEVEL, "%s starts at level %d" % [cname, h.level])
		assert(h.gold == START_GOLD, "%s starts with %d gold" % [cname, h.gold])
		assert(h.experience == 0, "%s starts with experience" % cname)
		assert(h.skills().size() == START_SKILLS,
			"%s starts with %d skills, expected %d" % [cname, h.skills().size(), START_SKILLS])
		for s in h.skills():
			assert(int(s["level"]) == 1, "%s starts a skill above level 1" % cname)
		assert(h.attributes().size() == Sacred.Hero.ATTRS, "%s has no attributes" % cname)
		# The second copy is byte-identical in every template. If that ever
		# stops being true the two are genuinely different fields and the
		# reader must say which is which.
		assert(h.attributes() == h.attributes_second(),
			"%s's two attribute copies disagree -- they are not the same field" % cname)
		assert(h.items().size() > 0, "%s starts with no items" % cname)
		rows.append("hero%02d\ttype=%d\t%s\tlvl=%d\tgold=%d\tattrs=%s\tskills=%s\titems=%d\tbytes=%d" % [
			i, h.character_type, cname, h.level, h.gold, h.attributes(),
			h.skills(), h.items().size(), total])

	assert(seen_type.size() == EXPECT,
		"%d distinct CharacterTypes, expected %d" % [seen_type.size(), EXPECT])

	# THE CORROBORATION, and it is what makes the class table a reading rather
	# than an ordering that happens to fit. Each of these is a fact about the
	# CHARACTER that must agree with the NAME the slot gives it, and they were
	# established before the binary's own table was read.
	var vamp = heroes[6]
	assert(vamp.skill_level(SK_VAMPIRISM) == 1,
		"the Vampiress does not have the Vampirism skill -- the class map is wrong")
	for t in TYPE_TREE:
		if t != 6:
			assert(heroes[t].skill_level(SK_VAMPIRISM) == 0,
				"class %d also has Vampirism, so it does not identify the Vampiress" % t)
	# The Gladiator is the strongest and has no magic at all.
	var glad = heroes[2]
	assert(glad.attribute("REMAG") == 0, "the Gladiator has magic regeneration")
	for t in TYPE_TREE:
		assert(heroes[t].attribute("STK") <= glad.attribute("STK") or t == 9,
			"class %d is stronger than the Gladiator" % t)
	# The Wood Elf is the most agile, and carries the Agility skill.
	var elve = heroes[5]
	assert(elve.skill_level(SK_AGILITY) == 1, "the Wood Elf lacks the Agility skill")
	for t in TYPE_TREE:
		assert(heroes[t].attribute("GES") <= elve.attribute("GES"),
			"class %d is more agile than the Wood Elf" % t)
	# The Battle Mage has the most magic regeneration.
	var mage = heroes[3]
	for t in TYPE_TREE:
		assert(heroes[t].attribute("REMAG") <= mage.attribute("REMAG"),
			"class %d out-regenerates the Battle Mage" % t)
	# Weapon Lore is the near-universal starting skill; only the Battle Mage
	# lacks it. A control on the skill reader: if every class scored the same
	# this would prove nothing.
	var with_wl := 0
	for t in TYPE_TREE:
		if heroes[t].skill_level(SK_WEAPON_LORE) == 1:
			with_wl += 1
	assert(with_wl == EXPECT - 1,
		"%d of %d classes start with Weapon Lore, expected all but the Battle Mage" % [
			with_wl, EXPECT])

	for r in rows:
		print(r)

	# The optional extra corpus, if the caller has one. Never a failure.
	var extra := 0
	var dir := OS.get_environment("SACRED_CHARS")
	if dir != "":
		for i in EXPECT:
			var p := "%s/Hero%02d.pax" % [dir, i]
			if not FileAccess.file_exists(p):
				continue
			var px = Sacred.Pax.new(p)
			if px.is_open():
				for t in px.types:
					assert(px.section(t).size() > 0,
						"$SACRED_CHARS Hero%02d section 0x%X decoded to nothing" % [i, t])
				extra += 1

	print("pax_check\tOK\ttemplates=%d\ttypes=%s\tseraphim=type1\textra_corpus=%d" % [
		EXPECT, seen_type.keys(), extra])
	finish(0)
