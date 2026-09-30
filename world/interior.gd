class_name Interior
extends RefCounted
## Authored building identity and mutable raw cTrigger state. Art admission uses
## exact u16 equality, never a region family or an EXTERIOR/INTERIOR projection.
## Source: LGP 0x080ED352/570 (parent), 0x080ED4AC (child order),
## 0x080ED1F2 (child+12/+45 grid), 0x0811577A (focus actor transitions).

signal state_changed(trigger_id: int, previous: int, state: int)
const Triggers := preload("res://formats/triggers.gd")
enum State { EXTERIOR, INTERIOR }
const APPROACH_CELLS := 6 # Existing door-destination search bound, not admission.

var triggers: Triggers
var _world: Sacred.World
var _statics: Sacred.Statics
var _sectors: Dictionary = {}
var _parents: Dictionary = {}
var _region_bindings: Dictionary = {}
## Immutable cell/child/grid descriptors only; raw trigger state stays live.
var _dynamic_support_sources: Dictionary = {}
var _dynamic_support_grids: Dictionary = {}
var _last_changes: Array = []
var _remembered_parent := 0
var _support := 0
var _layer := 0

func _init(world: Sacred.World, statics: Sacred.Statics, trigger_records: Triggers) -> void:
	_world = world
	_statics = statics
	triggers = trigger_records
	if triggers != null:
		triggers.state_changed.connect(_on_state_changed)

## Null parent is a real bypass; unavailable trigger data is NOT raw state zero.
func state(trigger_id: int) -> int:
	if triggers == null:
		push_error("Interior: raw trigger table is required")
		return -1
	return triggers.state(trigger_id)

func replace_state(trigger_id: int, value: int) -> bool:
	return triggers != null and triggers.replace_state(trigger_id, value)

func set_bits(trigger_id: int, mask: int) -> bool:
	return triggers != null and triggers.set_bits(trigger_id, mask)

func reset_bits(trigger_id: int, mask: int) -> bool:
	return triggers != null and triggers.reset_bits(trigger_id, mask)

## Resolve once by SIGNED base-cell+28/+29, then walk target static+31 until
## flags&0x10. No sprite position, name, rectangle, or nearest-region heuristic.
func parent_for_cell(cell: Vector2i) -> Dictionary:
	var source := cell_data(cell)
	if source.is_empty() or (source[30] & 1) == 0:
		return {}
	var target := cell + Vector2i(source.decode_s8(28), source.decode_s8(29))
	var base := cell_data(target)
	if base.is_empty() or (base[30] & 1) == 0:
		return {}
	var id := base.decode_u32(4)
	var seen: Dictionary = {}
	while id != 0 and not seen.has(id):
		seen[id] = true
		var object := _statics.get_object(id)
		if object.is_empty():
			push_error("Interior: invalid parent chain static %d" % id)
			return {}
		if (object["flags"] & 0x10) != 0:
			return object
		id = object["next"]
	return {}

## Layer zero is the PAR itself; layers 1+ follow PAR+23 then child+31.
func substate(parent_id: int, layer: int) -> int:
	var parent := _statics.get_object(parent_id)
	if parent.is_empty() or (parent["flags"] & 0x10) == 0 or layer < 0:
		return 0
	if layer == 0:
		return parent_id
	var id: int = parent["child_head"]
	for ordinal in range(1, layer + 1):
		var child := _statics.get_object(id)
		if child.is_empty():
			return 0
		if ordinal == layer:
			return id
		id = child["next"]
	return 0

func support_ref() -> int:
	return _support


func support_region(substate_id: int) -> Dictionary:
	var child := _statics.get_object(substate_id)
	if child.is_empty():
		return {}
	var coordinates := _world.coordinates_for_id(child["sector"])
	if coordinates.x < 0:
		return {}
	var sector := _sector(coordinates)
	if sector.is_empty():
		return {}
	var regions: Sacred.Regions = sector["regions"]
	var ordinal: int = child["region_ordinal"]
	if not regions.by_ordinal.has(ordinal):
		push_error("Interior: static %d references missing region ordinal %d" % [substate_id, ordinal])
		return {}
	return regions.by_ordinal[ordinal]

