class_name ScenarioCheckpoint
extends RefCounted
## THE SEMANTIC CHECKPOINT, E1's contract in one class: the machine-readable
## statement of "the world is in the state the scenario describes", written to
## a JSON sidecar beside every capture, compared on capture, and written by
## default -- never opt-in -- so a run without it cannot silently become a
## benchmark run.
##
## WHAT GOES IN. Authoritative simulation values ONLY, read from the same
## structures the simulation reads them from. Never a camera position, never
## a resident-sector count, never a frame timestamp, never a renderer count:
## those are exactly the loading-dependent quantities that made the old
## loading-relative capture refuse its own repeats (2702 differing
## actor-region pixels, 2026-09-29 audit §5). One keyed field of those is
## still allowed, deliberately: `anim_clip_time` records WHICH FRAME of an
## animation the capture froze, so two captures of an animating body can be
## compared as the same pose rather than refused as different worlds.
##
## WHAT "DONE" MEANS. Production code that moved the world writes a fact line
## (the house convention); this class writes the sidecar. A run that never
## calls world_moved() has no business passing a capture comparison, and
## write() records that emptiness explicitly rather than omitting it.
##
## SCHEMA VERSION 1. Bump on any field change; the comparison refuses a
## mismatched pair outright rather than diffing unequal schemas.

const SCHEMA := 1

## The scenario identity: content set + route + checkpoint name. Two captures
## compare only when this whole triple matches -- "same script, same state"
## is the unit, not "same milliseconds".
var scenario := ""
var route := ""
var checkpoint := ""

## Simulation values, set by the production path as it reaches them.
var sim_tick := -1                ## Sim.tick at the checkpoint; -1 = never set
var player_cell := Vector2.INF    ## authoritative cell, Vector2.INF = never set
var player_facing := Vector2.INF
var player_hp := -1
var player_hp_max := -1
var player_flags := -1
var next_actor_id := -1
var actor_count := -1
## res:-handle -> creature id for every scripted cast entry the hook created,
## in creation order. The identity question E1 exists to answer.
var cast_handles := {}
## quest id -> state mask (the bytecode's own bit array), for every quest the
## run touched.
var quest_states := {}
var quest_lines := -1
var anim_clip_name := ""          ## "" = not animated / not recorded
var anim_clip_time := NAN         ## NAN = not recorded; compared with an epsilon, not equality


## One production call site, at the moment the world is where the scenario
## wants it. Everything authoritative is read HERE, from the live objects --
## never passed in as arguments, so a caller cannot checkpoint a stale copy.
func capture(host) -> void:
	scenario = host._scenario_name
	route = host._scenario_route
	checkpoint = host._scenario_checkpoint
	sim_tick = host._sim.tick
	var p = host._registry.get_actor(host._player_id)
	if p != null:
		player_cell = p.cell
		player_facing = p.facing
		player_hp = p.hp
		player_hp_max = p.hp_max
		player_flags = p.flags
	next_actor_id = host._registry.next_id()
	actor_count = host._registry.count()
	for e: Dictionary in host._cast_snapshot():
		cast_handles[e["handle"]] = e["creature"]
	if host._quest_log != null:
		quest_states = host._quest_log.vars()
		quest_lines = host._quest_log.lines.size()
	var mv = host._anim_clip_state()
	anim_clip_name = mv["name"]
	anim_clip_time = mv["time"]


func to_dict() -> Dictionary:
	return {"schema": SCHEMA, "scenario": scenario, "route": route,
		"checkpoint": checkpoint, "sim_tick": sim_tick,
		"player_cell": _vec(player_cell), "player_facing": _vec(player_facing),
		"player_hp": player_hp, "player_hp_max": player_hp_max,
		"player_flags": player_flags, "next_actor_id": next_actor_id,
		"actor_count": actor_count, "cast_handles": cast_handles,
		"quest_states": quest_states, "quest_lines": quest_lines,
		"anim_clip_name": anim_clip_name, "anim_clip_time": anim_clip_time}


