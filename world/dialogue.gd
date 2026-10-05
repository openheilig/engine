extends RefCounted
## Engine-only interpreter of installed dialogue definitions/procedures.
## LGP dispatcher sub_826AEF2, definition lookup sub_825D466, NPCstate
## sub_8294750/sub_824F354, button sub_82A8AE6 and quest lifecycle
## sub_825E2F2/sub_825FFE2. No inferred dialogue labels or callback success.
const VM := preload("res://world/script.gd")
const Vectoren := preload("res://formats/vectoren.gd")
const Pak := preload("res://formats/pak.gd")

var _host: WeakRef
var host: RefCounted:
	get:
		return _host.get_ref()
var resources: RefCounted
var table: RefCounted
var code := PackedByteArray()
var vm := VM.new()
## Index zero is the native empty sentinel; definitions are 80-byte records.
var definitions: Array[Dictionary] = []
var texts: Array[Dictionary] = []
var choices: Array[Dictionary] = []
var last_error := ""
var active_handle := ""
var revision := 0
var _checking: Dictionary[int, bool] = {}
var _depth := 0

func _init(dir: String, cast: RefCounted, res: RefCounted) -> void:
	_host = weakref(cast)
	resources = res
	table = Vectoren.new(dir)
	code = FileAccess.get_file_as_bytes(Pak.resolve(dir.path_join("funkcode.bin")))
	host.dialogue = self

## Bootstrap variables are initialized in the VERIFIED native branch order.
## Placement remains the existing Startcode reader's job, not full execution of
## every bootstrap effect (notably movie/map initialization).
func bootstrap(start) -> bool:
	last_error = ""
	var records := vm.decode(start.code, 0, start.code.size())
	if records.is_empty():
		return _fail("unreadable StartCode")
	var selected := vm.reachable(records, host.named_variables())
	if not selected.get("ok", false):
		return _fail(str(selected.get("error", "StartCode condition refused")))
	for record: Dictionary in selected["records"]:
		var op := int(record["op"])
		var args: Array = record["args"]
		if op == VM.OP_DIALOG_DEF:
			if not append_definition(start.code.slice(int(record["offset"]) + 4, int(record["offset"]) + int(record["length"]))):
				return false
		elif op in [65, VM.OP_SET_VAR, VM.OP_SET_VAR_BIT]:
			if args.size() != 2 or int(args[0][0]) != 1 or int(args[1][0]) != 11:
				return _fail("unsupported bootstrap variable operand")
			if op == VM.OP_SET_VAR_BIT:
				host.set_var(str(args[0][1]), int(args[1][1]))
			else:
				host.set_script_var(str(args[0][1]), int(args[1][1]))
	return host.import_bootstrap(start)

func append_definition(body: PackedByteArray) -> bool:
	if body.size() != 80:
		return _fail("dialogue definition must be 80 bytes")
	var proc := body.decode_s32(68)
	if proc < 0 or table.proc_at(proc).is_empty():
		return _fail("dialogue procedure index %d is absent" % proc)
	if definitions.is_empty():
		definitions.append({"id": 0, "name": "", "procedure": 0, "state": 0, "actor_id": 0})
	definitions.append({"id": body.decode_s32(0), "name": body.slice(4, 68).get_string_from_ascii(),
		"procedure": proc, "state": body.decode_s32(72), "actor_id": 0})
	return true

func definition_index(name: String) -> int:
	for i in definitions.size():
		if str(definitions[i]["name"]).nocasecmp_to(name) == 0:
			return i
	return -1

func definition_id(id: int) -> int:
	if id == 0:
		return 0
	for i in definitions.size():
		if int(definitions[i]["id"]) == id:
			return i
	return -1

## Native -2 preserves, other nonpositive values clear. Clearing removes the
## previous definition's actor back-reference, not just a visible label.
func bind_dialogue(handle: String, index: int) -> bool:
	var entry: Dictionary = host.entry(handle)
	if entry.is_empty():
		return _fail("NPCstate handle %s does not exist" % handle)
	if index == -2:
		return true
	if index >= definitions.size():
		return _fail("NPCstate dialogue index %d is absent" % index)
	var previous := int(entry.get("dialogue", 0))
	if previous > 0 and previous < definitions.size():
		definitions[previous]["actor_id"] = 0
	index = maxi(0, index)
	entry["dialogue"] = index
	entry["dialogue_enabled"] = index > 0
	entry["object_flags"] = (int(entry.get("object_flags", 0)) | 0x80000) if index > 0 else (int(entry.get("object_flags", 0)) & ~0x80000)
	if index > 0:
		definitions[index]["actor_id"] = int(entry.get("actor_id", 0))
	return true

