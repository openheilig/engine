class_name QuestLog
extends RefCounted
## Quest state and the player's quest book: the HOST a ScriptVM writes into.
##
## State is kept exactly as the bytecode keeps it -- a named variable per
## quest, written by `SetVarBit`. Quests 65 and 74 both write 1 on entry and 3
## on exit, and `questcode.bin` seeds its initial state the same way (a numeric
## quest id under tag 0x44, row from install-inventory). So this class does NOT
## invent an enum: STATE_ACTIVE and STATE_DONE are the file's own numbers,
## named here for readability and never used to reject an unfamiliar value.
##
## Nothing here touches the scene tree or a node (R10.1). It holds no reference
## to a Vectoren, a ScriptVM or an install path either -- the caller owns
## those, and this owns only what the player has actually done.

## BIT INDICES, not values -- see set_var(). Quests 65 and 74 both set bit 1 on
## entry and bit 3 on exit, and questcode.bin seeds its initial state the same
## way. This class does NOT invent an enum: these are the file's own numbers,
## named for readability and never used to reject an unfamiliar bit.
const STATE_ACTIVE := 1
const STATE_DONE := 3
## Retail's array is 160 bits per difficulty (sub_83A436C caps `bit` at 0x9F),
## and the whole of it is the 100-byte `0xCE` section of a .pax save -- five
## difficulties x 160 bits. A bit past the end is a decode error, not a
## variable, so it is refused rather than silently widening the mask.
const BITS := 160

## One quest-book line, in the order the bytecode wrote it.
##   quest  the id the record itself carries
##   kind   ScriptVM.BOOK_TITLE for the heading, 1 for a body line
##   key    the `Res:` key as written
##   text   what the key resolved to, or "" -- see resolve_with()
var lines: Array[Dictionary] = []

var autosaves := 0              ## AutoSave records executed
var last_quest_info := -1       ## SetQuestInfo's argument, unidentified

var _var: Dictionary[String, int] = {}
## Quests the caller has entered. THE PORT'S OWN BOOKKEEPING, not the file's,
## and separate from _var for that reason: quest 74's OnEnter writes no state
## variable at all -- only its OnExit does, with 3 -- so "has this quest been
## started" is not answerable from the bytecode alone. Quest 65 does write 1 on
## entry, so the two are not even consistent with each other across the corpus.
var _entered: Dictionary[int, bool] = {}
## Native quest-table completion, independent of script variables ("03" is
## NOT the same name as "3"). EndQuest never invents a SetVarBit write.
var completed: Dictionary[int, bool] = {}


# --- ScriptVM host interface -------------------------------------------------

func quest_book(quest: int, kind: int, key: String) -> void:
	lines.append({"quest": quest, "kind": kind, "key": key, "text": ""})


## SetVarBit's second argument is a BIT INDEX, not a value, so this ORs rather
## than assigns. Measured: `Teleporter_WP` is written 26 times with indices
## 0..12, one bit per waypoint, and assignment would keep only the last one.
## Retail agrees -- `sub_83A43C2(stats, difficulty, bit, 1)` sets a single bit
## in a 160-bit-per-difficulty array, and a variable whose name is not
## `HeroQBit` ORs into a mask at its script object's +0x20.
##
## A quest's state is therefore a MASK, not a scalar: quest 65 sets bit 1 on
## entry and bit 3 on exit, so a finished quest has both -- it was active AND
## it is done. That distinction is invisible under assignment.
func set_var(name: String, bit: int) -> void:
	if bit < 0 or bit >= BITS:
		push_warning("QuestLog: bit %d for %s is outside the %d-bit array" % [bit, name, BITS])
		return
	var key := _variable_key(name)
	_var[key if not key.is_empty() else name] = int(_var.get(key, 0)) | (1 << bit)


## SetQuestInfo's argument is 3 in every hook read so far and nothing says what
## it selects, so it is RECORDED and not acted on. Acting on an unidentified
## number would be inventing a meaning the data does not carry.
func quest_info(value: int) -> void:
	last_quest_info = value


## Retail writes the save here. The port has no save format to write yet, so
## this counts the request -- which is the honest amount of behaviour to have.
func autosave(_value: int) -> void:
	autosaves += 1


# --- queries -----------------------------------------------------------------

## A quest's state MASK, or 0 when the bytecode has never written one. The
## variable is named for the quest id as a DECIMAL STRING, which is how the
## records spell it: SetVarBit("74", 3) sets bit 3.
func state_of(quest: int) -> int:
	return int(_var.get(str(quest), 0))


