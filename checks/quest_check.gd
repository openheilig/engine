extends "res://checks/check.gd"
## quest_check.gd -- the ONE runnable check for Sacred.Vectoren, ScriptVM and
## QuestLog: does a REAL quest's own bytecode run, and does the interpreter
## refuse what it cannot honestly execute?
##
##   godot --headless --path godot-port --script checks/quest_check.gd
##
## THE QUEST IS NOT SYNTHETIC. 74, "Kampf gegen den Dämon", is one of the 602
## in the Seraphim tree, and it was chosen by MEASUREMENT rather than taste:
## over all of them, counting how many opcodes each quest needs beyond a
## state-and-log core, 74 needs exactly one. Its hooks are 178 bytes and use
## four opcodes -- SetQuestInfo, QuestBook, SetVarBit, AutoSave.
##
## WHAT THE CONTROL IS. "The quest ran" proves little on its own: an
## interpreter that silently skipped every record it did not know would report
## the same success. So the refusal arm is asserted too -- a hook using an
## unimplemented opcode must come back false with NOTHING executed, and the
## corpus supplies plenty of those. If ScriptVM ever starts skipping instead of
## refusing, the second half of this check fails while the first still passes.
##
## THE BASE-4 ASSERTION is the other load-bearing one. Section-1 indices count
## the zero sentinel, so a hook resolves to `QIS_Trigger<id>`; at base 88 it
## lands one record early on `SelfTriggerQuest<id>` every time. Checked over
## the whole table rather than on one quest.
const TREE := "bin/type_npc_seraphim"
const QUEST := 74
const TITLE := "Kampf gegen den Dämon"
const WANT_PROCS := 23494
const WANT_QUESTS := 601
## OnEnter is 125 bytes and 4 records; OnExit is 53 and 3.
const WANT_ENTER_RECORDS := 4
const WANT_EXIT_RECORDS := 3
const WANT_BOOK_LINES := 4          ## 3 written on entry, 1 on exit
## ALL FOUR resolve, in English. This was pinned at 0 -- "the keys appear in
## funkcode.bin and in no other file in the install" -- and that was an artefact
## of a 64-bit name hash where retail's wraps at int32 (row 954). The quest is
## "The Soul of the Demon"; its objective is "Kill the demon, after Shareefa
## has summoned it."
const WANT_RESOLVED := 4


func _init() -> void:
	super()
	var install := Sacred.find_install()
	assert(install != "", "no retail install found; pass --install=/path/to/install")
	var dir := install.path_join(TREE)
	var vec := Sacred.Vectoren.new(dir)
	assert(vec.found, "vectoren.bin did not decode")
	assert(vec.procs == WANT_PROCS, "procedure count moved: want %d, got %d" % [WANT_PROCS, vec.procs])
	assert(vec.quests == WANT_QUESTS, "quest count moved: want %d, got %d" % [WANT_QUESTS, vec.quests])

	_base_four(vec)
	var code := FileAccess.get_file_as_bytes(dir.path_join("funkcode.bin"))
	assert(code.size() > 0, "funkcode.bin is unreadable")
	var log := _run(vec, code)
	_refusal(vec, code)
	_resolution(install, log)

	_state_machine(vec, code)
	_start_quest(vec, code)

	print("quest_check OK quest=%d title=%s lines=%d state=%d autosaves=%d resolved=%d/%d" % [
		QUEST, vec.title_of(QUEST), log.lines.size(), log.state_of(QUEST),
		log.autosaves, WANT_RESOLVED, log.lines.size()])
	finish(0)