func set_definition_state(name: String, value: int) -> bool:
	var index := definition_index(name)
	if index < 0:
		return _fail("SetDialogState definition %s absent" % name)
	definitions[index]["state"] = value
	return true

func open(handle: String) -> Dictionary:
	last_error = ""
	revision += 1
	texts.clear()
	choices.clear()
	active_handle = ""
	var entry: Dictionary = host.entry(handle)
	if entry.is_empty() or entry.get("deleted", false):
		_fail("dialogue NPC %s does not exist" % handle)
		return result()
	var index := int(entry.get("dialogue", 0))
	if index <= 0 or index >= definitions.size():
		_fail("NPC %s has no bound dialogue" % handle)
		return result()
	active_handle = str(entry["handle"])
	if not _run(table.proc_at(int(definitions[index]["procedure"]))):
		texts.clear()
		choices.clear()
	return result()

func choose(index: int, expected_revision: int) -> Dictionary:
	last_error = ""
	if expected_revision != revision or active_handle.is_empty() or index < 0 or index >= choices.size():
		_fail("stale or absent dialogue choice")
		return result()
	var target := str(choices[index]["procedure"])
	# A button calls precisely the installed named procedure; no synthetic
	# acceptance branch and no re-running the NPC's opening procedure.
	var procedure: Dictionary = table.procedure(target)
	if not _preflight(procedure):
		return result()
	revision += 1
	texts.clear()
	choices.clear()
	if not _run(procedure):
		return result()
	if choices.is_empty() and texts.is_empty():
		active_handle = ""
	return result()

func close() -> void:
	revision += 1
	active_handle = ""
	texts.clear()
	choices.clear()

func result() -> Dictionary:
	return {"ok": last_error.is_empty(), "error": last_error, "handle": active_handle,
		"texts": texts.duplicate(true), "choices": choices.duplicate(true), "revision": revision}

func append_text(args: Array) -> bool:
	if args.size() != 1 or int(args[0][0]) != 0x1e:
		return _fail("unsupported executed text operand")
	var key := str(args[0][1])
	var text := _resolve(key)
	if text.is_empty():
		return _fail("installed dialogue prose %s unresolved" % key)
	# Native tag 1e clears the previous resource list before this line, unless
	# the append modifier is set. Unsupported modifier shapes are refused.
	texts.clear()
	texts.append({"key": key, "text": text})
	return true

func append_button(args: Array) -> bool:
	if args.size() != 2 or int(args[0][0]) != 1 or int(args[1][0]) != 1:
		return _fail("unsupported executed SetButton operand")
	if choices.size() >= 5:
		return true # native bounded caption slots, not an unsupported-op skip
	var key := str(args[0][1])
	var target := str(args[1][1])
	var text := _resolve(key)
	if text.is_empty() or table.procedure(target).is_empty():
		return _fail("SetButton caption or procedure absent: %s -> %s" % [key, target])
	choices.append({"key": key, "text": text, "procedure": target})
	return true

func _resolve(key: String) -> String:
	if resources == null:
		return ""
	if key.to_lower().begins_with("res:"):
		return resources.resolve(key)
	return resources.by_name(key)

## StartQuest validates/runs Trigger, then OnEnter once. EndQuest runs OnExit
## only for a running quest; native completion is NOT a write to variable 03.
func start_quest(quest: int) -> bool:
	if host.is_running(quest) or host.is_done(quest):
		return true
	if not _validate_quest(quest, true):
		return false
	var trigger: Dictionary = table.hook(quest, Vectoren.H_TRIGGER)
	if not trigger.is_empty() and not _run(trigger):
		return false
	host.mark_entered(quest)
	var enter: Dictionary = table.hook(quest, Vectoren.H_ON_ENTER)
	return _run(enter) if not enter.is_empty() else true

func end_quest(quest: int) -> bool:
	if not host.is_running(quest):
		return true
	if not _validate_quest(quest, false):
		return false
	var exit: Dictionary = table.hook(quest, Vectoren.H_ON_EXIT)
	if not exit.is_empty() and not _run(exit):
		return false
	host.mark_finished(quest)
	return true

