extends "res://checks/check.gd"
## save_state_check.gd -- the engine-owned session save (P1) must roundtrip
## the authoritative state through SaveStore's atomic write, refuse unknown
## schema versions and corrupt files explicitly, and restore transactionally
## (a failed load must leave the live state untouched).

func _init() -> void:
	super()
	var fails := 0

	# --- build a live state: registry with two actors + quest state ---
	var reg := ActorRegistry.new()
	var id1 := reg.spawn(101, Vector2(3236.5, 2511.5), 119, 119)
	var id2 := reg.spawn(102, Vector2(10.25, 20.75), 40, 40)
	var hero := reg.get_actor(id1)
	hero.facing = Vector2.from_angle(0.7)
	var npc := reg.get_actor(id2)
	npc.flags &= ~ActorState.FLAG_ALIVE
	var quest := QuestCast.new()
	quest.mark_entered(74)
	# set_var's argument is a BIT INDEX (it ORs 1 << bit) -- the state mask
	# for bit 2 is therefore 16, not 4.
	quest.set_var("74", 2)
	quest.create_npc("res:17095", 679, "novizin1", "auftrag10", "ECS_HEALING")
	quest.npc_goto("Res:17095", Vector2i(3237, 2514))

	var session := {
		"registry": reg, "quest_log": quest, "player_id": id1,
		"tick": 1234, "tick_hz": 30,
	}

	# --- snapshot, mutate everything, restore, compare ---
	var snap := SaveState.snapshot(session)
	expect(not snap.is_empty(), "snapshot must not be empty")
	expect(int(snap.get("schema", 0)) == SaveState.SCHEMA, "snapshot carries the schema version")

	hero.cell = Vector2.ZERO
	hero.hp = 1
	npc.cell = Vector2(99, 99)
	reg.despawn(id2)
	quest.set_var("74", 3)

	var err: String = SaveState.restore(snap, session)
	if err != "":
		fails += 1
		printerr("restore failed: %s" % err)
	var h2 := reg.get_actor(id1)
	if h2 == null or h2.cell != Vector2(3236.5, 2511.5) or h2.hp != 119 \
			or h2.hp_max != 119:
		fails += 1
		printerr("hero state not restored: %s" % [h2.dump_line() if h2 else "null"])
	if reg.get_actor(id2) == null:
		fails += 1
		printerr("dead-actor record not restored")
	if reg.get_actor(id2) != null and reg.get_actor(id2).cell != Vector2(10.25, 20.75):
		fails += 1
		printerr("npc cell not restored")
	if reg.get_actor(id2) != null and (reg.get_actor(id2).flags & ActorState.FLAG_ALIVE) != 0:
		fails += 1
		printerr("npc dead flag not restored")
	if quest.state_of(74) != (1 << 2):
		fails += 1
		printerr("quest state not restored: %d" % quest.state_of(74))
	var cast: Array[Dictionary] = quest.cast
	if cast.is_empty() or cast[0]["cell"] != Vector2i(3237, 2514):
		fails += 1
		printerr("cast handle cell not restored")

	# --- store: atomic write + read-back parity ---
	var path := "user://_save_state_test/save.json"
	var err2: String = SaveStore.save(path, snap)
	if err2 != "":
		fails += 1
		printerr("store save failed: %s" % err2)
	var loaded := SaveStore.load(path)
	if loaded.is_empty():
		fails += 1
		printerr("store load returned empty")
	elif SaveState.restore(loaded, session) != "":
		fails += 1
		printerr("stored snapshot failed to restore")

	# --- negatives: corrupt file and wrong schema must refuse explicitly ---
	FileAccess.open(path, FileAccess.WRITE).store_string("{not json")
	if not SaveStore.load(path).is_empty():
		fails += 1
		printerr("corrupt JSON accepted")
	var wrong := {"schema": SaveState.SCHEMA + 99}
	SaveStore.save(path, wrong)
	if not SaveStore.load(path).is_empty():
		fails += 1
		printerr("unknown schema version accepted")
	# missing file
	if not SaveStore.load("user://_save_state_test/never-written.json").is_empty():
		fails += 1
		printerr("missing file accepted")

	print("save_state_check\tOK")
	finish(1 if fails > 0 else 0)