## Started. Stays true after the quest finishes, because the bit stays set --
## that is the file's own model, and is_running() is what asks the other
## question.
func is_active(quest: int) -> bool:
	return (state_of(quest) & (1 << STATE_ACTIVE)) != 0


## Marks a quest started. Called by whatever runs OnEnter, never by the VM --
## see _entered for why this cannot come from the bytecode.
func mark_entered(quest: int) -> void:
	_entered[quest] = true



func mark_finished(quest: int) -> void:
	completed[quest] = true

## Every quest id this log has marked entered, ascending -- the save
## snapshot's "port bookkeeping" half (P1): _entered is the port's own
## flag, separate from the bytecode's bits, and both halves persist.
func entered_ids() -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array(_entered.keys())
	out.sort()
	return out


## Bulk restore for SaveState: replaces BOTH halves of the quest state with
## the snapshot's. _var keys arrive as decimal strings (the bytecode's own
## spelling, see state_of); entered ids arrive as ints.
func restore_states(states: Dictionary, entered: Array) -> void:
	_var.clear()
	for k in states:
		_var[str(k)] = int(states[k])
	_entered.clear()
	for q in entered:
		_entered[int(q)] = true


## Started and not yet finished. This is the question a quest book asks, and
## answering it needs both the file's variable and the port's own flag.
func is_running(quest: int) -> bool:
	return _entered.has(quest) and not is_done(quest)


func is_done(quest: int) -> bool:
	return completed.has(quest) or (state_of(quest) & (1 << STATE_DONE)) != 0


## Every variable the bytecode has written, for a gate that wants to see the
## whole effect of a run rather than one quest's slice.
func vars() -> Dictionary[String, int]:
	return _var.duplicate()


## Native name lookup requires full length and case-insensitive equality.
## The found bit matters: IsNotVarBit on an absent variable is also false.
func named_variable(name: String) -> Dictionary:
	var key := _variable_key(name)
	return {"found": not key.is_empty(), "value": int(_var.get(key, 0))}


func named_variables() -> Dictionary:
	var out := {}
	for key in _var:
		out[key.to_lower()] = int(_var[key])
	return out


func _variable_key(name: String) -> String:
	for key in _var:
		if key.nocasecmp_to(name) == 0:
			return key
	return ""


## Fills in each line's `text` from a Sacred.Resources.
##
## THE KEYS RESOLVE. This used to say they did not -- "they appear in
## funkcode.bin and in NO other file in the install, so global.res has nothing
## to answer with" -- and that was wrong for the reason recorded in row 954:
## the name hash was reimplemented in 64-bit and stopped matching retail's
## wrapping int32 from the fifth character on, which is every symbolic key and
## no numeric one. Quest 74 reads:
##
##   HQ_7_4_1_Log_Title   "The Soul of the Demon"
##   HQ_7_4_1_Log_Header  "Kill the demon, after Shareefa has summoned it."
##   HQ_7_4_1_Log_Qstart  "Shareefa told me that she would summon the demon..."
##   HQ_Log_Qend          "Quest completed."
##
## A COMPOSED key -- `NAME+Var(X)+SUFFIX` -- is instantiated from this log's own
## variables, which is the whole reason the substitution belongs here and not in
## Sacred.Resources: the VM's state is what the key is missing.
##
## Returns how many resolved, so a caller reports the shortfall rather than
## showing a blank quest book and calling it working.
func resolve_with(res) -> int:
	if res == null:
		return 0
	var got := 0
	for l in lines:
		var key: String = l["key"]
		var text: String = res.resolve(key)
		if text == key:
			# Unresolved as written. If it is composed, substitute and retry.
			text = _compose(res, key)
		l["text"] = text if text != key else ""
		if l["text"] != "":
			got += 1
	return got


## One composed key, instantiated from this log's variables. `NAME+Var(X)+SUF`
## takes X's value; an unknown variable yields "" rather than a guessed 0,
## because index 0 is a real quest in every template measured.
func _compose(res, key: String) -> String:
	var bare := key.substr(4) if key.to_lower().begins_with("res:") else key
	var open := bare.find("+")
	if open < 0:
		return key
	var inner := bare.substr(open + 1, bare.rfind("+") - open - 1)
	var lb := inner.find("(")
	var rb := inner.rfind(")")
	if lb < 0 or rb <= lb:
		return key
	var vname := inner.substr(lb + 1, rb - lb - 1)
	if not _var.has(vname):
		return key
	return res.compose(bare, int(_var[vname]))