func _validate_quest(quest: int, starting: bool) -> bool:
	if not table.has_quest(quest):
		return _fail("quest %d absent" % quest)
	if _checking.has(quest):
		return _fail("recursive quest callback %d" % quest)
	_checking[quest] = true
	var ok := true
	var hooks: Array = [Vectoren.H_TRIGGER, Vectoren.H_ON_ENTER] if starting else [Vectoren.H_ON_EXIT]
	for hook in hooks:
		var procedure: Dictionary = table.hook(quest, hook)
		if not procedure.is_empty() and not _preflight(procedure):
			ok = false
			break
	_checking.erase(quest)
	return ok

func _preflight(procedure: Dictionary) -> bool:
	if procedure.is_empty():
		return _fail("procedure absent")
	var length := int(procedure["length"])
	if length == 0:
		return true
	var records := vm.decode(code, int(procedure["offset"]), length)
	if records.is_empty():
		return _fail("procedure %s malformed" % procedure["name"])
	var selected := vm.reachable(records, host.named_variables())
	if not selected.get("ok", false):
		return _fail("%s: %s" % [procedure["name"], selected.get("error", "condition refused")])
	for record: Dictionary in selected["records"]:
		var op := int(record["op"])
		if not VM.IMPLEMENTED.has(op):
			return _fail("%s executes unsupported opcode %d" % [procedure["name"], op])
		if not validate_record(record):
			return false
	return true

func _run(procedure: Dictionary) -> bool:
	if _depth >= 32:
		return _fail("procedure recursion limit")
	if not _preflight(procedure):
		return false
	_depth += 1
	var ok := vm.run(code, int(procedure["offset"]), int(procedure["length"]), host)
	_depth -= 1
	if not ok and last_error.is_empty():
		_fail("%s refused executed opcode %d" % [procedure["name"], vm.refused_op])
	return ok

func validate_record(record: Dictionary) -> bool:
	var op := int(record["op"])
	var args: Array = record["args"]
	match op:
		VM.OP_NOP: return true
		VM.OP_DIALOG_DEF:
			var body: PackedByteArray = record["definition"]
			if body.size() == 80 and not table.proc_at(body.decode_s32(68)).is_empty():
				return true
		VM.OP_START_QUEST, VM.OP_END_QUEST:
			if args.size() == 1 and int(args[0][0]) == 11:
				var quest := int(args[0][1])
				if op == VM.OP_START_QUEST and (host.is_running(quest) or host.is_done(quest)):
					return true
				if op == VM.OP_END_QUEST and not host.is_running(quest):
					return true
				return _validate_quest(quest, op == VM.OP_START_QUEST)
		VM.OP_GOLD:
			if args.size() == 2 and int(args[0][0]) == 1 and int(args[1][0]) == 11 and str(args[0][1]).nocasecmp_to("hero") == 0 and host.session != null:
				return true
		VM.OP_DELETE_NPC:
			if args.size() == 1 and int(args[0][0]) == 1 and not host.entry(str(args[0][1])).is_empty():
				return true
		VM.OP_COMPASS_POS:
			if args.size() == 3 and args.all(func(arg: Array) -> bool: return int(arg[0]) == 11):
				return true
		VM.OP_DIALOG_STATE:
			if args.size() == 2 and int(args[0][0]) == 1 and int(args[1][0]) == 11 and definition_index(str(args[0][1])) >= 0:
				return true
		VM.OP_SOUND:
			if args.size() == 1 and int(args[0][0]) == 1 and str(args[0][1]).begins_with("SOUND_FX_"):
				return true
		VM.OP_TEXT:
			if args.size() == 1 and int(args[0][0]) == 0x1e and not _resolve(str(args[0][1])).is_empty():
				return true
		VM.OP_BUTTON:
			if args.size() == 2 and int(args[0][0]) == 1 and int(args[1][0]) == 1 and not _resolve(str(args[0][1])).is_empty() and not table.procedure(str(args[1][1])).is_empty():
				return true
		VM.OP_SET_NPC_STATE:
			if args.size() == 2 and int(args[0][0]) == 1 and int(args[1][0]) in [9, 10] and not host.entry(str(args[0][1])).is_empty():
				return true
		VM.OP_CREATE_NPC:
			var has_handle := false
			var has_body := false
			for arg in args:
				if int(arg[0]) == 1: has_handle = true
				if int(arg[0]) == 2: has_body = true
				if int(arg[0]) == 9 and definition_index(str(arg[1])) < 0:
					return _fail("CreateNPC dialogue %s absent" % arg[1])
			if has_handle and has_body: return true
		_:
			# Existing verified core handlers retain their convention.
			return true
	return _fail("unsupported executed operand for opcode %d" % op)

