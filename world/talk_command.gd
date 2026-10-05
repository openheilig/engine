extends RefCounted
## Native primary KiTalk action10 (LGP sub_82EE0E8; ENG sub_529C60).
## Owns only a persistent command, not movement, views or scene nodes. Parent
## admits movement and calls tick once per simulation tick; only 'open' may
## invoke DialogueView. A click itself never opens a distant conversation.
const Actor := preload("res://world/actor_state.gd")
const RAW_PER_CELL := 53.66563
const MAX_TYPE := 32351
const INTEGER_FIELDS := ["hero_id", "target_id", "hero_body", "target_body"]
const MOVEMENT_STATES := ["idle", "queued", "moving", "arrived", "blocked", "cancelled"]

var weapons: RefCounted
## Immutable mounted item metadata: type -> (stamped descriptor row, category).
## The actor's equipped types live in the command, never inferred from names.
var _definitions: Dictionary[int, Vector2i] = {}
var hero_id := 0
var target_id := 0
var hero_body := 0
var target_body := 0
var _equipment := PackedInt32Array([0, 0, 0, 0])
var _approaching := false

func _init(weapon_reader: RefCounted) -> void:
	weapons = weapon_reader

func bind_definition(type: int, definition: PackedByteArray) -> String:
	if type < 1 or type > MAX_TYPE or definition.size() != 128:
		return "talk requires a valid normalized 128-byte item definition"
	_definitions[type] = Vector2i(definition.decode_u16(24), int(definition[46]))
	return ""

## sub_81988EC(actor,0): cWeapon3D objects +468/+472, raw descriptor byte30.
## Category13 is the explicit native exception (sub_813813A), not a guess
## that every nonzero hand item is an armed weapon.
func equipped_mode(first_type: int, second_type: int) -> Dictionary:
	if first_type == 0 and second_type == 0:
		return {"ok": true, "mode": 0}
	if weapons == null or not weapons.found:
		return {"ok": false, "error": "weapon descriptor table is unavailable"}
	if first_type < 0 or second_type < 0 or first_type > MAX_TYPE or second_type > MAX_TYPE:
		return {"ok": false, "error": "equipped item type is outside native bounds"}
	if first_type != 0 and not _definitions.has(first_type) or second_type != 0 and not _definitions.has(second_type):
		return {"ok": false, "error": "equipped normalized item definition is not bound"}
	var first_mode := int(weapons.mode(_definitions[first_type].x)) if first_type != 0 else 0
	var second_mode := int(weapons.mode(_definitions[second_type].x)) if second_type != 0 else 0
	if first_type != 0 and second_type != 0 and _definitions[first_type].y != 13:
		return {"ok": true, "mode": 8 if first_mode != 0 or second_mode != 0 else 0}
	var mode := second_mode if second_type != 0 else first_mode
	return {"ok": true, "mode": 12 if mode == 14 else mode}

## Exact body table sub_81D2472, independently matching ENG sub_4DBC60 and
## RUS sub_4DC070. The pair radius is the integer average, NOT the sum.
static func body_radius(body: int, equipped_weapon_mode: int) -> int:
	if body == 4 or body >= 274 and body <= 303:
		return 80 if equipped_weapon_mode == 0 else 110
	match body:
		1, 32, 33, 34, 38, 45, 48, 49, 50, 51, 192, 316, 699:
			return 100
		2, 37, 44, 182, 188, 194, 260, 307, 308, 315, 322, 670, 671, 689, 690:
			return 120
		5, 6, 333:
			return 70
		52, 74, 88, 100, 101, 102, 103:
			return 480
		55:
			return 420
		183:
			return 300
		187, 205, 206, 207, 208, 253, 254, 255, 202, 203, 204, 344, 350, 351, 352, 359:
			return 200
		190, 193, 348:
			return 170
		259:
			return 110
		_:
			return 130

## sub_8180522 reads stored live raw XY at actor+28/+32. ActorState.cell is
## continuous and already includes the cell centre; the +0.5 belongs only to
## CREATE from an authored integer cell, never to a live distance query.
static func native_position(cell: Vector2) -> Vector2i:
	return Vector2i(int(float(cell.x) * RAW_PER_CELL),
		int(float(cell.y) * RAW_PER_CELL))