## Quest 1's OnEnter -- the hook a NEW GAME runs, and the one that puts the
## novice nun beside the Seraphim at the start (rows 1105/1106). It is here
## rather than in a check of its own because it exercises the same three
## classes this file already covers, plus QuestCast.
##
## WHAT MAKES IT WORTH ASSERTING. The hook's CreateNPC carries NO POSITION --
## it names a handle, and an NPC_Goto two records later gives that handle a
## cell. A reader that expected a cell on the create record would build nothing
## and report success, which is exactly the failure this asserts against: the
## cell is checked, not merely the count.
func _start_quest(vec, code: PackedByteArray) -> void:
	const Q := 1
	const WANT_RECORDS := 10
	const WANT_CREATURE := 679            ## NOVIZIN02.GRN
	const WANT_CELL := Vector2i(3237, 2514)
	const WANT_HANDLE := "res:17095"
	expect(vec.title_of(Q) == "Tutorial",
		"quest %d is titled '%s', not 'Tutorial'" % [Q, vec.title_of(Q)])
	var h: Dictionary = vec.hook(Q, Sacred.Vectoren.H_ON_ENTER)
	expect(not h.is_empty(), "quest %d has no OnEnter hook" % Q)
	var vm := ScriptVM.new()
	var cast := QuestCast.new()
	expect(vm.run(code, h["offset"], h["length"], cast),
		"quest %d OnEnter refused opcode %d" % [Q, vm.refused_op])
	expect(vm.executed == WANT_RECORDS,
		"quest %d OnEnter ran %d records, expected %d" % [Q, vm.executed, WANT_RECORDS])
	expect(cast.lines.size() == 4,
		"quest %d wrote %d book lines, expected 4" % [Q, cast.lines.size()])
	# SetVar is not SetVarBit: both names must appear with their whole values,
	# and neither may have gone into the bit array.
	expect(cast.script_vars.get("PoolDLG", -1) == 0 and cast.script_vars.get("atmos10", -1) == 1,
		"SetVar did not record PoolDLG=0 and atmos10=1: %s" % [cast.script_vars])

	expect(cast.cast.size() == 1, "quest %d created %d NPCs, expected 1" % [Q, cast.cast.size()])
	var e: Dictionary = cast.cast[0]
	expect(str(e["handle"]) == WANT_HANDLE,
		"the created NPC's handle is '%s', expected '%s'" % [e["handle"], WANT_HANDLE])
	expect(int(e["creature"]) == WANT_CREATURE,
		"the created NPC is creature %d, expected %d" % [int(e["creature"]), WANT_CREATURE])
	expect(str(e["name"]) == "novizin1", "the created NPC is named '%s'" % e["name"])
	# THE LOAD-BEARING ONE. The cell comes from a different record than the
	# create, matched by handle across a case change (`res:` then `Res:`).
	expect(e["cell"] == WANT_CELL,
		"the NPC stands at %s, expected %s -- NPC_Goto did not reach her" % [e["cell"], WANT_CELL])
	expect(bool(e["compass"]), "QuestKompassObj did not mark the NPC")
	expect(cast.placed().size() == 1, "placed() returned %d entries" % cast.placed().size())

	# THE CONTROL, and it must stay a REAL quest rather than a synthetic span:
	# quest 9 sits next to quest 1 in the same tree and uses Teleport, SetIcon,
	# SetAnimMode and PlaySound, none of which is implemented. If widening the
	# opcode set ever starts skipping instead of refusing, this fails while
	# everything above still passes.
	var vm9 := ScriptVM.new()
	var c9 := QuestCast.new()
	var h9: Dictionary = vec.hook(9, Sacred.Vectoren.H_ON_ENTER)
	expect(not vm9.run(code, h9["offset"], h9["length"], c9),
		"quest 9's OnEnter ran despite using unimplemented opcodes")
	expect(vm9.executed == 0, "a refused hook executed %d records" % vm9.executed)
	expect(c9.cast.is_empty(), "a refused hook created %d NPCs" % c9.cast.size())

	# AND THE HOST ARM. A plain QuestLog cannot answer CreateNPC, so quest 1
	# must refuse against it rather than run four records and crash on the
	# fifth -- the reason ScriptVM checks HOST_METHOD before executing.
	var vmp := ScriptVM.new()
	var plain := QuestLog.new()
	expect(not vmp.run(code, h["offset"], h["length"], plain),
		"quest %d ran against a host that cannot receive its NPC" % Q)
	expect(plain.lines.is_empty(),
		"a hook refused for host narrowness still wrote %d book lines" % plain.lines.size())


## Section-1 indices are based at 4. Over every quest that declares a Trigger,
## the symbol must be exactly `QIS_Trigger<id>`.
func _base_four(vec) -> void:
	var ok := 0
	var tried := 0
	for qid in vec.quest_ids():
		var sym: String = vec.hook_symbol(qid, Sacred.Vectoren.H_TRIGGER)
		if sym == "":
			continue
		tried += 1
		if sym == "QIS_Trigger%d" % qid:
			ok += 1
	expect(tried > 200, "only %d quests declare a Trigger -- too few to check the index base" % tried)
	expect(ok == tried,
		"%d of %d Trigger hooks do not resolve to QIS_Trigger<id> -- the section-1 index base is wrong"
			% [tried - ok, tried])