## Schema3 fragment extends legacy SaveState's cast records. Base quest masks,
## entered IDs and registry actors remain in their original channels; no UI
## choice list is serialized as authoritative state.
func snapshot() -> Dictionary:
	var states: Array = []
	for definition in definitions:
		states.append({"id": int(definition["id"]), "name": str(definition["name"]),
			"procedure": int(definition["procedure"]), "state": int(definition["state"]),
			"actor_id": int(definition["actor_id"])})
	var targets := {}
	for quest in host.quest_targets:
		var target: Dictionary = host.quest_targets[quest]
		var cell: Vector2i = target["cell"]
		targets[str(quest)] = {"cell": [cell.x, cell.y], "radius": int(target["radius"])}
	var bindings := {}
	for entry: Dictionary in host.cast:
		bindings[str(entry["handle"])] = {
			"actor_id": int(entry.get("actor_id", 0)),
			"dialogue": int(entry.get("dialogue", 0)),
			"main": int(entry.get("main", 0)), "off": int(entry.get("off", 0)),
			"deleted": bool(entry.get("deleted", false)),
			"bootstrap": bool(entry.get("bootstrap", false)),
			"layer": int(entry.get("layer", 0))}
	return {"definitions": states, "completed": host.completed.keys(), "quest_targets": targets,
		"cast_bindings": bindings, "script_vars": host.script_vars.duplicate(),
		"book": host.lines.duplicate(true), "autosaves": host.autosaves,
		"quest_info": host.last_quest_info}

## JSON.parse_string represents its numbers as floats. Accept only exact,
## finite integral values that convert to int64 without overflow; strings,
## booleans, fractions and non-finite values are never coerced into state.
static func _integer(value: Variant) -> bool:
	if value is int:
		return true
	return value is float and is_finite(value) and value == floor(value) \
		and value >= -9223372036854775808.0 and value < 9223372036854775808.0

func validate_snapshot(fragment: Dictionary) -> String:
	var states: Variant = fragment.get("definitions")
	if not states is Array or states.size() != definitions.size():
		return "dialogue definition table differs"
	for i in definitions.size():
		var state: Variant = states[i]
		if not state is Dictionary or state.get("name") != definitions[i]["name"] or not _integer(state.get("procedure")) or not _integer(state.get("id")) or int(state["procedure"]) != int(definitions[i]["procedure"]) or int(state["id"]) != int(definitions[i]["id"]):
			return "dialogue definition identity differs at %d" % i
		if not _integer(state.get("state")) or not _integer(state.get("actor_id")) or int(state["actor_id"]) < 0:
			return "invalid dialogue definition state at %d" % i
	if not fragment.get("completed") is Array or not fragment.get("quest_targets") is Dictionary:
		return "invalid dialogue quest state"
	for quest in fragment["completed"]:
		if not _integer(quest) or not table.has_quest(int(quest)):
			return "invalid completed dialogue quest"
	for quest in fragment["quest_targets"]:
		var target: Variant = fragment["quest_targets"][quest]
		if not str(quest).is_valid_int() or not table.has_quest(int(quest)) or not target is Dictionary:
			return "invalid dialogue compass quest"
		var cell: Variant = target.get("cell")
		if not cell is Array or cell.size() != 2 or not _integer(cell[0]) or not _integer(cell[1]) or not _integer(target.get("radius")):
			return "invalid dialogue compass target"
	if not fragment.get("cast_bindings") is Dictionary or not fragment.get("script_vars") is Dictionary or not fragment.get("book") is Array:
		return "invalid dialogue host state"
	if not _integer(fragment.get("autosaves")) or int(fragment["autosaves"]) < 0 or not _integer(fragment.get("quest_info")):
		return "invalid dialogue book effects"
	var handles := {}
	for handle in fragment["cast_bindings"]:
		if not handle is String or handles.has(handle.to_lower()):
			return "invalid duplicate dialogue handle"
		handles[handle.to_lower()] = true
		var binding: Variant = fragment["cast_bindings"][handle]
		if not binding is Dictionary:
			return "invalid dialogue cast binding"
		for field in ["actor_id", "dialogue", "main", "off", "layer"]:
			if not _integer(binding.get(field)):
				return "invalid dialogue cast %s" % field
		if int(binding["actor_id"]) < 0 or int(binding["dialogue"]) < 0 or int(binding["dialogue"]) >= states.size():
			return "invalid dialogue cast reference"
		if not binding.get("deleted") is bool or not binding.get("bootstrap") is bool:
			return "invalid dialogue cast lifecycle"
	for key in fragment["script_vars"]:
		if not key is String or not _integer(fragment["script_vars"][key]):
			return "invalid named script variable"
	for line in fragment["book"]:
		if not line is Dictionary or not _integer(line.get("quest")) or not _integer(line.get("kind")) or not line.get("key") is String or not line.get("text") is String:
			return "invalid dialogue quest book line"
	return ""

