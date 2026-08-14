extends RefCounted
## Data-layer correspondence between region/navmesh footprints and placed art.
## Consumes one sector stream plus the two retail readers that own object and
## name data; no world-layer or node type reaches this class.

const Common := preload("res://formats/common.gd")
const Items := preload("res://formats/items.gd")
const Regions := preload("res://formats/regions.gd")
const Statics := preload("res://formats/statics.gd")

var _statics: Statics
var _items: Items
## Number of regions in the most recent resolve() whose levelled members
## voted for more than one family. Mixed footprints remain deterministic
## (majority, then lexical tie-break) but are exposed rather than hidden.
var mixed: int = 0

func _init(statics: Statics, items: Items) -> void:
	_statics = statics
	_items = items

## Per region-index, in Sacred.Regions.list order:
## {anchor, size, family, members, props}. Object arrays carry mixed.pak
## sprite ids in the sector cell-grid's ascending row-major order.
func resolve(stream: PackedByteArray, gx: int, gy: int) -> Dictionary:
	var out: Dictionary = {}
	mixed = 0
	var regions := Regions.new(stream, gx, gy)
	for ri in regions.list.size():
		var r: Dictionary = regions.list[ri]
		out[ri] = {
			"anchor": r["cell"], "size": r["size"], "family": "",
			"members": [], "props": [], "region": r,
		}
	if _statics == null or _items == null or out.is_empty():
		return out
	var entries_end := Common.NAME + Common.SECT * Common.SECT * Common.CELL
	if stream.size() < entries_end:
		push_error("Footprints: sector %d,%d stream is too short for its cell grid (%d < %d)" % [
			gx, gy, stream.size(), entries_end])
		return out
	# The whole chain, not just the cell's head static -- same reason
	# SectorView._build_objects walks it: a stacked placement is a real
	# placement, and its family vote counts.
	for i in Common.SECT * Common.SECT:
		for o: Dictionary in _statics.chain(stream.decode_u32(Common.NAME + i * Common.CELL + 4)):
			var cell := _object_cell(o["pos"])
			for ri in regions.list.size():
				var fp: Dictionary = out[ri]
				if not Rect2i(fp["anchor"], fp["size"]).has_point(cell):
					continue
				var sid: int = o["type"]
				if _items.levels(sid) != 0:
					fp["members"].append(sid)
				else:
					fp["props"].append(sid)
				out[ri] = fp
	for ri in regions.list.size():
		var fp: Dictionary = out[ri]
		var votes: Dictionary = {}
		for sid: int in fp["members"]:
			var family := _items.family_of(sid)
			if family != "":
				votes[family] = int(votes.get(family, 0)) + 1
		if votes.size() > 1:
			mixed += 1
		var families: Array = votes.keys()
		families.sort()
		var winner := ""
		var best := 0
		for family: String in families:
			var count: int = votes[family]
			if count > best:
				best = count
				winner = family
		fp["family"] = winner
		out[ri] = fp
	return out

## static.pak positions are absolute isometric screen coordinates (Statics'
## own format contract). Invert ox=48*(cx-cy), oy=-24*(cx+cy), then floor so
## negative fractional coordinates land in the same cell as simulation.
static func _object_cell(pos: Vector2) -> Vector2i:
	return Vector2i(floori(pos.x / 96.0 - pos.y / 48.0),
		floori(-pos.y / 48.0 - pos.x / 96.0))
