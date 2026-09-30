class_name QuestCast
extends QuestLog
## A QuestLog that can also receive the cast a quest hook creates.
##
## WHY THIS IS NOT JUST QuestLog. That class documents its own scope as holding
## "only what the player has actually done" -- quest state and the quest book.
## An NPC a script spawned is WORLD state: it exists whether or not the player
## ever speaks to it. Rather than widen QuestLog's meaning, this subclass adds
## the four host methods the NPC opcodes need, and `world/encounter.gd` goes on
## using a plain QuestLog with no change at all.
##
## WHAT THIS DELIBERATELY DOES NOT DO: build anything. Every entry below is a
## REQUEST -- "a rig of this creature belongs at this cell" -- and main.gd is
## what turns one into a PlayerView. `world/` may not name Node3D, add_child or
## SectorView (parity/verify.gd LAYER_RULES), and more to the point the split is
## what lets a headless check assert the whole of quest 1's effect without a
## viewport. Same idiom as ScriptVM's own "bytes in, effects on a HOST out".
##
## THE HANDLE IS THE IDENTITY. Retail's script refers to an NPC by a `res:`
## string (`res:17095`), created by one record and positioned by another two
## records later, and quest 9 reaches for the SAME handle to walk her onward.
## So handles are matched case-insensitively: quest 1 writes `res:17095` on
## CreateNPC and `Res:17095` on the NPC_Goto that follows it, in the same hook.

## One script-created NPC, in the order the bytecode created it.
##   handle    the `res:` string the script identifies it by, as written
##   creature  items.pak record id -- 679 is NOVIZIN02.GRN
##   name      the script's own name for it, e.g. `novizin1`
##   task      its assignment, e.g. `auftrag10`
##   art       its combat art, e.g. `ECS_HEALING`
##   cell      where NPC_Goto put it, or NO_CELL if nothing ever placed it
##   compass   true once QuestKompassObj named it -- the `?!` over its head
var cast: Array[Dictionary] = []

## A created NPC that no NPC_Goto ever placed. Distinct from cell (0, 0), which
## is a real corner of the world.
const NO_CELL := Vector2i(-1, -1)

## SetVar's writes, by name. Kept out of QuestLog's `_var` on purpose: that one
## is a bit array with a 160-bit ceiling and these are plain values under a
## name. Nothing in the port reads them yet; they are here so a hook that writes
## one is not silently lossy.
var script_vars: Dictionary[String, int] = {}

var _by_handle: Dictionary[String, int] = {}


## P1 save/restore: clears the handle index alongside `cast` so a restored
## cast rebuilds its own map. A stale index would route handles at entries
## the snapshot replaced.
func reset_handles() -> void:
	_by_handle.clear()


# --- ScriptVM host interface -------------------------------------------------

## SetVar(name, value). NOT SetVarBit -- see QuestLog.set_var(), which takes a
## BIT INDEX. Routing both to one method would write bit 0 of `PoolDLG` and
## call it done.
func set_script_var(name: String, value: int) -> void:
	script_vars[name] = value


func create_npc(handle: String, creature: int, name: String, task: String,
		art: String, cell: Vector2i = NO_CELL) -> void:
	var key := handle.to_lower()
	if _by_handle.has(key):
		# Retail's sector scripts create every NPC under the placeholder
		# handle "NON_UNIQUE" (the runtime renumbers them); uniquify that
		# shape instead of dropping the placement. Any other duplicate
		# reports rather than guessing which one wins.
		if key != "non_unique":
			push_warning("QuestCast: handle '%s' created twice" % handle)
			return
		var n := 2
		while _by_handle.has("%s#%d" % [key, n]):
			n += 1
		key = "%s#%d" % [key, n]
		handle = "%s#%d" % [handle, n]
	_by_handle[key] = cast.size()
	cast.append({"handle": handle, "creature": creature, "name": name,
		"task": task, "art": art, "cell": cell, "compass": false})


## Places an already-created NPC. A handle nothing created is a warning and no
## entry: inventing one here would put a rig in the world with no creature id,
## which is a crash later and a mystery now.
func npc_goto(handle: String, cell: Vector2i) -> void:
	var i := _index_of(handle, "NPC_Goto")
	if i >= 0:
		cast[i]["cell"] = cell


func quest_compass(handle: String) -> void:
	var i := _index_of(handle, "QuestKompassObj")
	if i >= 0:
		cast[i]["compass"] = true


# --- queries -----------------------------------------------------------------

## The cast entries that something actually placed, in creation order. What
## main.gd builds; an unplaced NPC is real but has nowhere to stand.
func placed() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e: Dictionary in cast:
		if e["cell"] != NO_CELL:
			out.append(e)
	return out


func _index_of(handle: String, op: String) -> int:
	var key := handle.to_lower()
	if not _by_handle.has(key):
		push_warning("QuestCast: %s names handle '%s', which nothing created" % [op, handle])
		return -1
	return _by_handle[key]
