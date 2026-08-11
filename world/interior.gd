class_name Interior
extends RefCounted
## Deterministic building-swap state derived from the focus actor's cell.
##
## Nothing in this file references a node type, the scene tree or the camera.
## Every region and object footprint is read straight from Sacred.World's own
## sector streams, never from anything SectorView happens to have loaded -- a
## streamer's resident set must not become simulation input.

enum State { EXTERIOR, INTERIOR }

## 06-02 rows 625-626 measured the chapel trigger 3-6 cells out; six is the
## conservative measured bound. Relevance therefore needs only the actor's own
## and neighbouring sectors, plus already-active regions so exit is observed.
const APPROACH_CELLS := 6
const SECTOR_RADIUS := 1

var _world: Sacred.World
var _walk: Walkable
var _footprints: Sacred.Footprints
var _sector_cache: Dictionary = {}   ## gy*100+gx -> Dictionary or null (cached miss)
var _states: Dictionary = {}         ## packed gx,gy,index -> State
var _regions: Dictionary = {}        ## packed key -> resolved footprint
var _last_changes: Array = []


func _init(world: Sacred.World, walk: Walkable, footprints: Sacred.Footprints) -> void:
	_world = world
	_walk = walk
	_footprints = footprints


## Derives every nearby footprint from one actor cell. Dictionary iteration is
## never output order: candidate keys and transitions are sorted numerically.
##
## ponytail: visited EXTERIOR entries are retained forever. A long session thus
## grows by one state/footprint per visited building; the upgrade path is
## deterministic eviction on sector unload once simulation owns such an event.
func derive(cell: Vector2) -> void:
	_last_changes = []
	var ci := Vector2i(floori(cell.x), floori(cell.y))
	var sx := floori(float(ci.x) / float(Sacred.SECT))
	var sy := floori(float(ci.y) / float(Sacred.SECT))
	var candidates: Dictionary = {}
	for dy in range(-SECTOR_RADIUS, SECTOR_RADIUS + 1):
		var gy := sy + dy
		if gy < 0 or gy >= 100:
			continue
		for dx in range(-SECTOR_RADIUS, SECTOR_RADIUS + 1):
			var gx := sx + dx
			if gx < 0 or gx >= 100:
				continue
			var resolved: Variant = _footprints_for(gx, gy)
			if resolved == null:
				continue
			var indices: Array = resolved.keys()
			indices.sort()
			for index: int in indices:
				var key := _region_key(gx, gy, index)
				candidates[key] = resolved[index]
		# A footprint that was INTERIOR remains relevant until this same
		# predicate observes its symmetric false edge. Otherwise walking more
		# than one sector away could strand it in INTERIOR forever.
	for key: int in _states:
		if _states[key] == State.INTERIOR and _regions.has(key):
			candidates[key] = _regions[key]
	var keys: Array = candidates.keys()
	keys.sort()
	for key: int in keys:
		var region: Dictionary = candidates[key]
		_regions[key] = region
		var next := State.INTERIOR if _triggered(cell, key, region) else State.EXTERIOR
		var previous: int = _states.get(key, State.EXTERIOR)
		if next != previous:
			_last_changes.append({
				"key": key, "from": previous, "to": next,
				"family": region.get("family", ""),
			})
		_states[key] = next


func current() -> Dictionary:
	return _states.duplicate()


func last_changes() -> Array:
	return _last_changes.duplicate(true)


## The ONE trigger predicate. It implements 06-02 findings rows 625-626:
## - ON a DOOR cell at the OZELT1 tent (row 625), and on its connected STEP /
##   navigable interior cells;
## - on the chapel door's approach path 3-6 cells out (row 626, +/-2-cell
##   positional bound), represented as a width-2 corridor projected outward
##   from each DOOR/STEP entrance cell;
## - never on mere wall proximity (row 625's north/east-wall negative runs).
## Exit is this exact predicate becoming false -- no separate exit heuristic.
func _triggered(cell: Vector2, _region_key_value: int, region: Dictionary) -> bool:
	var ci := Vector2i(floori(cell.x), floori(cell.y))
	var anchor: Vector2i = region["anchor"]
	var size: Vector2i = region["size"]
	var source: Dictionary = region["region"]
	var local := ci - anchor
	if local.x >= 0 and local.y >= 0 and local.x < size.x and local.y < size.y:
		var own_class := Sacred.Regions.cell_class(source, local.x, local.y)
		if Walkable.class_is_open(own_class):
			return true

	var centre := Vector2(anchor) + Vector2(size) * 0.5
	for y in size.y:
		for x in size.x:
			var cls := Sacred.Regions.cell_class(source, x, y)
			if cls != Sacred.Regions.DOOR and cls != Sacred.Regions.STEP:
				continue
			var entrance := anchor + Vector2i(x, y)
			var delta := ci - entrance
			if maxi(absi(delta.x), absi(delta.y)) > APPROACH_CELLS:
				continue
			var outward := (Vector2(entrance) + Vector2(0.5, 0.5) - centre).normalized()
			if outward == Vector2.ZERO:
				continue
			var along := Vector2(delta).dot(outward)
			if along < 0.0 or along > float(APPROACH_CELLS):
				continue
			var sideways := absf(Vector2(delta).cross(outward))
			if sideways <= 2.0:
				return true
	return false


func _footprints_for(gx: int, gy: int) -> Variant:
	var sector_key := gy * 100 + gx
	if _sector_cache.has(sector_key):
		return _sector_cache[sector_key]
	var resolved: Variant = null
	if _world != null and _footprints != null and _world.has_sector(gx, gy):
		var stream := _world.sector(gx, gy)
		if not stream.is_empty():
			resolved = _footprints.resolve(stream, gx, gy)
	_sector_cache[sector_key] = resolved   # cache misses too
	return resolved


static func _region_key(gx: int, gy: int, index: int) -> int:
	return gx * 1000000 + gy * 1000 + index


static func unpack_region_key(key: int) -> Vector3i:
	var gx := key / 1000000
	var rest := key - gx * 1000000
	return Vector3i(gx, rest / 1000, rest % 1000)


static func state_name(state: int) -> String:
	return "INTERIOR" if state == State.INTERIOR else "EXTERIOR"