## Nonmutating per-actor support lookup. Layer is native actor+36, and zero
## means no child grid; callers must not copy the focus actor's support to NPCs.
func support_ref_at(cell: Vector2i, layer: int) -> int:
	if layer <= 0:
		return 0
	var parent := parent_for_cell(cell)
	return substate(parent["id"], layer) if not parent.is_empty() else 0

## FIFO phases from 0x080E0E96: authored zero-based child ordinals, then -1
## for the base traversal. Empty means rejected, NOT [-1]. 0x083A6312 returns
## the lowest set-bit index: raw0/raw1/raw3 give zero and skip support visits
## unless parent flag0x400 enumerates every child. Raw2/raw6 select child1.
## Identity is static+12/+45, not reference, layer, or overlapping bounds.
## 0x080ED1F2 zero-size grids alias the base cell: retain every matching child
## occurrence AND -1, since native traverses that same chain more than once.
func dynamic_support_orders(cell: Vector2i, actual_support_ref: int) -> PackedInt32Array:
	var orders := PackedInt32Array()
	var source := _dynamic_support_source(cell)
	if source.is_empty():
		return orders
	var actual: Dictionary = {}
	var on_base := actual_support_ref == 0
	if not on_base:
		actual = _dynamic_support_grid(actual_support_ref)
		if actual.is_empty():
			return orders
		on_base = actual["base"]
		if not on_base:
			var bounds: Rect2i = actual["bounds"]
			if not bounds.has_point(cell):
				return orders
	var parent: Dictionary = source["parent"]
	var children: Array[Dictionary] = source["children"]
	var first := 0
	var end := 0
	if not parent.is_empty():
		if (parent["flags"] & 0x400) != 0:
			end = children.size()
		else:
			var raw := state(parent["trigger"])
			if raw > 0:
				var layer := 0
				while (raw & 1) == 0:
					raw >>= 1
					layer += 1
				if layer > 0 and layer <= children.size():
					first = layer - 1
					end = layer
	for ordinal in range(first, end):
		var selected: Dictionary = children[ordinal]
		if selected.is_empty():
			continue
		if on_base:
			if selected["base"]:
				orders.append(ordinal)
		elif not selected["base"] and selected["identity"] == actual["identity"]:
			orders.append(ordinal)
	if on_base:
		orders.append(-1)
	return orders

func _dynamic_support_source(cell: Vector2i) -> Dictionary:
	if _dynamic_support_sources.has(cell):
		return _dynamic_support_sources[cell]
	var source: Dictionary = {}
	var base := cell_data(cell)
	if not base.is_empty():
		var parent := parent_for_cell(cell)
		var children: Array[Dictionary] = []
		var selected_parent := parent
		if not parent.is_empty() and (parent["flags"] & 0x400) == 0:
			# 0x080E285F offsets once before getParentObject applies the
			# target cell's own signed offset. Trigger still belongs to parent.
			var target := cell + Vector2i(base.decode_s8(28), base.decode_s8(29))
			selected_parent = parent_for_cell(target)
		if not selected_parent.is_empty():
			for child: Dictionary in _statics.chain(selected_parent["child_head"]):
				children.append(_dynamic_support_grid(child["id"]))
		source = {"parent": parent, "children": children}
	_dynamic_support_sources[cell] = source
	return source

func _dynamic_support_grid(id: int) -> Dictionary:
	if _dynamic_support_grids.has(id):
		return _dynamic_support_grids[id]
	var grid: Dictionary = {}
	var region := support_region(id)
	if not region.is_empty():
		var object := _statics.get_object(id)
		grid = {"identity": Vector2i(object["sector"], object["region_ordinal"]),
			"base": region["size"] == Vector2i.ZERO,
			"bounds": Rect2i(region["cell"], region["size"])}
	_dynamic_support_grids[id] = grid
	return grid

