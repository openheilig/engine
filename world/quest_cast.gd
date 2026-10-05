class_name QuestCast
extends "res://world/quest_log.gd"
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
## The quest origin for position-less CreateNPC (the hero's cell), set by
## the runner before executing quest hooks.
var quest_origin := Vector2i.ZERO
## Canonical session/VM context, supplied by the composition root, never a
## sector-owned host. Runtime references are not serialized.
var _session: WeakRef
var session: Object:
	get:
		return _session.get_ref() if _session != null else null
var dialogue: RefCounted
var positions: Dictionary = {}
var quest_targets: Dictionary[int, Dictionary] = {}
## Parent drains these into its real presentation/audio handlers.
var effects: Array[Dictionary] = []


func bind_runtime(owner: Object) -> void:
	_session = weakref(owner)


func named_variable(name: String) -> Dictionary:
	for key in script_vars:
		if key.nocasecmp_to(name) == 0:
			return {"found": true, "value": int(script_vars[key])}
	return super.named_variable(name)


func named_variables() -> Dictionary:
	var out := super.named_variables()
	for key in script_vars:
		out[key.to_lower()] = int(script_vars[key])
	return out


func set_var(name: String, bit: int) -> void:
	for key in script_vars:
		if key.nocasecmp_to(name) == 0:
			if bit >= 0 and bit < 32:
				script_vars[key] = int(script_vars[key]) | (1 << bit)
			return
	super.set_var(name, bit)


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
	for key in script_vars:
		if key.nocasecmp_to(name) == 0:
			script_vars[key] = value
			return
	var bit_key := _variable_key(name)
	if not bit_key.is_empty():
		_var[bit_key] = value
	else:
		script_vars[name] = value


func create_npc(handle: String, creature: int, name: String, task: String,
		art: String, cell: Vector2i = NO_CELL) -> void:
	# A position-less quest CreateNPC spawns at the quest origin (the
	# hero's cell), not NO_CELL: retail's nun appears on the hero and
	# walks to her Goto target (the creature push displaces the hero).
	if cell == NO_CELL and quest_origin != Vector2i.ZERO:
		cell = quest_origin
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
		"task": task, "art": art, "cell": cell, "compass": false,
		"main": 0, "off": 0, "dialogue": 0, "actor_id": 0, "deleted": false})


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


func configure_npc(handle: String, main_hand: int, off_hand: int, dialog_name: String) -> void:
	var e: Dictionary = cast[-1] if handle.to_lower() == "non_unique" and not cast.is_empty() else entry(handle)
	if e.is_empty():
		return
	e["main"] = main_hand
	e["off"] = off_hand
	if not dialog_name.is_empty() and dialogue != null:
		dialogue.bind_dialogue(str(e["handle"]), dialogue.definition_index(dialog_name))


## Preserves native script handles even when a nearby visual actor is built
## later. The registry identity is independent of sector rendering lifetime.
func import_bootstrap(start) -> bool:
	positions = start.places
	for npc: Dictionary in start.npcs:
		var handle := str(npc["handle"])
		create_npc(handle, int(npc["body"]), str(npc.get("script_name", "")),
			str(npc.get("task", "")), str(npc.get("art", "")), npc["cell"])
		var e: Dictionary = cast[-1]
		handle = str(e["handle"])
		e["bootstrap"] = true
		e["layer"] = int(npc["layer"])
		e["main"] = int(npc["main"])
		e["off"] = int(npc["off"])
		if not str(npc.get("dialogue", "")).is_empty():
			if dialogue == null or not dialogue.bind_dialogue(handle, dialogue.definition_index(npc["dialogue"])):
				return false
	return true


func script_position(name: String) -> Vector2i:
	for key in positions:
		if str(key).nocasecmp_to(name) == 0:
			return positions[key]
	return NO_CELL


func bind_actor(handle: String, actor_id: int) -> bool:
	var e := entry(handle)
	if e.is_empty() or e.get("deleted", false) or session == null or session.registry.get_actor(actor_id) == null:
		return false
	var previous := int(e.get("actor_id", 0))
	if previous != 0 and previous != actor_id:
		return false
	e["actor_id"] = actor_id
	if dialogue != null:
		dialogue.bind_dialogue(handle, int(e.get("dialogue", 0)))
	return true


func handle_for_actor(actor_id: int) -> String:
	for e in cast:
		if int(e.get("actor_id", 0)) == actor_id and not e.get("deleted", false):
			return str(e["handle"])
	return ""


func entry(handle: String) -> Dictionary:
	if _by_handle.is_empty() and not cast.is_empty():
		for i in cast.size():
			_by_handle[str(cast[i]["handle"]).to_lower()] = i
	return cast[int(_by_handle[handle.to_lower()])] if _by_handle.has(handle.to_lower()) else {}


func npc_state(args: Array) -> bool:
	if dialogue == null or args.size() != 2 or int(args[0][0]) != 1:
		return false
	var index := -1
	if int(args[1][0]) == 9:
		index = dialogue.definition_index(str(args[1][1]))
	elif int(args[1][0]) == 10:
		index = dialogue.definition_id(int(args[1][1]))
	else:
		return false
	return dialogue.bind_dialogue(str(args[0][1]), index)


func define_dialogue(body: PackedByteArray) -> bool:
	return dialogue != null and dialogue.append_definition(body)


func dialogue_text(args: Array) -> bool:
	return dialogue != null and dialogue.append_text(args)


func dialogue_button(args: Array) -> bool:
	return dialogue != null and dialogue.append_button(args)


func dialogue_state(name: String, value: int) -> bool:
	return dialogue != null and dialogue.set_definition_state(name, value)


func start_quest(quest: int) -> bool:
	return dialogue != null and dialogue.start_quest(quest)


func end_quest(quest: int) -> bool:
	return dialogue != null and dialogue.end_quest(quest)


func give_gold(handle: String, amount: int) -> bool:
	if session == null or handle.nocasecmp_to("hero") != 0:
		return false
	session.hero_gold += amount
	return true


func delete_npc(handle: String) -> bool:
	var e := entry(handle)
	if e.is_empty():
		return false
	if session != null and int(e.get("actor_id", 0)) != 0:
		session.registry.despawn(int(e["actor_id"]))
	if dialogue != null:
		dialogue.bind_dialogue(handle, 0)
	e["deleted"] = true
	e["compass"] = false
	return true


func quest_compass_pos(cell: Vector2i, quest: int) -> bool:
	quest_targets[quest] = {"cell": cell, "radius": 1200}
	return true


func play_sound(name: String) -> bool:
	if name.is_empty():
		return false
	effects.append({"kind": "PlaySound", "name": name})
	return true


## Every extended handler validates shape/semantic prerequisites, including
## nested quest procedures, before the VM applies any reachable record.
func validate_script_record(record: Dictionary) -> bool:
	return dialogue.validate_record(record) if dialogue != null else int(record["op"]) not in [3, 15, 18, 20, 26, 55, 60, 63, 86, 104]


# --- queries -----------------------------------------------------------------

## The cast entries that something actually placed, in creation order. What
## main.gd builds; an unplaced NPC is real but has nowhere to stand.
func placed() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e: Dictionary in cast:
		if e["cell"] != NO_CELL and not e.get("deleted", false):
			out.append(e)
	return out


func _index_of(handle: String, op: String) -> int:
	var e := entry(handle)
	if e.is_empty():
		push_warning("QuestCast: %s names handle '%s', which nothing created" % [op, handle])
		return -1
	return int(_by_handle[handle.to_lower()])
