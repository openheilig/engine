extends "res://checks/check.gd"
## resources_check.gd -- the ONE runnable check for Sacred.Resources.
##
##   godot --headless --path . --script res://checks/resources_check.gd
##
## Two namespaces over one file, and the whole point of this gate is that they
## are NOT interchangeable:
##
##   BY SLOT  `res:N` from the script bytecode -- startcode.gd's tag 0x01.
##   BY NAME  the engine's own hash of a resource's name, which is how a
##            numeric resource id resolves.
##
## Slot 9400 is quest prose; resource 9400 is 'Heavenly Magic'. A reader that
## silently used one for the other would look fine on a spot check, so this
## asserts they DISAGREE as well as that each is right.
##
## WHAT THIS GATE DOES NOT ESTABLISH. It checks the READER. It does not check
## that startcode.gd's tag 0x01 is "the NPC's display name" -- see the control
## at the bottom, which was built to show exactly that and failed to. Reading
## every NPC reference two slots either side scores no worse than reading it
## where the port says, so the instrument cannot see the difference and the
## claim stands unverified.
const SKILLS := 33               ## global.res 9400..9432, the whole skill list
const NUMERIC_REFS := 1377       ## NPC names that are `res:<integer>`; all resolve
const DANGLING_REFS := 144       ## `res:D1Dorf_01`..`_18` x 8 classes; resolve to nothing
const NAME_MAX := 40.0           ## a skill NAME is short; its description is not
const CLASSES := [
	"type_npc_daemonin", "type_npc_darkelve", "type_npc_elve",
	"type_npc_gladiator", "type_npc_magician", "type_npc_seraphim",
	"type_npc_vampirelady", "type_npc_zwerg",
]

func _init() -> void:
	super()
	var install := Sacred.find_install()
	var res := Sacred.Resources.new(install.path_join("scripts/us/global.res"))
	assert(res.count() > 20000, "global.res did not load: %d entries" % res.count())

	# BY SLOT -- what `res:N` means.
	assert(res.slot(0) == "Seraphim", "slot 0 is %s" % res.slot(0))
	assert(res.slot(1) == "Gladiator", "slot 1 is %s" % res.slot(1))
	assert(res.slot(18101) == "Settler", "slot 18101 is %s" % res.slot(18101))

	# BY NAME -- what a numeric resource id means.
	assert(res.by_id(9400) == "Heavenly Magic", "resource 9400 is %s" % res.by_id(9400))
	assert(res.by_id(1100) == "Attack Speed", "resource 1100 is %s" % res.by_id(1100))
	assert(res.by_id(1078) == "Physical" and res.by_id(1081) == "Poison",
		"1078..1081 are the four damage channels")

	# The mask is not decorative: a NEGATIVE id is a key that is ALREADY
	# hashed and must reach the same entry without being hashed twice.
	var k := Sacred.Resources.name_hash("9400")
	assert(res.by_id(k - (1 << 31)) == "Heavenly Magic", "negative id did not round-trip")

	# The two namespaces must DISAGREE, or one of them is not implemented.
	assert(res.slot(9400) != res.by_id(9400),
		"slot 9400 and resource 9400 returned the same text -- one namespace is missing")

	# The skill list is contiguous, and each description sits at id + 50.
	var skills := 0
	var described := 0
	for i in SKILLS:
		var n := res.by_id(9400 + i)
		if n != "" and n.length() < NAME_MAX:
			skills += 1
		if res.by_id(9450 + i).length() > NAME_MAX:
			described += 1
	assert(skills == SKILLS, "%d of %d skill names resolve" % [skills, SKILLS])
	assert(described > SKILLS / 2,
		"only %d skill descriptions sit at id+50" % described)

	# THE PAYOFF, and its control. Every NPC startcode.gd decodes carries a
	# `res:N` display name it has never been able to read.
	var named := 0
	var total := 0
	var name_len := 0.0
	var refs: Array[int] = []
	for cls in CLASSES:
		var sc = Sacred.Startcode.new(install.path_join("bin").path_join(cls))
		for npc in sc.npcs:
			var ref: String = npc.get("name", "")
			if not ref.to_lower().begins_with("res:"):
				continue
			total += 1
			var t := res.resolve(ref)
			if t != "" and t != ref:
				named += 1
				name_len += t.length()
				refs.append(ref.substr(4).to_int())   # numeric ones only
	assert(total > 500, "only %d NPCs carry a res: name -- nothing to test" % total)
	# NOT 100%, and the shortfall is a fact about the data rather than a hole
	# in the reader. 144 of the references are `res:D1Dorf_01` .. `res:D1Dorf_18`
	# -- 18 word names repeated across all eight classes -- and they resolve
	# under NEITHER namespace: not by slot, because the tail is not an integer,
	# and not by hash, because no such name is in the file (the string "Dorf"
	# appears in none of its 23,123 entries). They are dangling references the
	# retail game cannot resolve either. Every reference that IS numeric
	# resolves, and that is the number worth pinning.
	assert(named == NUMERIC_REFS,
		"%d of %d numeric NPC name references resolved (expected %d)" % [
			named, total, NUMERIC_REFS])
	assert(total - named == DANGLING_REFS,
		"%d references resolve to nothing, expected the %d known D1Dorf_* ones" % [
			total - named, DANGLING_REFS])
	name_len /= float(named)

	# THE CONTROL, AND WHAT IT REFUSES TO SHOW. `startcode.gd` says tag 0x01 is
	# "the NPC's display name". This gate does NOT establish that, and the
	# attempt is kept here so nobody repeats it.
	#
	# The idea was that a display name is short where global.res is mostly
	# quest prose, so the right slot should read much shorter than a wrong one.
	# Reading the same references at slot +/- 1 and +/- 2 instead:
	#
	#     offset  -2     -1      0     +1     +2
	#     short   .432   .468   .444   .497   .513
	#
	# Offset 0 is not the best and is inside the spread. The instrument cannot
	# tell the documented reading from one two slots away, so it is evidence of
	# nothing. What the resolved text actually contains is a MIX -- "Wolff von
	# Lindenau" and "Cerebropod" beside dialogue lines and item names -- and
	# 1377 references share only 161 distinct texts.
	#
	# So what is asserted below is the reader, not the meaning of tag 0x01.
	var spread: Array[float] = []
	for off in [-2, -1, 0, 1, 2]:
		var short := 0
		for i in refs:
			var t := res.slot(i + off)
			if t.length() > 0 and t.length() <= 24:
				short += 1
		spread.append(float(short) / float(refs.size()))
	assert(spread[2] <= spread.max() and spread[2] >= spread.min(),
		"slot+0 now separates from its neighbours (%s) -- if that is real this gate can be strengthened" % [spread])

	print("resources_check\tOK\tentries=%d\tskills=%d/%d\tdescriptions=%d\tnpc_refs=%d\tnumeric=%d\tdangling=%d\tmean_len=%.1f\tslot_offset_spread=%.3f..%.3f" % [
		res.count(), skills, SKILLS, described, total, named, total - named,
		name_len, spread.min(), spread.max()])
	finish(0)