## Native initial placement, 0x0811577A: layer0 on base class1/2 tries child1
## except item types768..924. 0x080EE10C -> 0x080EE194 checks the CHILD grid:
## low class must not be1/2 and flags+30 bit8 must be clear. The native
## position-trigger registry's optional doorbit4 override is not populated by
## this port's pre-existing gameplay; no rectangle/family substitutes for it.
func initial_support_ref(cell: Vector2i, type_id: int, layer: int) -> int:
	if layer > 0:
		return support_ref_at(cell, layer)
	if type_id >= 768 and type_id <= 924:
		return 0
	var base := cell_data(cell)
	if base.is_empty() or (base[31] & 0xf) not in [1, 2]:
		return 0
	var child_id := support_ref_at(cell, 1)
	if child_id == 0:
		return 0
	var child_cell := cell_data(cell, child_id)
	if child_cell.is_empty() or (child_cell[31] & 0xf) in [1, 2] or (child_cell[30] & 8) != 0:
		return 0
	return child_id

## Initialize the focus actor from its actual definition type and authored
## layer. Sim's later derive(cell) retains this support instead of guessing it
## from the raw trigger mask (zero and one both have native lowest-level zero).
func place_focus(cell: Vector2, type_id: int, layer: int) -> void:
	var ci := Vector2i(floori(cell.x), floori(cell.y))
	var child_id := initial_support_ref(ci, type_id, layer)
	if child_id == 0:
		restore_remembered()
		return
	var child := _statics.get_object(child_id)
	select_storey(child["parent"], layer if layer > 0 else 1)

## Raw cell for native support sampling. Zero-size height records use base
## cells; absent/outside nonzero substate grids return no cell (0x080ED1F2).
func cell_data(cell: Vector2i, substate_id: int = 0) -> PackedByteArray:
	if substate_id != 0:
		var region := support_region(substate_id)
		if region.is_empty():
			return PackedByteArray()
		if region["size"] != Vector2i.ZERO:
			var local: Vector2i = cell - region["cell"]
			var size: Vector2i = region["size"]
			if local.x < 0 or local.y < 0 or local.x >= size.x or local.y >= size.y:
				return PackedByteArray()
			var grid: PackedByteArray = region["grid"]
			var offset := (local.y * size.x + local.x) * Sacred.CELL
			return grid.slice(offset, offset + Sacred.CELL)
	var coordinates := Vector2i(floori(float(cell.x) / Sacred.SECT), floori(float(cell.y) / Sacred.SECT))
	var sector := _sector(coordinates)
	if sector.is_empty():
		return PackedByteArray()
	var local := cell - coordinates * Sacred.SECT
	var grid: PackedByteArray = sector["cells"]
	var offset := (local.y * Sacred.SECT + local.x) * Sacred.CELL
	return grid.slice(offset, offset + Sacred.CELL)

func _sector(coordinates: Vector2i) -> Dictionary:
	if _sectors.has(coordinates):
		return _sectors[coordinates]
	if _world == null or coordinates.x < 0 or coordinates.y < 0 \
			or coordinates.x >= _world.size.x or coordinates.y >= _world.size.y \
			or not _world.has_sector(coordinates.x, coordinates.y):
		return {}
	var stream := _world.sector(coordinates.x, coordinates.y)
	if stream.size() < Sacred.NAME + Sacred.SECT * Sacred.SECT * Sacred.CELL:
		return {}
	var sector := {"cells": stream.slice(Sacred.NAME, Sacred.NAME + Sacred.SECT * Sacred.SECT * Sacred.CELL),
		"regions": Sacred.Regions.new(stream, coordinates.x, coordinates.y)}
	_sectors[coordinates] = sector
	return sector

func _register_parent(parent: Dictionary) -> void:
	var id: int = parent["id"]
	if _parents.has(id):
		return
	_parents[id] = parent
	var child_id: int = parent["child_head"]
	var seen: Dictionary = {}
	var layer := 1
	while child_id != 0 and not seen.has(child_id):
		seen[child_id] = true
		var child := _statics.get_object(child_id)
		if child.is_empty():
			break
		var region := support_region(child_id)
		if not region.is_empty() and region["index"] >= 0:
			var coordinates := _world.coordinates_for_id(child["sector"])
			var key := _region_key(coordinates.x, coordinates.y, region["index"])
			_region_bindings[key] = {"trigger": parent["trigger"], "layer": layer,
				"parent": id, "substate": child_id, "region": region}
		child_id = child["next"]
		layer += 1