## sub_8180522 + sub_864F50A: integer nearest sqrt, not a cell radius or
## unrounded float length. Deltas outside native bounds saturate at32000.
static func raw_distance(first: Vector2i, second: Vector2i) -> int:
	var dx := second.x - first.x
	var dy := second.y - first.y
	if dx > 32000 or dx < -32000 or dy > 32000 or dy < -32000:
		return 32000
	var remainder := dx * dx + dy * dy
	var root := 0
	var bit := 0x10000000
	while bit != 0:
		var trial := root + bit
		root >>= 1
		if trial <= remainder:
			remainder -= trial
			root += bit
		bit >>= 2
	return root + (1 if root < remainder else 0)

func pending() -> bool:
	return target_id != 0

## Inputs are native body IDs and equipped item TYPES, not RecordStore's
## high-bit geometry IDs. first/second equipment follows native +468/+472.
func request(hero: Actor, target: Actor, hero_body_id: int, target_body_id: int,
		hero_first: int, hero_second: int, npc_first: int, npc_second: int) -> Dictionary:
	_reset()
	if not _alive(hero) or not _alive(target) or hero.id <= 0 or target.id <= 0 or hero.id == target.id:
		return {"outcome": "error", "error": "talk requires distinct live actors"}
	if hero_body_id < 1 or hero_body_id > MAX_TYPE or target_body_id < 1 or target_body_id > MAX_TYPE:
		return {"outcome": "error", "error": "talk requires native body identities"}
	hero_id = hero.id
	target_id = target.id
	hero_body = hero_body_id
	target_body = target_body_id
	_equipment = PackedInt32Array([hero_first, hero_second, npc_first, npc_second])
	var range_result := _range()
	if not range_result["ok"]:
		return _finish("error", str(range_result["error"]))
	return {"outcome": "approach", "queued": true, "move": false,
		"hero_id": hero_id, "target_id": target_id, "stop_radius_raw": int(range_result["radius"])}

## 'arrived' means an admitted movement command successfully completed.
## Idle/queued is NOT completion; blocked/cancelled clears the native action.
## If an NPC moved away after the goal completed, re-approach its current
## position rather than treating stale path completion as permission to talk
## remotely. This preserves the caller's native action-cancellation boundary.
func tick(registry: Object, movement_state: String, bound_dialogue: bool,
		current_equipment: Array = [], hero_body_id: int = -1,
		target_body_id: int = -1) -> Dictionary:
	if not pending():
		return {"outcome": "cancelled", "reason": "no pending talk"}
	if not MOVEMENT_STATES.has(movement_state):
		return _finish("error", "unknown talk movement state")
	if movement_state in ["blocked", "cancelled"]:
		return _finish("cancelled", "movement did not complete")
	var hero: Actor = registry.get_actor(hero_id)
	var target: Actor = registry.get_actor(target_id)
	if not _alive(hero) or not _alive(target):
		return _finish("cancelled", "talk actor retired or died")
	if not bound_dialogue:
		return _finish("cancelled", "target has no current dialogue binding")
	if not hero.cell.is_finite() or not target.cell.is_finite():
		return _finish("error", "talk actor position is not finite")
	if not current_equipment.is_empty():
		if current_equipment.size() != 4:
			return _finish("error", "talk equipment requires four item types")
		for type in current_equipment:
			if not _integer(type) or int(type) < 0 or int(type) > MAX_TYPE:
				return _finish("error", "talk equipment type is invalid")
		_equipment = PackedInt32Array(current_equipment)
	if hero_body_id != -1:
		hero_body = hero_body_id
	if target_body_id != -1:
		target_body = target_body_id
	if hero_body < 1 or hero_body > MAX_TYPE or target_body < 1 or target_body > MAX_TYPE:
		return _finish("error", "current native body identity is invalid")
	var range_result := _range()
	if not range_result["ok"]:
		return _finish("error", str(range_result["error"]))
	var radius := int(range_result["radius"])
	var distance := raw_distance(native_position(hero.cell), native_position(target.cell))
	var admission := (3 * radius) >> 1
	if not _approaching and distance <= admission:
		return _finish("open", "")
	if _approaching and (distance < radius or movement_state == "arrived" and distance <= admission):
		return _finish("open", "")
	_approaching = true
	return {"outcome": "approach", "queued": false, "move": true,
		"hero_id": hero_id, "target_id": target_id, "cell": target.cell,
		"stop_radius_raw": radius, "stop_radius_cells": float(radius) / RAW_PER_CELL,
		"distance_raw": distance}

