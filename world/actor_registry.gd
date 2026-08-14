class_name ActorRegistry
extends RefCounted
## Owns every living actor's ActorState, keyed by a process-lifetime int id.
##
## ACTOR HANDLE DECISION (Phase 1, Plan 01, Task 1 -- full rationale and
## rejected alternatives in the project decision record (kept off this repo), "Actor Handle Decision"):
## the actor id is a MONOTONIC int allocated by spawn(), NEVER reused by
## despawn(). A stale handle therefore resolves to null forever -- it can
## never alias a different, later actor. Ids are already totally ordered, so
## R10.3's composite simulation sort key needs no extra tiebreaker beyond the
## id itself. Rejected: a packed (index, generation) handle -- unpacking cost
## on every dump/diff, and slot reuse makes the index half ambiguous on its
## own, the very aliasing bug this decision exists to prevent -- and a
## (sector, index) composite handle, which makes identity a function of
## position, the anti-pattern this whole phase is named after.
##
## This object is constructed exactly ONCE, in main.gd._ready(). It is NEVER
## added to the scene tree and NEVER referenced from any sector-building code
## path. OpenMW's own wiki records the equivalent coupling as "a design flaw
## ... that could not be fixed anymore without a total rewrite" (ROADMAP.md,
## Phase 1). main.gd's streamer queue_free's sector MeshInstance3Ds on
## backtrack (_stream / _add_sector); an actor parented to one of them would
## be destroyed with it. Registry-owned RefCounted state cannot be, because
## nothing here is ever a child of anything the streamer frees.
##
## LAYERING (01-03 task 3, godot-port/verify.gd _layer_check): this file must
## never call Node3D, add_child, or queue_free in real code -- the three
## tokens named here, in prose, on purpose, to prove the checker strips
## comments rather than merely never seeing these words.

const INVALID_ID := 0
const MAX_ACTORS := 4096

var _next_id: int = 1
var _by_id: Dictionary[int, ActorState] = {}
var _ids: PackedInt64Array = PackedInt64Array()   ## strictly ascending -- canonical simulation order


## Allocates the next id, stores a new ActorState, returns the id. At
## MAX_ACTORS this push_errors naming the cap and returns INVALID_ID; it
## never evicts -- a silently vanishing actor is the failure mode this class
## exists to prevent.
func spawn(record_id: int, cell: Vector2, hp: int, hp_max: int) -> int:
	if _ids.size() >= MAX_ACTORS:
		push_error("ActorRegistry.spawn: MAX_ACTORS (%d) reached, refusing to spawn" % MAX_ACTORS)
		return INVALID_ID
	var id := _next_id
	_next_id += 1
	# Ids are monotonic, so append preserves strict ascending order -- assert
	# it rather than silently trust it.
	assert(_ids.is_empty() or id > _ids[-1], "ActorRegistry: ids must stay strictly ascending")
	_ids.append(id)
	var a := ActorState.new()
	a.id = id
	a.record_id = record_id
	a.cell = cell
	a.hp = hp
	a.hp_max = hp_max
	a.flags = ActorState.FLAG_ALIVE
	_by_id[id] = a
	return id


## null for an unknown id.
func get_actor(id: int) -> ActorState:
	return _by_id.get(id, null)


## No-op on an unknown id. _next_id is never rewound, so a retired id is
## never reissued.
func despawn(id: int) -> void:
	if not _by_id.has(id):
		return
	_by_id.erase(id)
	var i := _ids.bsearch(id)
	if i < _ids.size() and _ids[i] == id:
		_ids.remove_at(i)


func count() -> int:
	return _ids.size()


## Strictly ascending -- this is the canonical simulation order.
func ids() -> PackedInt64Array:
	return _ids


func next_id() -> int:
	return _next_id


## Ids within `r` of `centre`, ascending order preserved (== _ids' own
## order, since this filters _ids in place rather than rebuilding it).
## Boundary is INCLUSIVE (<=) -- a decision, not an accident.
func in_radius(centre: Vector2, r: float) -> PackedInt64Array:
	var r2 := r * r
	var out := PackedInt64Array()
	for id in _ids:
		var a: ActorState = _by_id[id]
		if centre.distance_squared_to(a.cell) <= r2:
			out.append(id)
	return out


## Appends every actor's dump_line() in ascending id order, then one trailing
## "registry\tcount=<n>\tnext=<next_id>" line.
func dump(out: Array[String]) -> void:
	for id in _ids:
		var a: ActorState = _by_id[id]
		out.append(a.dump_line())
	out.append("registry\tcount=%d\tnext=%d" % [count(), _next_id])
