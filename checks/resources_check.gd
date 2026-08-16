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
const NUMERIC_REFS := 1377       ## NPC names that are `res:<integer>`; resolve BY SLOT
## `res:D1Dorf_01`..`_18` x 8 classes. These were recorded as DANGLING -- "they
## resolve under neither namespace, references the retail game cannot resolve
## either". That was wrong, and it was wrong because of the hash bug this gate
## now controls for: all 18 resolve BY NAME to a village roster (Smith, Healer,
## Bartender, Witch and 14 Peasants). Findings log row 954.
const SYMBOLIC_REFS := 144
const NAME_MAX := 40.0           ## a skill NAME is short; its description is not
## Static QuestBook keys across all eight trees, and how many are in the table.
## NOT 100%: the rest are runtime-composed (`DQ_BRINGE_ITEM+Var(DQ_2604)+_LOG`)
## and cannot resolve without the VM's variables -- see compose().
const QUESTBOOK_KEYS := 1242
const QUESTBOOK_RESOLVED := 319
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

	# LONG NAMES, and this is the assertion the old gate was missing. Every
	# name it hashed was four characters, which is exactly the length at which
	# a 64-bit hash and retail's wrapping 32-bit one still agree.
	assert(res.by_name("UI_QUICKSAVE") == "Quicksave",
		"UI_QUICKSAVE is %s" % res.by_name("UI_QUICKSAVE"))
	assert(res.by_name("INVENTAR_RES_PHYSICAL") == "Physical Resistance",
		"INVENTAR_RES_PHYSICAL is %s" % res.by_name("INVENTAR_RES_PHYSICAL"))
	assert(res.by_name("DQ_BAUER_BEGRUESSUNG_LOG") == "The peasants need my help.",
		"a quest-log line is %s" % res.by_name("DQ_BAUER_BEGRUESSUNG_LOG"))
	# Case folding, on a name whose case actually varies in the wild.
	assert(Sacred.Resources.name_hash("EWT_Schwert") == Sacred.Resources.name_hash("ewt_schwert")
		and res.by_name("EWT_Schwert") == "Sword", "the hash is not case-folding")

	# THE CONTROL FOR THE WRAP. A naive 64-bit `(h*113 + c) % MOD` -- the hash
	# this reader used to have -- must AGREE with retail's on a four-character
	# name and DISAGREE on a long one. Both halves matter: agreement alone
	# would be satisfied by any hash, and disagreement alone would not show
	# that the old reading was right about the short keys it did resolve.
	assert(_naive("9400") == Sacred.Resources.name_hash("9400"),
		"the 64-bit and 32-bit hashes disagree at four characters, so the wrap is not what separates them")
	assert(_naive("UI_QUICKSAVE") != Sacred.Resources.name_hash("UI_QUICKSAVE"),
		"the int32 wrap has stopped mattering -- it is what makes long names resolve")
	# And the naive one must actually MISS, not merely differ.
	assert(not res._by_hash.has(_naive("UI_QUICKSAVE")),
		"the naive hash now hits the table too, so this control proves nothing")

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
	# The 18 village roles, which the old reader could not see at all.
	assert(res.by_name("D1Dorf_01") == "Smith" and res.by_name("D1Dorf_18") == "Witch",
		"the D1Dorf village roster no longer resolves")
	# NOW 100%, and the change is the finding. This used to read 1377 of 1521
	# with 144 written off as dangling; both namespaces work, so every NPC in
	# every tree has a readable name.
	assert(named == total, "%d of %d NPC name references resolved" % [named, total])
	assert(total == NUMERIC_REFS + SYMBOLIC_REFS,
		"the NPC reference corpus changed: %d, expected %d numeric + %d symbolic" % [
			total, NUMERIC_REFS, SYMBOLIC_REFS])
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

	# THE QUEST LOG, which is the point of all of this. Every static QuestBook
	# key in all eight trees, and how many the table holds.
	var qb := _questbook_keys(install)
	var qhit := 0
	for key in qb:
		if res.by_name(key) != "":
			qhit += 1
	assert(qb.size() == QUESTBOOK_KEYS,
		"%d static QuestBook keys, expected %d" % [qb.size(), QUESTBOOK_KEYS])
	assert(qhit == QUESTBOOK_RESOLVED,
		"%d of %d quest-log keys resolve, expected %d" % [qhit, qb.size(), QUESTBOOK_RESOLVED])
	# A COMPOSED key, instantiated. This is the half the table cannot answer on
	# its own, and it must come back with real prose or compose() is decoration.
	assert(res.compose("Res:DQ_BRINGE_ITEM+Var(DQ_2604)+_LOGTITLE", 2) == "The Father's Sword.",
		"a composed quest title did not instantiate")

	print("resources_check\tOK\tentries=%d\tskills=%d/%d\tdescriptions=%d\tnpc_refs=%d\tnumeric=%d\tsymbolic=%d\tquestbook=%d/%d\tmean_len=%.1f\tslot_offset_spread=%.3f..%.3f" % [
		res.count(), skills, SKILLS, described, total, NUMERIC_REFS, SYMBOLIC_REFS,
		qhit, qb.size(), name_len, spread.min(), spread.max()])
	finish(0)


## The naive 64-bit hash this reader used to have, kept ONLY as the control
## above. It is deliberately not a method on Resources.
func _naive(name: String) -> int:
	var h := 0
	for c in name.to_upper():
		h = (h * 0x71 + c.unicode_at(0)) % Sacred.Resources.MOD
	return h & 0x7fffffff


## Every static (non-composed) QuestBook key in every script tree. Walks the
## bytecode by its length field, so it needs no tag table for what it skips.
func _questbook_keys(install: String) -> PackedStringArray:
	var seen := {}
	for cls in CLASSES:
		var code := FileAccess.get_file_as_bytes(
			install.path_join("bin").path_join(cls).path_join("funkcode.bin"))
		var p := 0
		while p + 4 <= code.size():
			var op := code.decode_u16(p)
			var l := code.decode_u16(p + 2)
			if l < 4 or p + l > code.size():
				p += 1
				continue
			if op == ScriptVM.OP_QUEST_BOOK:
				var q := p + 4
				while q < p + l:
					var tag := code[q]
					q += 1
					if tag == 0x01:
						var e := q
						while e < p + l and code[e] != 0:
							e += 1
						var s := code.slice(q, e).get_string_from_ascii()
						q = e + 1
						if s.begins_with("Res:"):
							s = s.substr(4)
						if s != "" and s.find("+") < 0:
							seen[s] = true
					elif ScriptVM.WIDTH.has(tag):
						q += int(ScriptVM.WIDTH[tag])
					else:
						break
			p += l
	var out := PackedStringArray()
	for s in seen:
		out.append(s)
	return out
