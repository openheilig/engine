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

const STATE_ACTIVE := 1
const STATE_DONE := 3

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


# --- ScriptVM host interface -------------------------------------------------

func quest_book(quest: int, kind: int, key: String) -> void:
	lines.append({"quest": quest, "kind": kind, "key": key, "text": ""})


func set_var(name: String, value: int) -> void:
	_var[name] = value


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

## A quest's state, or -1 when the bytecode has never written one. The variable
## is named for the quest id as a DECIMAL STRING, which is how the records
## spell it: SetVarBit("74", 3).
func state_of(quest: int) -> int:
	return _var.get(str(quest), -1)


func is_active(quest: int) -> bool:
	return state_of(quest) == STATE_ACTIVE


## Marks a quest started. Called by whatever runs OnEnter, never by the VM --
## see _entered for why this cannot come from the bytecode.
func mark_entered(quest: int) -> void:
	_entered[quest] = true


## Started and not yet finished. This is the question a quest book asks, and
## answering it needs both the file's variable and the port's own flag.
func is_running(quest: int) -> bool:
	return _entered.has(quest) and not is_done(quest)


func is_done(quest: int) -> bool:
	return state_of(quest) == STATE_DONE


## Every variable the bytecode has written, for a gate that wants to see the
## whole effect of a run rather than one quest's slice.
func vars() -> Dictionary[String, int]:
	return _var.duplicate()


## Fills in each line's `text` from a Sacred.Resources.
##
## THE KEYS DO NOT RESOLVE, and that is a property of the shipped install
## rather than of this code: `Res:HQ_7_4_1_Log_Title`, `..._Log_Header`,
## `..._Log_Qstart` and `Res:HQ_Log_Qend` appear in funkcode.bin and in NO
## other file in the install, so global.res has nothing to answer with. This
## is the same gap as the 389 symbolic keys in credits.txt. Returns how many
## resolved, so a caller can report the shortfall instead of showing a blank
## quest book and calling it working.
func resolve_with(res) -> int:
	var got := 0
	for l in lines:
		var key: String = l["key"]
		var bare := key.substr(4) if key.to_lower().begins_with("res:") else key
		var text: String = res.by_id(-Sacred.Resources.name_hash(bare)) if res != null else ""
		l["text"] = text
		if text != "":
			got += 1
	return got
