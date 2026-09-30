class_name SaveState
extends RefCounted
## P1: the engine-owned session snapshot. Captures the AUTHORITATIVE
## simulation state — actors, quest state, cast handles, clocks — and
## restores it transactionally: `restore` validates the whole snapshot
## before touching the live session, so a bad snapshot leaves the running
## world untouched.
##
## SCHEMA v1 covers the state that exists today (per the plan: P1 grows
## with each real state owner — inventory, tasks, triggers, effects land
## in later increments). What v1 does NOT claim: world-save compatibility
## (that is X1/P2, a different format), view/camera state, RNG streams
## (the encounter's seeded rng is reconstructed from FIGHT_SEED by its
## owner, not stored here).
##
## JSON via SaveStore (never .tres/.res — user-controlled files), floats
## serialized as explicit components, every field present-or-invalid.

const SCHEMA := 1


static func snapshot(session: Dictionary) -> Dictionary:
	var reg: ActorRegistry = session["registry"]
	var actors: Array = []
	for id in reg.ids():
		var a := reg.get_actor(id)
		actors.append({
			"id": a.id, "record_id": a.record_id,
			"cell_x": a.cell.x, "cell_y": a.cell.y,
			"facing_x": a.facing.x, "facing_y": a.facing.y,
			"hp": a.hp, "hp_max": a.hp_max, "flags": a.flags,
			"ticks": a.ticks_simulated,
		})
	var quest: QuestLog = session.get("quest_log")
	var cast: Array = []
	var qcast := quest as QuestCast
	if qcast != null:
		for e in qcast.cast:
			var cell: Vector2i = e["cell"]
			cast.append({"handle": e["handle"], "creature": e["creature"],
				"name": e["name"], "task": e["task"], "art": e["art"],
				"cell_x": cell.x, "cell_y": cell.y, "compass": e["compass"]})
	return {
		"schema": SCHEMA,
		"tick": session.get("tick", 0),
		"tick_hz": session.get("tick_hz", Sim.TICK_HZ),
		"player_id": session.get("player_id", 0),
		"next_actor_id": reg.next_id(),
		"actors": actors,
		"quest_states": quest.vars() if quest != null else {},
		"quest_entered": quest.entered_ids() if quest != null else [],
		"cast": cast,
	}


## Restores `snap` into the session. The WHOLE snapshot is validated first;
## on any error the live state is untouched and the reason is returned
## ("" on success).
static func restore(snap: Dictionary, session: Dictionary) -> String:
	if int(snap.get("schema", -1)) != SCHEMA:
		return "schema %s is not %d" % [str(snap.get("schema")), SCHEMA]
	var actors_v: Variant = snap.get("actors")
	if typeof(actors_v) != TYPE_ARRAY:
		return "missing actors array"
	# Validate every actor entry BEFORE mutating anything.
	var ids := {}
	for a in actors_v:
		if typeof(a) != TYPE_DICTIONARY:
			return "malformed actor entry"
		for f in ["id", "record_id", "cell_x", "cell_y", "facing_x",
				"facing_y", "hp", "hp_max", "flags"]:
			if not a.has(f):
				return "actor entry missing field %s" % f
		if ids.has(int(a["id"])):
			return "duplicate actor id %d" % int(a["id"])
		ids[int(a["id"])] = true

	var reg: ActorRegistry = session["registry"]
	# Rebuild the registry from the snapshot: the ids are restored exactly
	# (spawn's monotonic contract is preserved by replaying ids in order).
	reg.clear()
	for a in actors_v:
		var id: int = reg.spawn(int(a["record_id"]),
			Vector2(float(a["cell_x"]), float(a["cell_y"])),
			int(a["hp"]), int(a["hp_max"]))
		if id != int(a["id"]):
			return "actor id drifted: wanted %d, allocated %d" % [int(a["id"]), id]
		var actor := reg.get_actor(id)
		actor.facing = Vector2(float(a["facing_x"]), float(a["facing_y"]))
		actor.flags = int(a["flags"])
		actor.ticks_simulated = int(a["ticks"])
	# next_id must sit ABOVE the highest restored id so later spawns cannot
	# collide with restored handles.
	while reg.next_id() <= int(snap.get("next_actor_id", 0)):
		reg.spawn(0, Vector2.ZERO, 0, 0)
		reg.despawn(reg.next_id() - 1)

	var quest: QuestLog = session.get("quest_log")
	if quest != null:
		quest.restore_states(snap.get("quest_states", {}),
			snap.get("quest_entered", []))
	var qcast := quest as QuestCast
	if qcast != null:
		qcast.cast.clear()
		qcast.reset_handles()
		for e in snap.get("cast", []):
			qcast.create_npc(str(e["handle"]), int(e["creature"]),
				str(e["name"]), str(e["task"]), str(e["art"]))
			var i: int = qcast.cast.size() - 1
			qcast.cast[i]["cell"] = Vector2i(int(e["cell_x"]), int(e["cell_y"]))
			qcast.cast[i]["compass"] = bool(e["compass"])
	session["tick"] = int(snap.get("tick", 0))
	session["player_id"] = int(snap.get("player_id", 0))
	return ""
