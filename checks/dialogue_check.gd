extends "res://checks/check.gd"
## Real Dwarf bootstrap, installed prose, callback hooks and durable state.
## godot --headless --path godot-port --script checks/dialogue_check.gd
const VM := preload("res://world/script.gd")
const Cast := preload("res://world/quest_cast.gd")
const Dialogue := preload("res://world/dialogue.gd")
const Session := preload("res://world/game_session.gd")
const Start := preload("res://formats/startcode.gd")
const Resources := preload("res://formats/resources.gd")
const Registry := preload("res://world/actor_registry.gd")

func _init() -> void:
	super()
	var install := Sacred.find_install()
	assert(install != "", "requires retail install")
	var dir := install.path_join("bin/type_npc_zwerg")
	var host := Cast.new()
	var session := Session.new()
	session.quest_log = host
	session.registry = Registry.new()
	host.bind_runtime(session)
	var res := Resources.new(install.path_join("scripts/us/global.res"))
	var runtime := Dialogue.new(dir, host, res)
	var start := Start.new(dir)
	expect(runtime.bootstrap(start), "bootstrap refused: %s" % runtime.last_error)
	expect(host.named_variable("03") == {"found": true, "value": 1}, "03 bit zero not seeded")
	expect(host.entry("RES:17085").get("cell") == Vector2i(3349, 2534), "Romata identity/cell lost")
	expect(runtime.start_quest(1), "Dwarf OnEnter1 refused: %s" % runtime.last_error)
	var romata := host.entry("res:17085")
	var actor := session.registry.spawn(297, Vector2(romata["cell"]), 100, 100)
	expect(host.bind_actor("res:17085", actor), "Romata registry binding failed")
	var weston := host.entry("res:17437")
	var weston_actor := session.registry.spawn(297, Vector2(weston["cell"]), 100, 100)
	host.bind_actor("res:17437", weston_actor)
	var opened := runtime.open("RES:17085")
	expect(opened.get("ok", false), "Romata open refused: %s" % opened)
	expect(opened.get("texts", []).size() == 1 and opened.get("choices", []).size() == 1, "missing prose/choice")
	if not opened.get("choices", []).is_empty():
		expect(opened["choices"][0]["procedure"] == "trigger03", "wrong initial branch")
		expect(opened["texts"][0]["key"] == "HQ_3_1_4_DWA_NPC_AUFTRAG_QSTART", "wrong installed prose key")
		expect(not str(opened["texts"][0]["text"]).is_empty(), "installed prose unresolved")
		var chosen := runtime.choose(0, int(opened["revision"]))
		expect(chosen.get("ok", false), "trigger03 refused: %s" % chosen)
		expect(session.hero_gold == 2300, "GiveGold did not change real session purse")
		expect(int(host.named_variable("03")["value"]) == 3, "Q3 callback did not set bit one")
		expect(host.is_done(1) and host.is_running(3), "native quest lifecycle not durable")
		expect(session.registry.get_actor(weston_actor) == null, "DelNPC did not retire Weston actor")
		expect(host.quest_targets.get(3, {}).get("cell") == Vector2i(3217, 2771), "compass position missing")
		expect(host.effects.any(func(e: Dictionary) -> bool: return e.get("kind") == "PlaySound" and e.get("name") == "SOUND_FX_SCDWARF_AUDIO_3_4_2"), "sound event missing")
		var again := runtime.open("res:17085")
		expect(again.get("ok", false) and again.get("choices", [])[0]["procedure"] == "btn_HQNEW_OK", "Q3 flag did not select open-quest branch")
		expect(runtime.choose(0, int(again["revision"])).get("ok", false), "verified NOP callback refused")
		expect(session.hero_gold == 2300, "OK replayed reward")
		var fragment := runtime.snapshot()
		expect(runtime.validate_bindings(fragment, host.cast, session.registry.ids()) == "", "valid native shared-definition bindings rejected")
		_json_roundtrip(runtime, host, session, fragment)
		var bad := fragment.duplicate(true)
		bad["cast_bindings"]["Res:17085"]["actor_id"] = 999999
		expect(not runtime.validate_bindings(bad, host.cast, session.registry.ids()).is_empty(), "missing registry actor accepted")
		var untouched := runtime.snapshot()
		bad = fragment.duplicate(true)
		bad["definitions"][956]["procedure"] = 11533
		expect(not runtime.restore(bad).is_empty() and runtime.snapshot() == untouched, "foreign definition mutated live dialogue state")
		host.completed.clear()
		expect(runtime.restore(fragment) == "", "dialogue durable fragment failed restore")
		expect(host.is_done(1) and runtime.open("res:17085").get("choices", [])[0]["procedure"] == "btn_HQNEW_OK", "restore changed causal branch")
	_conditions()
	print("dialogue_check OK Romata installed text, trigger03, purse, registry, flags and restore")
	finish()