## Parent calls before ANY session mutation, using the incoming legacy cast/
## registry channels, not the currently running session's identities.
func validate_bindings(fragment: Dictionary, cast_records: Array, actor_ids: PackedInt64Array) -> String:
	var error := validate_snapshot(fragment)
	if not error.is_empty():
		return error
	var incoming := {}
	for entry: Dictionary in cast_records:
		incoming[str(entry["handle"]).to_lower()] = true
	if incoming.size() != fragment["cast_bindings"].size():
		return "dialogue cast membership differs"
	for handle in fragment["cast_bindings"]:
		if not incoming.has(str(handle).to_lower()):
			return "dialogue handle missing from cast"
		var binding: Dictionary = fragment["cast_bindings"][handle]
		var actor := int(binding["actor_id"])
		if actor != 0 and not bool(binding["deleted"]) and not actor_ids.has(actor):
			return "dialogue actor missing from registry"
	# Multiple NPCs may share a definition. Native keeps ONLY its last actor
	# back-reference; do not demand a false one-to-one binding convention.
	for index in fragment["definitions"].size():
		var actor := int(fragment["definitions"][index]["actor_id"])
		if actor == 0:
			continue
		var bound := false
		for binding: Dictionary in fragment["cast_bindings"].values():
			if int(binding["dialogue"]) == index and int(binding["actor_id"]) == actor and not bool(binding["deleted"]):
				bound = true
				break
		if not bound:
			return "dialogue actor back-reference has no bound NPC"
	return ""

func restore(fragment: Dictionary) -> String:
	var error := validate_snapshot(fragment)
	if not error.is_empty():
		return error
	for handle in fragment["cast_bindings"]:
		if host.entry(str(handle)).is_empty():
			return "dialogue handle missing from restored cast"
	for i in definitions.size():
		definitions[i]["state"] = int(fragment["definitions"][i]["state"])
		definitions[i]["actor_id"] = int(fragment["definitions"][i]["actor_id"])
	host.completed.clear()
	for quest in fragment["completed"]:
		host.completed[int(quest)] = true
	host.quest_targets.clear()
	for quest in fragment["quest_targets"]:
		var target: Dictionary = fragment["quest_targets"][quest]
		host.quest_targets[int(quest)] = {"cell": Vector2i(int(target["cell"][0]), int(target["cell"][1])), "radius": int(target["radius"])}
	host.script_vars.clear()
	for key in fragment["script_vars"]:
		host.script_vars[str(key)] = int(fragment["script_vars"][key])
	for handle in fragment["cast_bindings"]:
		var entry: Dictionary = host.entry(str(handle))
		var binding: Dictionary = fragment["cast_bindings"][handle]
		for field in binding:
			entry[field] = int(binding[field]) if field in ["actor_id", "dialogue", "main", "off", "layer"] else binding[field]
		entry["dialogue_enabled"] = int(entry["dialogue"]) > 0
		entry["object_flags"] = 0x80000 if int(entry["dialogue"]) > 0 else 0
	host.lines.clear()
	for line: Dictionary in fragment["book"]:
		host.lines.append({"quest": int(line["quest"]), "kind": int(line["kind"]),
			"key": str(line["key"]), "text": str(line["text"])})
	host.autosaves = int(fragment["autosaves"])
	host.last_quest_info = int(fragment["quest_info"])
	host.effects.clear()
	close()
	return ""

func _fail(error: String) -> bool:
	last_error = error
	return false
