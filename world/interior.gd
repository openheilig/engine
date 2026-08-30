class_name Interior
extends RefCounted
## Deterministic building-swap state derived from the focus actor's cell.
##
## Nothing in this file references a node type, the scene tree or the camera.
## Every region and object footprint is read straight from Sacred.World's own
## sector streams, never from anything SectorView happens to have loaded -- a
## streamer's resident set must not become simulation input.

enum State { EXTERIOR, INTERIOR }

## Retained only as the outward search bound used by main.gd's
## _exterior_destination / door_transition_check: how far outside a footprint a
## caller must look to find a cell the trigger predicate no longer fires on.
## It is NOT a trigger radius any more -- rows 670-676 established the retail
## trigger is the hero's OWN cell class, with no approach corridor at all.
const APPROACH_CELLS := 6
const SECTOR_RADIUS := 1

var _world: Sacred.World
var _walk: Walkable
var _footprints: Sacred.Footprints
var _sector_cache: Dictionary = {}   ## gy*100+gx -> Dictionary or null (cached miss)
var _states: Dictionary = {}         ## packed gx,gy,index -> State
var _regions: Dictionary = {}        ## packed key -> resolved footprint
var _last_changes: Array = []
var _remembered: Array = []          ## keys of the building currently cut open (cObject+0x2c/+0x34)
var _debug := false                  ## INTERIOR_DEBUG=1: log every state flip


func _init(world: Sacred.World, walk: Walkable, footprints: Sacred.Footprints) -> void:
	_world = world
	_walk = walk
	_footprints = footprints
	_debug = OS.get_environment("INTERIOR_DEBUG") == "1"


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
	# Regions are navigation records, not necessarily one record per visual
	# building. The verified Seraphim start compound TENT6 is represented by
	# two overlapping region records (52,51,1 and 52,51,2). Deriving each key
	# independently leaves half of one tent in EXTERIOR while the other half is
	# INTERIOR. Build same-family connected components from overlapping/touching
	# rectangles; distant same-family buildings (e.g. separate TENT6 camps) stay
	# independent.
	var groups: Array[Array] = []
	for key: int in keys:
		var region: Dictionary = candidates[key]
		_regions[key] = region
		# Default trigger state is EXTERIOR (retail: initial cTrigger state comes
		# from map data and is bit0). Registering it here, silently, is NOT a
		# transition -- it is what makes a never-visited building's interior
		# geometry hidden under its roof. Only derive()'s edge-trigger below
		# records changes.
		if not _states.has(key):
			_states[key] = State.EXTERIOR
		var joined: Array[int] = []
		for group_index in groups.size():
			var group: Array = groups[group_index]
			for other_key: int in group:
				if _regions_same_compound(region, candidates[other_key]):
					joined.append(group_index)
					break
		if joined.is_empty():
			groups.append([key])
		else:
			# Merge every matching group, not only the first. This is required
			# for transitive compounds across the full map: A may overlap B and B
			# may overlap C while A and C do not directly overlap.
			var merged: Array = [key]
			for group_index in joined:
				merged.append_array(groups[group_index])
			joined.reverse()
			for group_index in joined:
				groups.remove_at(group_index)
			groups.append(merged)
	# RETAIL MODEL (rows 670-676, four independent witnesses). The trigger is
	# read EVERY FRAME from the hero's CURRENT CELL -- cWorld::getParentObject
	# resolves cell -> building anchor -> cTrigger -- and is EDGE-TRIGGERED
	# against a per-object "remembered building" field (cObject+0x2c/+0x34):
	#   DOOR/FLOOR cell inside a building -> that building goes INTERIOR and the
	#     REMEMBERED one is restored to EXTERIOR (setState(1<<layer) @0x005fd0fd
	#     also resets the building you left -- that is why the roof comes back);
	#   STEP cell (0xA) = the authored EXIT cell -> reset the remembered building
	#     to EXTERIOR and forget it (~0x005fd5df);
	#   nothing resolves -> retail FALLS THROUGH leaving the remembered field
	#     stale and fires nothing. Mirrored deliberately (canonical first).
	# There is NO approach corridor: row 676 measured the flip at the INNER LIP
	# of the doorway (still closed on the top step inside the arch, cut one to
	# two cells further in) -- which is exactly STEP-then-FLOOR.
	var resolved: Array = []
	var on_exit_cell := false
	for group: Array in groups:
		for key: int in group:
			var cls := _class_at(cell, candidates[key])
			if cls == Sacred.Regions.STEP:
				on_exit_cell = true
			elif Walkable.class_is_open(cls):
				resolved = group.duplicate()
				resolved.sort()
		if not resolved.is_empty():
			break
	if on_exit_cell:
		_set_group(_remembered, State.EXTERIOR, candidates, ci)
		_remembered = []
	elif not resolved.is_empty() and resolved != _remembered:
		_set_group(_remembered, State.EXTERIOR, candidates, ci)
		_set_group(resolved, State.INTERIOR, candidates, ci)
		_remembered = resolved