## The quest runs, end to end, out of its own bytes.
func _run(vec, code: PackedByteArray) -> QuestLog:
	if not expect(vec.has_quest(QUEST), "quest %d is not in this tree" % QUEST):
		return QuestLog.new()
	expect(vec.title_of(QUEST) == TITLE,
		"quest %d is titled '%s', expected '%s'" % [QUEST, vec.title_of(QUEST), TITLE])
	var vm := ScriptVM.new()
	var log := QuestLog.new()

	# A Trigger that is DECLARED AND EMPTY is not a missing hook. Every Trigger
	# in the corpus is zero bytes, so running one must succeed vacuously -- if
	# this ever returned false the quest could never be entered.
	var trg: Dictionary = vec.hook(QUEST, Sacred.Vectoren.H_TRIGGER)
	expect(not trg.is_empty(), "quest %d declares no Trigger" % QUEST)
	expect(int(trg["length"]) == 0, "the Trigger is %d bytes, expected 0" % int(trg["length"]))
	expect(vm.run(code, int(trg["offset"]), 0, log), "an empty Trigger did not run vacuously")

	var enter: Dictionary = vec.hook(QUEST, Sacred.Vectoren.H_ON_ENTER)
	expect(vm.opcodes(code, enter["offset"], enter["length"]).size() == WANT_ENTER_RECORDS,
		"OnEnter is %d records, expected %d" % [
			vm.opcodes(code, enter["offset"], enter["length"]).size(), WANT_ENTER_RECORDS])
	expect(vm.run(code, enter["offset"], enter["length"], log),
		"OnEnter refused opcode %d" % vm.refused_op)
	log.mark_entered(QUEST)
	# QUEST 74's OnEnter WRITES NO STATE VARIABLE. The first version of this
	# check asserted state 1 here and failed -- correctly, because only OnExit
	# writes one. Quest 65 does write 1 on entry, so the corpus is not even
	# self-consistent, which is exactly why "has it started" is the port's own
	# flag and not a reading of the file.
	expect(log.state_of(QUEST) == 0,
		"quest %d's OnEnter now writes state %d -- it wrote none when this was measured"
			% [QUEST, log.state_of(QUEST)])
	expect(log.is_running(QUEST), "the quest is not running after OnEnter")
	expect(log.lines.size() == 3, "OnEnter wrote %d quest-book lines, expected 3" % log.lines.size())
	# The heading is distinguishable from the body lines, which is the whole
	# point of QuestBook's second argument.
	expect(int(log.lines[0]["kind"]) == ScriptVM.BOOK_TITLE,
		"the first quest-book line is not the title")
	expect(int(log.lines[1]["kind"]) != ScriptVM.BOOK_TITLE,
		"the second quest-book line is also a title")

	var exit: Dictionary = vec.hook(QUEST, Sacred.Vectoren.H_ON_EXIT)
	expect(vm.opcodes(code, exit["offset"], exit["length"]).size() == WANT_EXIT_RECORDS,
		"OnExit is %d records, expected %d" % [
			vm.opcodes(code, exit["offset"], exit["length"]).size(), WANT_EXIT_RECORDS])
	expect(vm.run(code, exit["offset"], exit["length"], log), "OnExit refused opcode %d" % vm.refused_op)
	expect(log.is_done(QUEST),
		"after OnExit the quest state is %d, expected %d" % [log.state_of(QUEST), QuestLog.STATE_DONE])
	expect(log.lines.size() == WANT_BOOK_LINES,
		"the finished quest has %d book lines, expected %d" % [log.lines.size(), WANT_BOOK_LINES])
	expect(log.autosaves == 1, "OnExit requested %d autosaves, expected 1" % log.autosaves)
	expect(not log.is_running(QUEST), "the quest is still running after OnExit")
	# Every line carries the quest's OWN id, which the records state rather
	# than the hook implying. A reader that assumed it would pass regardless.
	for l in log.lines:
		expect(int(l["quest"]) == QUEST,
			"a quest-book line is filed under quest %d, not %d" % [int(l["quest"]), QUEST])
	return log


