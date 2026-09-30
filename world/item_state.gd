class_name ItemInstances
extends RefCounted
## C2 foundation: the INSTANCE half of OpenMW's split. `formats/items.gd`
## stays the immutable DEFINITION reader (records in items.pak are shared,
## read-only); this class owns the mutable per-instance state -- which copy
## of a definition exists, where it is, and who owns it. Two instances of
## one definition are distinct objects (with distinct future rolls; the
## rolls themselves are the ITEM gate's, deliberately absent here: v1
## spawns carry no modifiers rather than invented ones).
##
## ID CONTRACT (mirrors ActorRegistry's): instance ids are MONOTONIC ints
## allocated by spawn(), never reused by despawn(). A stale instance id
## resolves to null forever.
##
## LOCATION MODEL (v1): GROUND (at a world cell), INVENTORY (owned by an
## actor), EQUIPPED (owned by an actor, named slot index). Transfers are
## transactional -- validate, then mutate; a refused transfer changes
## nothing.
##
## Stacking is deliberately absent: which categories stack is a retail fact
## the ITEM gate must observe first. v1 instances are always quantity 1 --
## a wrong stack merge would silently destroy items.

enum Location { GROUND, INVENTORY, EQUIPPED, GONE }

## One mutable item instance. `definition_id` indexes items.pak (the
## immutable half); everything else is this copy's own state.
class Instance extends RefCounted:
	var instance_id: int = 0
	var definition_id: int = 0
	var location: int = Location.GONE
	var owner_id: int = 0            ## actor id for INVENTORY/EQUIPPED, else 0
	var cell := Vector2i.ZERO        ## world cell for GROUND, else ZERO
	var slot: int = -1               ## equipped slot index for EQUIPPED, else -1

	func to_dict() -> Dictionary:
		return {"instance_id": instance_id, "definition_id": definition_id,
			"location": location, "owner_id": owner_id,
			"cell_x": cell.x, "cell_y": cell.y, "slot": slot}

	static func from_dict(d: Dictionary) -> Instance:
		var i := Instance.new()
		i.instance_id = int(d["instance_id"])
		i.definition_id = int(d["definition_id"])
		i.location = int(d["location"])
		i.owner_id = int(d["owner_id"])
		i.cell = Vector2i(int(d["cell_x"]), int(d["cell_y"]))
		i.slot = int(d["slot"])
		return i

	func duplicate() -> Dictionary:
		return to_dict()


var _next_id: int = 1
var _by_id: Dictionary[int, Instance] = {}


## Spawns a fresh instance of `definition_id` at a world cell. Returns the
## new instance id (monotonic, never reused).
func spawn(definition_id: int, at: Vector2i) -> int:
	var id := _next_id
	_next_id += 1
	assert(_by_id.is_empty() or id > _by_id.keys().max(),
		"ItemInstances: ids must stay strictly ascending")
	var i := Instance.new()
	i.instance_id = id
	i.definition_id = definition_id
	i.location = Location.GROUND
	i.cell = at
	_by_id[id] = i
	return id


## The instance for `id`, or null for an unknown/despawned id.
func instance(id: int) -> Instance:
	return _by_id.get(id, null)


## Moves `id` to a new location/owner. Transactional: an invalid transfer
## (unknown instance, unequippable-to-nonexistent owner) returns a reason
## and mutates nothing. GROUND transfers take the world cell in `at`.
func transfer(id: int, to: int, owner_or_zero: int, slot: int = -1,
		at: Vector2i = Vector2i.ZERO) -> String:
	var i: Instance = _by_id.get(id, null)
	if i == null:
		return "unknown instance %d" % id
	match to:
		Location.GROUND:
			pass
		Location.INVENTORY, Location.EQUIPPED:
			if owner_or_zero <= 0:
				return "location %d needs a positive owner" % to
			if to == Location.EQUIPPED and slot < 0:
				return "EQUIPPED needs a slot index"
		_:
			return "unknown target location %d" % to
	i.location = to
	i.owner_id = owner_or_zero
	i.slot = slot if to == Location.EQUIPPED else -1
	i.cell = at if to == Location.GROUND else Vector2i.ZERO
	return ""


## Removes an instance. The id is never reissued.
func despawn(id: int) -> void:
	_by_id.erase(id)


func count() -> int:
	return _by_id.size()


## Every live instance (any location), id order. Read-only use.
func all_instances() -> Array:
	return _by_id.values()


func next_id() -> int:
	return _next_id


## P1 schema-v2 fragment: every instance as a dict, id order. `from_snapshot`
## is the counterpart.
func snapshot() -> Array:
	var out: Array = []
	for id in _by_id.keys():
		out.append(_by_id[id].to_dict())
	return out


## P1 schema-v2 fragment counterpart: rebuilds the container with the
## snapshot's ids EXACTLY (despawned ids stay retired -- the gap is part of
## the id history), and the watermark moves above the highest restored id.
static func from_snapshot(arr: Array) -> ItemInstances:
	var items := ItemInstances.new()
	items._by_id.clear()
	var highest := 0
	for d in arr:
		var i := Instance.from_dict(d)
		items._by_id[i.instance_id] = i
		if i.instance_id > highest:
			highest = i.instance_id
	items._next_id = highest + 1
	return items