## The door-teleport path (main.gd's _door_transition) moves the actor past
## the authored STEP cell a walking exit would tick, so derive() never sees
## the STEP edge and the left building stays INTERIOR -- its roof stays off
## while the hero stands outside (measured 2026-08-30, drive-swapfix: the
## trace flips EXTERIOR->INTERIOR at spawn and never back). The caller
## invokes this after an OUTWARD crossing: the remembered building returns
## to EXTERIOR, exactly what the STEP edge in derive() does.
func restore_remembered() -> void:
	if _remembered.is_empty():
		return
	_set_group(_remembered, State.EXTERIOR, _regions, Vector2i.ZERO)
	_remembered = []


## Applies one whole-complex state change, recording the per-key transitions.
func _set_group(group: Array, state: int, candidates: Dictionary, ci: Vector2i) -> void:
	for key: int in group:
		var region: Dictionary = candidates.get(key, _regions.get(key, {}))
		var previous: int = _states.get(key, State.EXTERIOR)
		if state != previous:
			_last_changes.append({
				"key": key, "from": previous, "to": state,
				"family": region.get("family", ""),
			})
			if _debug:
				print("interior_trace\tcell=%d,%d\tkey=%d\tfrom=%s\tto=%s\tfamily=%s" % [
					ci.x, ci.y, key, state_name(previous), state_name(state),
					region.get("family", "")])
		_states[key] = state


func _regions_same_compound(a: Dictionary, b: Dictionary) -> bool:
	var family_a := str(a.get("family", ""))
	var family_b := str(b.get("family", ""))
	if family_a == "" or family_a != family_b:
		return false
	var ra := Rect2i(a["anchor"], a["size"]).grow(1)
	var rb := Rect2i(b["anchor"], b["size"]).grow(1)
	return ra.intersects(rb) or ra.encloses(rb) or rb.encloses(ra)


func current() -> Dictionary:
	return _states.duplicate()


func current_with_families() -> Dictionary:
	var out: Dictionary = {}
	for key: int in _states:
		var region: Dictionary = _regions.get(key, {})
		out[key] = {"state": _states[key], "family": region.get("family", "")}
	return out


func last_changes() -> Array:
	return _last_changes.duplicate(true)


## The ONE trigger predicate, retail form (rows 670-676): the class of the
## hero's OWN cell inside this footprint. DOOR(9)/FLOOR(2) = inside; STEP(0xA)
## is the authored EXIT cell and is handled by derive() as a restore, so it is
## NOT "inside" here; anything else (WALL, EMPTY, outside the rect) is false.
## No approach corridor -- the retail flip is at the inner lip of the doorway.
## Callers outside this file (main.gd::_exterior_destination,
## door_transition_check.gd) use it to find a cell that does NOT trigger.
func _triggered(cell: Vector2, _region_key_value: int, region: Dictionary) -> bool:
	var cls := _class_at(cell, region)
	return cls != Sacred.Regions.STEP and Walkable.class_is_open(cls)


## Class of the cell under `cell` within this footprint, or EMPTY when the cell
## is outside the rect. This is the port's stand-in for cWorld::getParentObject:
## the cell -> building mapping is authored DATA (Regions.cell_class), not
## geometry, exactly as the retail cell +0x1f nibble / +0x1c,+0x1d anchor delta.
func _class_at(cell: Vector2, region: Dictionary) -> int:
	if region.is_empty():
		return Sacred.Regions.EMPTY
	var ci := Vector2i(floori(cell.x), floori(cell.y))
	var local := ci - (region["anchor"] as Vector2i)
	var size: Vector2i = region["size"]
	if local.x < 0 or local.y < 0 or local.x >= size.x or local.y >= size.y:
		return Sacred.Regions.EMPTY
	return Sacred.Regions.cell_class(region["region"], local.x, local.y)


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