func _json_roundtrip(runtime, host, session, fragment: Dictionary) -> void:
	var parsed: Variant = JSON.parse_string(JSON.stringify(fragment))
	if not expect(parsed is Dictionary, "real dialogue JSON roundtrip did not parse"):
		return
	expect(runtime.validate_bindings(parsed, host.cast, session.registry.ids()) == "", "integral JSON floats rejected")
	expect(runtime.restore(parsed) == "", "JSON dialogue restore failed")
	expect(runtime.snapshot() == fragment, "JSON roundtrip changed durable dialogue state")
	expect(host.entry("res:17085")["actor_id"] is int and host.entry("res:17085")["dialogue"] is int, "JSON binding numbers were not normalized")
	expect(host.lines.all(func(line: Dictionary) -> bool: return line["quest"] is int and line["kind"] is int), "JSON quest book numbers were not normalized")
	var before: Dictionary = runtime.snapshot()
	for invalid in [0.5, NAN, INF, "1", true]:
		var bad: Dictionary = parsed.duplicate(true)
		bad["definitions"][956]["state"] = invalid
		expect(not runtime.restore(bad).is_empty() and runtime.snapshot() == before, "invalid definition numeric state mutated session")
	var fractional: Dictionary = parsed.duplicate(true)
	fractional["cast_bindings"]["Res:17085"]["actor_id"] = 1.5
	expect(not runtime.validate_bindings(fractional, host.cast, session.registry.ids()).is_empty(), "fractional actor binding accepted")
	expect(not runtime.restore(fractional).is_empty() and runtime.snapshot() == before, "fractional binding mutated session")

func _conditions() -> void:
	var vm := VM.new()
	var host := Cast.new()
	# Installed procedure: absent variables must fail BOTH bit predicates.
	var a := [[0x49, 0], [0x49, "Absent"], [0x4a, 1], [0x4a, "Absent"]]
	expect(vm.condition(a, host.named_variables()) == 0, "missing variable accepted")
	expect(vm.condition([[0x4a, 0], [0x4a, "Absent"]], host.named_variables()) == 0, "missing variable satisfied IsNotVarBit")
	host.set_script_var("CaseSensitiveSpelling", 0)
	expect(vm.condition([[0x4a, 0], [0x4a, "casesensitivespelling"]], host.named_variables()) == 1, "case insensitive existing variable failed")
	# IF false -> ELSE/NOP: unsupported unreachable opcode must not reject.
	var code := PackedByteArray([58, 0, 12, 0, 0x49, 0, 0, 0, 0, 65, 0, 0, 139, 0, 4, 0, 59, 0, 4, 0, 62, 0, 4, 0])
	expect(vm.run(code, 0, code.size(), host), "native unreachable opcode rejected")
	host.set_var("A", 0)
	expect(not vm.run(code, 0, code.size(), host) and vm.refused_op == 139, "executed unsupported opcode skipped")
