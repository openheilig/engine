extends RefCounted
## bin/TYPE_NPC_*/vectoren.bin -- funkcode.bin's SYMBOL TABLE and the QUEST
## TABLE (autoresearch rows 936, 937; research/formats/script-bytecode.md).
##
## Three sections, of which this class reads the first two:
##
##   SECTION 1  procedure table, `u32 count` then count x 84 B
##     +0x00 char name[64]      +0x40 i32 offset into funkcode.bin
##     +0x44 i32 length         +0x48 i32 quest id, -1 = none
##   SECTION 2  quest table, at 4 + count*84; `u32 count` then count x 292 B
##     +0x000 u32 quest id      +0x004 char title[256]   German
##     +0x104, +0x108 u32 enums, unidentified
##     +0x10c..+0x11c  five section-1 INDICES: Trigger, OnEnter, OnSetUp,
##                     OnExit, OnLose. 0 means absent.
##
## SECTION-1 INDICES ARE BASED AT OFFSET 4, COUNTING THE ZERO SENTINEL, and
## this is the one thing to get right. Resolving each quest's Trigger index and
## asking whether the symbol is literally `QIS_Trigger<that id>` gives 285/285
## at base 4 and 0/285 at base 88, where it lands one record early on
## `SelfTriggerQuest<id>` every time. `Sacred.Funk` uses 88 for its own lookups
## and that is NOT a bug -- it looks symbols up by funkcode OFFSET, and 88
## simply skips a zero-length record that cannot contribute. An INDEX must use
## base 4, which is what this class does and what hook_symbol() checks.
##
## Section 3 (the dynamic-quest region table) is not read: its content is
## `ToDo:-1.<slot>` placeholder in every base tree, so whether that system
## shipped functional is unresolved and nothing here should pretend otherwise.

const REC1 := 84
const REC2 := 292
const NAME1 := 64
const TITLE := 256
const HOOKS := 5
const HOOK_NAMES: Array[String] = ["Trigger", "OnEnter", "OnSetUp", "OnExit", "OnLose"]
const H_TRIGGER := 0
const H_ON_ENTER := 1
const H_ON_SETUP := 2
const H_ON_EXIT := 3
const H_ON_LOSE := 4

var found := false
var procs := 0           ## section-1 records, sentinel included
var quests := 0          ## section-2 records

## section-1 index -> {name, offset, length, quest}
var _proc: Array[Dictionary] = []
## quest id -> {title, hooks PackedInt32Array}
var _quest: Dictionary[int, Dictionary] = {}
var _order := PackedInt32Array()


func _init(dir: String) -> void:
	var b := FileAccess.get_file_as_bytes(dir.path_join("vectoren.bin"))
	if b.size() < 4:
		push_warning("Vectoren: no vectoren.bin under %s" % dir)
		return
	var n1 := b.decode_u32(0)
	var base2 := 4 + n1 * REC1
	if n1 <= 0 or base2 + 4 > b.size():
		push_warning("Vectoren: section 1 declares %d procedures, which does not fit" % n1)
		return
	for i in n1:
		var o := 4 + i * REC1
		_proc.append({
			"name": b.slice(o, o + NAME1).get_string_from_ascii(),
			"offset": b.decode_s32(o + 0x40),
			"length": b.decode_s32(o + 0x44),
			"quest": b.decode_s32(o + 0x48),
		})
	procs = _proc.size()
	var n2 := b.decode_u32(base2)
	if base2 + 4 + n2 * REC2 > b.size():
		push_warning("Vectoren: section 2 declares %d quests, which does not fit" % n2)
		return
	for i in n2:
		var o := base2 + 4 + i * REC2
		var qid := b.decode_u32(o)
		var hooks := PackedInt32Array()
		for k in HOOKS:
			hooks.append(b.decode_s32(o + 0x10c + k * 4))
		# Quest 0 is the same shape of empty record section 1 opens with: no
		# title and no hooks. Skipped by CONTENT rather than by index.
		if qid == 0 and b[o + 4] == 0:
			continue
		_quest[qid] = {
			"title": b.slice(o + 4, o + 4 + TITLE).get_string_from_ascii(),
			"hooks": hooks,
		}
		_order.append(qid)
	quests = _quest.size()
	found = quests > 0 and procs > 0


## Every quest id carrying data, in file order.
func quest_ids() -> PackedInt32Array:
	return _order


func has_quest(qid: int) -> bool:
	return _quest.has(qid)


## The quest-log title, as retail compiled it: German, from the file.
func title_of(qid: int) -> String:
	return _quest[qid]["title"] if _quest.has(qid) else ""


## One hook's funkcode span as {offset, length, name}, or an empty Dictionary
## when the quest has no such hook. `hook` is one of the H_* constants.
func hook(qid: int, h: int) -> Dictionary:
	if not _quest.has(qid) or h < 0 or h >= HOOKS:
		return {}
	var idx: int = (_quest[qid]["hooks"] as PackedInt32Array)[h]
	if idx <= 0 or idx >= _proc.size():
		return {}
	var p := _proc[idx]
	# A zero-length hook is not missing -- every Trigger in the corpus is zero
	# bytes -- so it is returned with its name and an empty span, and the
	# caller decides. Reporting it as absent would erase the distinction
	# between "declared but empty" and "not declared".
	return {"offset": p["offset"], "length": p["length"], "name": p["name"]}


## The symbol a hook resolves to. This is the base-4 check from the class doc,
## exposed so a gate can run it over the whole table rather than trusting the
## constant.
func hook_symbol(qid: int, h: int) -> String:
	var k := hook(qid, h)
	return k.get("name", "")


## A section-1 procedure by index, for a caller walking CallFunktion targets.
func proc_at(index: int) -> Dictionary:
	return _proc[index] if index >= 0 and index < _proc.size() else {}