## THE REFUSAL ARM. A hook using an opcode ScriptVM does not implement must
## come back false having executed nothing. Without this, an interpreter that
## silently skipped unknown records would pass everything above.
func _refusal(vec, code: PackedByteArray) -> void:
	var vm := ScriptVM.new()
	var log := QuestLog.new()
	var refused := 0
	var runnable := 0
	for qid in vec.quest_ids():
		var h: Dictionary = vec.hook(qid, Sacred.Vectoren.H_ON_ENTER)
		if h.is_empty() or int(h["length"]) == 0:
			continue
		if vm.can_run(code, h["offset"], h["length"]):
			runnable += 1
		else:
			refused += 1
			var before := vm.executed
			expect(not vm.run(code, h["offset"], h["length"], log),
				"quest %d's OnEnter ran despite using an unimplemented opcode" % qid)
			expect(vm.executed == before,
				"a refused hook still executed %d records -- refusal must be all-or-nothing"
					% [vm.executed - before])
	expect(refused > 400,
		"only %d OnEnter hooks are refused -- the interpreter is accepting more than it implements" % refused)
	expect(runnable > 0, "no OnEnter hook is runnable at all")
	expect(log.lines.is_empty(), "refused hooks wrote %d quest-book lines" % log.lines.size())


## The log text, which now resolves in English.
func _resolution(install: String, log: QuestLog) -> void:
	var res := Sacred.Resources.new(install.path_join("scripts/us/global.res"))
	expect(res.count() > 0, "global.res did not load")
	var got := log.resolve_with(res)
	expect(got == WANT_RESOLVED,
		"%d of %d quest-book keys resolved, expected %d -- if an install carries them, raise WANT_RESOLVED deliberately"
			% [got, log.lines.size(), WANT_RESOLVED])


## THE STATE TRANSITION, on the quest that actually carries one. 65
## ("Trockenlegung durch Zwergenstaudamm") writes SetVarBit("65", 1) on entry
## and SetVarBit("65", 3) on exit, so it -- not 74 -- is where 1 and 3 are
## observed rather than assumed. Both quests are run because neither alone
## exercises the whole shape: 74 has the quest book, 65 has the state.
func _state_machine(vec, code: PackedByteArray) -> void:
	const Q := 65
	expect(vec.has_quest(Q), "quest %d is not in this tree" % Q)
	var vm := ScriptVM.new()
	var log := QuestLog.new()
	var enter: Dictionary = vec.hook(Q, Sacred.Vectoren.H_ON_ENTER)
	var exit: Dictionary = vec.hook(Q, Sacred.Vectoren.H_ON_EXIT)
	expect(vm.run(code, enter["offset"], enter["length"], log),
		"quest %d OnEnter refused opcode %d" % [Q, vm.refused_op])
	# STATE IS A MASK, not a scalar: SetVarBit's second argument is a bit index
	# (measured -- Teleporter_WP takes 0..12, one bit per waypoint), so entry
	# sets bit 1 and the variable reads 2.
	expect(log.state_of(Q) == 1 << QuestLog.STATE_ACTIVE,
		"quest %d is state %d after OnEnter, expected %d" % [
			Q, log.state_of(Q), 1 << QuestLog.STATE_ACTIVE])
	expect(log.is_active(Q), "quest %d does not read as active after OnEnter" % Q)
	expect(vm.run(code, exit["offset"], exit["length"], log),
		"quest %d OnExit refused opcode %d" % [Q, vm.refused_op])
	# BOTH bits, and that is the point of the mask: a finished quest was also
	# once active. Assignment would have discarded that and read 8.
	expect(log.state_of(Q) == (1 << QuestLog.STATE_ACTIVE) | (1 << QuestLog.STATE_DONE),
		"quest %d is state %d after OnExit, expected %d" % [
			Q, log.state_of(Q),
			(1 << QuestLog.STATE_ACTIVE) | (1 << QuestLog.STATE_DONE)])
	expect(log.is_done(Q) and log.is_active(Q),
		"quest %d lost its active bit when it finished" % Q)
	# The variable is keyed by the quest id AS A DECIMAL STRING, which is how
	# the record spells it. A reader that keyed by int would pass every
	# assertion above and fail this one.
	expect(log.vars().has(str(Q)), "quest %d's state variable is not named '%d'" % [Q, Q])