static func from_dict(d: Dictionary) -> ScenarioCheckpoint:
	var c := ScenarioCheckpoint.new()
	if int(d.get("schema", -1)) != SCHEMA:
		return null
	c.scenario = str(d.get("scenario", ""))
	c.route = str(d.get("route", ""))
	c.checkpoint = str(d.get("checkpoint", ""))
	c.sim_tick = int(d.get("sim_tick", -1))
	c.player_cell = _unvec(d.get("player_cell", ""))
	c.player_facing = _unvec(d.get("player_facing", ""))
	c.player_hp = int(d.get("player_hp", -1))
	c.player_hp_max = int(d.get("player_hp_max", -1))
	c.player_flags = int(d.get("player_flags", -1))
	c.next_actor_id = int(d.get("next_actor_id", -1))
	c.actor_count = int(d.get("actor_count", -1))
	var ch: Dictionary = {}
	for k: String in d.get("cast_handles", {}):
		ch[k] = int(d["cast_handles"][k])
	c.cast_handles = ch
	var qs: Dictionary = {}
	for k: String in d.get("quest_states", {}):
		qs[k] = int(d["quest_states"][k])
	c.quest_states = qs
	c.quest_lines = int(d.get("quest_lines", -1))
	c.anim_clip_name = str(d.get("anim_clip_name", ""))
	c.anim_clip_time = float(d.get("anim_clip_time", NAN))
	return c


## Writes the sidecar. Returns the error string, "" on success -- the caller
## prints it in the house fact-line shape and treats a failure as fatal.
func save(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "cannot open %s (%s)" % [path, error_string(FileAccess.get_open_error())]
	f.store_string(JSON.stringify(to_dict(), "\t"))
	f.close()
	return ""


## THE COMPARISON. Deterministic channels must match exactly; the animation
## pose may differ by a bounded epsilon because two wall-clock runs cannot
## freeze the same frame of a looping clip. Every difference is named.
## Returns "" when the two checkpoints agree, else the reason they do not.
func compare_against(other: ScenarioCheckpoint, anim_eps := 0.05) -> String:
	if other == null:
		return "reference checkpoint missing or wrong schema"
	for field in ["scenario", "route", "checkpoint", "sim_tick", "player_hp",
			"player_hp_max", "player_flags", "next_actor_id", "actor_count",
			"quest_lines", "anim_clip_name"]:
		if get(field) != other.get(field):
			return "%s differs: %s vs %s" % [field, get(field), other.get(field)]
	if player_cell.distance_squared_to(other.player_cell) > 1e-9:
		return "player_cell differs: %s vs %s" % [player_cell, other.player_cell]
	if player_facing.distance_squared_to(other.player_facing) > 1e-9:
		return "player_facing differs: %s vs %s" % [player_facing, other.player_facing]
	if cast_handles != other.cast_handles:
		return "cast_handles differ: %s vs %s" % [cast_handles, other.cast_handles]
	if quest_states != other.quest_states:
		return "quest_states differ: %s vs %s" % [quest_states, other.quest_states]
	if not (anim_clip_time == other.anim_clip_time \
			or (not is_nan(anim_clip_time) and not is_nan(other.anim_clip_time)
				and absf(anim_clip_time - other.anim_clip_time) <= anim_eps)):
		return "anim_clip_time differs beyond %.3fs: %s vs %s" % [
			anim_eps, anim_clip_time, other.anim_clip_time]
	return ""


static func _vec(v: Vector2) -> String:
	return "%.6f,%.6f" % [v.x, v.y] if v.is_finite() else "unset"


static func _unvec(s) -> Vector2:
	var t := str(s).split(",")
	if t.size() != 2:
		return Vector2.INF
	return Vector2(float(t[0]), float(t[1]))