func cancel() -> Dictionary:
	return _finish("cancelled", "talk command superseded")

func _range() -> Dictionary:
	var hero_mode := equipped_mode(_equipment[0], _equipment[1])
	if not hero_mode["ok"]:
		return hero_mode
	var npc_mode := equipped_mode(_equipment[2], _equipment[3])
	if not npc_mode["ok"]:
		return npc_mode
	return {"ok": true, "radius": (body_radius(hero_body, int(hero_mode["mode"]))
		+ body_radius(target_body, int(npc_mode["mode"]))) >> 1}

static func _alive(actor: Actor) -> bool:
	return actor != null and actor.hp > 0 and (actor.flags & Actor.FLAG_ALIVE) != 0

func _finish(outcome: String, reason: String) -> Dictionary:
	var result := {"outcome": outcome, "hero_id": hero_id, "target_id": target_id}
	if not reason.is_empty():
		result["error" if outcome == "error" else "reason"] = reason
	_reset()
	return result

func _reset() -> void:
	hero_id = 0
	target_id = 0
	hero_body = 0
	target_body = 0
	_equipment.fill(0)
	_approaching = false

func snapshot() -> Dictionary:
	return {"hero_id": hero_id, "target_id": target_id, "hero_body": hero_body,
		"target_body": target_body, "equipment": Array(_equipment), "approaching": _approaching}

static func _integer(value: Variant) -> bool:
	return value is int or value is float and is_finite(value) and value == floor(value) \
		and value >= -9223372036854775808.0 and value < 9223372036854775808.0

## Parent checks incoming registry IDs before replacing ANY live session state.
func validate_snapshot(state: Dictionary, actor_ids: PackedInt64Array) -> String:
	for field in INTEGER_FIELDS:
		if not _integer(state.get(field)) or int(state[field]) < 0:
			return "invalid talk %s" % field
	var equipment: Variant = state.get("equipment")
	if not equipment is Array or equipment.size() != 4 or not state.get("approaching") is bool:
		return "invalid talk equipment/phase"
	for type in equipment:
		if not _integer(type) or int(type) < 0 or int(type) > MAX_TYPE:
			return "invalid talk equipped type"
	var incoming_hero := int(state["hero_id"])
	var incoming_target := int(state["target_id"])
	if incoming_target == 0:
		if incoming_hero != 0 or int(state["hero_body"]) != 0 or int(state["target_body"]) != 0 or bool(state["approaching"]) or equipment.any(func(type: Variant) -> bool: return int(type) != 0):
			return "inactive talk command contains pending state"
		return ""
	if incoming_hero == incoming_target or not actor_ids.has(incoming_hero) or not actor_ids.has(incoming_target):
		return "pending talk actor is absent from registry"
	if int(state["hero_body"]) < 1 or int(state["hero_body"]) > MAX_TYPE or int(state["target_body"]) < 1 or int(state["target_body"]) > MAX_TYPE:
		return "invalid pending talk body identity"
	return ""

func restore(state: Dictionary, actor_ids: PackedInt64Array) -> String:
	var error := validate_snapshot(state, actor_ids)
	if not error.is_empty():
		return error
	hero_id = int(state["hero_id"])
	target_id = int(state["target_id"])
	hero_body = int(state["hero_body"])
	target_body = int(state["target_body"])
	_equipment = PackedInt32Array(state["equipment"])
	_approaching = bool(state["approaching"])
	return ""