## Door entry and STEP exit use the current authored child grid. Only the
## focus actor is passed here by Sim; initial placement uses place_focus().
func derive(cell: Vector2) -> void:
	_last_changes.clear()
	var ci := Vector2i(floori(cell.x), floori(cell.y))
	var base := cell_data(ci)
	if base.is_empty():
		return
	var parent := parent_for_cell(ci)
	if _support != 0 and not parent.is_empty() and parent["id"] != _remembered_parent:
		select_storey(parent["id"], _layer)
	var active := cell_data(ci, _support) if _support != 0 else base
	if active.is_empty():
		active = base
	var cls := active[31] & 0xf
	if cls == Sacred.Regions.STEP and _support != 0:
		restore_remembered()
	elif cls == Sacred.Regions.DOOR and (active[30] & 1) != 0:
		enter_at(ci)

## Door-click teleport must invoke this at the authored door before moving the
## actor beyond it. Full native interaction prerequisites/event locks are not
## implemented by the existing gameplay, and are not inferred from rectangles.
func enter_at(cell: Vector2i) -> bool:
	var parent := parent_for_cell(cell)
	if parent.is_empty():
		return false
	# Native placement does not re-fire while already using PAR+23. External
	# script/raw-state changes must survive standing still in that doorway.
	if _support != 0 and _support == parent["child_head"]:
		return true
	return select_storey(parent["id"], 1)

## Storey/teleport callers supply native layer order, never compact region order.
func select_storey(parent_id: int, layer: int) -> bool:
	if layer < 0 or layer >= 16:
		push_error("Interior: layer %d cannot select a u16 state" % layer)
		return false
	var selected := substate(parent_id, layer)
	if selected == 0:
		return false
	var parent := _statics.get_object(parent_id)
	_register_parent(parent)
	if _remembered_parent != 0 and _remembered_parent != parent_id:
		_restore_parent(_remembered_parent)
	if not _select_mask(parent["trigger"], 1 << layer):
		return false
	_remembered_parent = parent_id if layer != 0 else 0
	_support = selected if layer != 0 else 0
	_layer = layer
	return true

func _select_mask(trigger_id: int, mask: int) -> bool:
	if not reset_bits(trigger_id, 0xffff):
		return false
	return set_bits(trigger_id, mask)

func _restore_parent(parent_id: int) -> void:
	var parent := _statics.get_object(parent_id)
	if not parent.is_empty():
		_select_mask(parent["trigger"], 1)

func restore_remembered() -> void:
	if _remembered_parent != 0:
		_restore_parent(_remembered_parent)
	_remembered_parent = 0
	_support = 0
	_layer = 0

func _on_state_changed(trigger_id: int, previous: int, value: int) -> void:
	for key: int in _region_bindings:
		var binding: Dictionary = _region_bindings[key]
		if binding["trigger"] == trigger_id:
			_last_changes.append({"key": key, "from": _projection(previous, binding["layer"]),
				"to": _projection(value, binding["layer"]), "family": "",
				"trigger": trigger_id, "raw_from": previous, "raw_to": value})
	state_changed.emit(trigger_id, previous, value)

## Navigation/replay presentation only. Renderer never consumes this enum.
func current() -> Dictionary:
	var result: Dictionary = {}
	for key: int in _region_bindings:
		var binding: Dictionary = _region_bindings[key]
		result[key] = _projection(state(binding["trigger"]), binding["layer"])
	return result

func last_changes() -> Array:
	return _last_changes.duplicate(true)

func _triggered(cell: Vector2, _key: int, region: Dictionary) -> bool:
	var ci := Vector2i(floori(cell.x), floori(cell.y))
	var local: Vector2i = ci - region["anchor"]
	var cls := Sacred.Regions.cell_class(region["region"], local.x, local.y)
	return cls != Sacred.Regions.STEP and Walkable.class_is_open(cls)


static func _projection(raw: int, layer: int) -> int:
	return State.INTERIOR if raw == (1 << layer) else State.EXTERIOR

static func _region_key(gx: int, gy: int, index: int) -> int:
	return gx * 1000000 + gy * 1000 + index

static func unpack_region_key(key: int) -> Vector3i:
	var gx := key / 1000000
	var rest := key - gx * 1000000
	return Vector3i(gx, rest / 1000, rest % 1000)

static func state_name(value: int) -> String:
	return "INTERIOR" if value == State.INTERIOR else "EXTERIOR"
