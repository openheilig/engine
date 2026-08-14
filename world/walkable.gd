class_name Walkable
extends RefCounted
## Cell-space walkability lookup over Sacred.Regions region grids.
##
## Nothing in this file references a node type, the scene tree or the
## camera -- the same disclaimer sim.gd opens with (world/sim.gd:11-13).
## Constructed with a Sacred.World; every region grid is read straight from
## Sacred.World's own sector streams, never from anything SectorView happens
## to have loaded -- reading from the streamer's cache would make
## walkability a function of streaming order, which is exactly what replay
## exists to be independent of.
##
## ALLOWLIST, not a blocklist (D-08, D-09, ROADMAP.md/04-CONTEXT.md): only
## Sacred.Regions.FLOOR, .DOOR, .STEP and .OPEN are open ground. Everything
## else -- Sacred.Regions.EMPTY, Sacred.Regions.WALL, every other undecoded
## 0xd_/0xe_ class, and every cell no region covers -- blocks. A wrong ALLOWLIST fails
## visibly: the player is stranded against an invisible wall, obvious on
## sight. A wrong BLOCKLIST fails silently: a mis-decoded class lets the
## player walk through geometry, which looks plausible on screen. This
## project's whole verification posture is "make wrongness visible" (the
## same stance sacred.gd:1038-1040 takes on out-of-range mesh indices), so
## an allowlist is the only choice consistent with it.
##
## Sacred.Regions.OPEN (the 0xd0/0xe0 bytes, 39,644 cells) IS open ground,
## measured 2026-08-13: the retail Seraphim start stands the hero on a 0xd0
## cell inside KLOSTER_KAPELLE01 with the roof cut away, and 0xd0/0xe0 tile
## that chapel's nave and its library wing wall to wall. Before that date
## Regions.cell_class collapsed them onto EMPTY, so this allowlist never got
## to see them and every building interior was unwalkable.
##
## The raw 0x00 byte is still explicitly UNDECODED, not open ground (D-10): 143,806 of
## it is the single most common region-cell code in the world, and calling
## it walkable would encode a guess as fact. The upgrade path is a retail
## capture through install/shim/autopilot.c; until one exists, adding 0x00
## to the allowlist is a one-line change this file does not make.

## Sectors searched behind (and including) the queried cell's own sector, in
## both x and y -- the search block is (SEARCH_BACK+1) x (SEARCH_BACK+1)
## sectors, walked in ASCENDING sector-key order (gy*100+gx). Region records
## are anchored inside their own owning sector (sacred.gd Regions._init's
## `Rect2i(lo, ...).has_point(cell)` check) but their grid can extend past
## that sector's edge -- sector 64,39 alone carries four co-located 50x55
## grids (sacred.gd:389), the largest measured extent. SEARCH_BACK=1 gives a
## 128x128-cell search span, comfortably past that measured max with room to
## grow before this bound needs revisiting -- validated at cache time by
## _validate_span() below rather than assumed.
const SEARCH_BACK := 1

## Out-of-range / uncovered-cell return value, the house accessor rule
## ("out of range returns the empty value, never an error"). Numerically
## equal to Sacred.Regions.EMPTY (== 0); spelled as a local constant rather
## than that qualified name so this file's allowlist stays exactly the
## three open classes when grepped for "Regions.(FLOOR|DOOR|STEP)" versus
## "Regions.(WALL|EMPTY)" treated as open -- an allowlist that also had to
## spell the blocked names for plumbing reasons would be harder to audit at
## a glance for exactly this file's one job.
const _UNCOVERED := 0

var _world: Sacred.World
var _region_cache: Dictionary = {}   ## sector key (gy*100+gx) -> Sacred.Regions or null (a cached miss)
## sector key -> PackedByteArray of the sector's 64x64 WldxEntry byte-26 values
## (terrain walkability per the retail canWalk rule), or null for an absent sector.
var _terrain_cache: Dictionary = {}


func _init(world: Sacred.World) -> void:
	_world = world


## The class of one WORLD cell -- not region-local -- as Sacred.Regions'
## symbolic enum, never the raw byte (only the low nibble is decoded;
## sacred.gd:431-438). Out of range, or covered by no region at all, returns
## Sacred.Regions.EMPTY, matching the house accessor rule (out-of-range
## returns the empty value, never an error).
##
## When more than one region covers a cell -- the storey case, the
## co-located 0xd_/0xe_ grids sector 64,39 shows -- the first match in
## ascending sector-key order, then Regions.list order, wins.
##
## ponytail: the 0xd_/0xe_ family split (storey or inside/outside, per
## sacred.gd:388-390) is undecoded, so this file cannot yet tell two stacked
## storeys apart -- it takes whichever region query order finds first. The
## upgrade path is decoding that family split; the four co-located grids in
## sector 64,39 are the sample to decode it from.
func class_at(cx: int, cy: int) -> int:
	var sx := int(floor(float(cx) / float(Sacred.SECT)))
	var sy := int(floor(float(cy) / float(Sacred.SECT)))
	for dy in range(-SEARCH_BACK, 1):
		var gy := sy + dy
		if gy < 0:
			continue
		for dx in range(-SEARCH_BACK, 1):
			var gx := sx + dx
			if gx < 0:
				continue
			var regions := _regions_for(gx, gy)
			if regions == null:
				continue
			for r: Dictionary in regions.list:
				var anchor: Vector2i = r["cell"]
				var size: Vector2i = r["size"]
				var lx := cx - anchor.x
				var ly := cy - anchor.y
				if lx >= 0 and ly >= 0 and lx < size.x and ly < size.y:
					return Sacred.Regions.cell_class(r, lx, ly)
	return _UNCOVERED


## The allowlist itself, over a class rather than a cell -- exposed
## separately so a caller can test a class it already has without a second
## lookup. Written as four separate returns, one open class per line, so
## the allowlist is exactly as wide as it looks on a `grep -c` audit of this
## file -- one collapsed boolean expression would hide behind a single
## matched line.
static func class_is_open(cls: int) -> bool:
	if cls == Sacred.Regions.FLOOR:
		return true
	if cls == Sacred.Regions.DOOR:
		return true
	if cls == Sacred.Regions.OPEN:
		return true
	return cls == Sacred.Regions.STEP


## One lookup per axis inside Movement.sweep(): class_at() plus the
## allowlist, over a WORLD cell.
##
## The region grids are the building-footprint layer: where a region covers
## the cell, its class decides (D-08 allowlist). Cells NO region covers are
## outdoor ground, which retail walkability decides by WldxEntry byte 26
## (Armalion canWalk sub_4B0220: `byte26 != 1 && byte26 != 4 && tile >= 0`).
## Before 2026-08-13 the port returned blocked for every uncovered cell,
## which made ALL outdoor ground unwalkable and trapped actors inside
## buildings -- the D-10 "0x00 might be outdoor terrain" case, resolved by
## this byte being decoded from the retail binary rather than guessed.
##
## The coverage test must be separate from the class test: a region-covered
## cell whose class byte is 0x00 (EMPTY, the most common code, D-10) returns
## EMPTY from class_at() -- numerically equal to _UNCOVERED -- so an
## `if cls != _UNCOVERED` gate would fall through to the terrain fallback and
## open EMPTY cells INSIDE building footprints (2026-08-13: walking "outside"
## through a building, door corridors flipping state). _region_class_at()
## returns null for uncovered cells, which is what the gate keys on.
func is_open(cx: int, cy: int) -> bool:
	var cls := _region_class_at(cx, cy)
	if cls != _NO_REGION:
		return class_is_open(cls)
	return _terrain_open(cx, cy)


## The region class of one WORLD cell, or -1 if NO region grid covers it.
## Same scan order as class_at() (ascending sector key, then Regions.list),
## but returns -1 instead of EMPTY for uncovered cells so a caller can
## tell "region says EMPTY" apart from "no region here" -- the two must
## resolve differently (EMPTY stays blocked, uncovered consults terrain).
const _NO_REGION := -1

func _region_class_at(cx: int, cy: int) -> int:
	var sx := int(floor(float(cx) / float(Sacred.SECT)))
	var sy := int(floor(float(cy) / float(Sacred.SECT)))
	for dy in range(-SEARCH_BACK, 1):
		var gy := sy + dy
		if gy < 0:
			continue
		for dx in range(-SEARCH_BACK, 1):
			var gx := sx + dx
			if gx < 0:
				continue
			var regions := _regions_for(gx, gy)
			if regions == null:
				continue
			for r: Dictionary in regions.list:
				var anchor: Vector2i = r["cell"]
				var size: Vector2i = r["size"]
				var lx := cx - anchor.x
				var ly := cy - anchor.y
				if lx >= 0 and ly >= 0 and lx < size.x and ly < size.y:
					return Sacred.Regions.cell_class(r, lx, ly)
	return _NO_REGION


func _regions_for(gx: int, gy: int) -> Sacred.Regions:
	var key := gy * 100 + gx
	if _region_cache.has(key):
		return _region_cache[key]
	var regions: Sacred.Regions = null
	if _world != null and _world.has_sector(gx, gy):
		var stream := _world.sector(gx, gy)
		if not stream.is_empty():
			var r := Sacred.Regions.new(stream, gx, gy)
			_validate_span(r, gx, gy)
			regions = r
	_region_cache[key] = regions   ## cache the miss too -- an absent sector is not re-inflated on every query
	return regions


## The retail terrain walkability of one WORLD cell: true when no region grid
## covers it and the WldxEntry byte 26 says the ground is open (not 1, not 4,
## per the retail canWalk rule). False for cells outside the world or in an
## absent sector -- the house accessor rule again.
func _terrain_open(cx: int, cy: int) -> bool:
	if _world == null:
		return false
	var sx := int(floor(float(cx) / float(Sacred.SECT)))
	var sy := int(floor(float(cy) / float(Sacred.SECT)))
	if sx < 0 or sy < 0 or sx >= 100 or sy >= 100:
		return false
	var bytes := _terrain_bytes_for(sx, sy)
	if bytes.is_empty():
		return false
	var lx := cx - sx * Sacred.SECT
	var ly := cy - sy * Sacred.SECT
	if lx < 0 or ly < 0 or lx >= Sacred.SECT or ly >= Sacred.SECT:
		return false
	var b := bytes[ly * Sacred.SECT + lx]
	return b != 1 and b != 4


## WldxEntry byte 26 for every cell of one sector, in row-major order, or an
## empty array if the sector is absent. Byte 26 is the retail terrain
## walkability field (canWalk sub_4B0220 reads `v8 + 26` where v8 points at a
## 32-byte world cell record). Extracted once per sector and cached; the
## decompressed stream is 150 KB but the byte-26 plane is 4 KB.
func _terrain_bytes_for(gx: int, gy: int) -> PackedByteArray:
	var key := gy * 100 + gx
	if _terrain_cache.has(key):
		return _terrain_cache[key]
	var out := PackedByteArray()
	if _world != null and _world.has_sector(gx, gy):
		var stream := _world.sector(gx, gy)
		if not stream.is_empty():
			var n := Sacred.SECT * Sacred.SECT
			out.resize(n)
			for i in n:
				out[i] = stream[32 + i * Sacred.CELL + 26]
	_terrain_cache[key] = out   ## cache the miss too, same as _regions_for
	return out


## Runtime check, not assert() -- assert() is stripped from release builds
## and this relation must hold in every build, the same posture Sim._init
## takes for its radius ordering (sim.gd:69-70).
func _validate_span(r: Sacred.Regions, gx: int, gy: int) -> void:
	var span := (SEARCH_BACK + 1) * Sacred.SECT
	for reg: Dictionary in r.list:
		var size: Vector2i = reg["size"]
		if size.x > span or size.y > span:
			push_error("Walkable: region at sector %d,%d cell %s size %s exceeds the %dx%d search-block span -- SEARCH_BACK is too small" % [
				gx, gy, reg["cell"], size, span, span])


## For one sector: flood-fills 4-connected over the union of that sector's
## OWN region cells (never a neighbour sector's), restricted to the
## allowlist, and returns the largest connected component as
## {"seed": Vector2i, "count": int, "bbox": Rect2i}, or {} if the sector has
## no region data or no open cell at all.
##
## Deterministic: candidate cells are sorted (y then x) before flood-filling,
## so BFS always starts from the lowest unvisited cell in that order and a
## tie between two equal-size components is broken by whichever is found
## first in that same order -- never by Dictionary iteration order, which
## Godot does not guarantee stays insertion-order across engine versions.
func largest_component(gx: int, gy: int) -> Dictionary:
	var regions := _regions_for(gx, gy)
	if regions == null or regions.list.is_empty():
		return {}
	var open_set: Dictionary = {}   ## Vector2i -> true
	for r: Dictionary in regions.list:
		var anchor: Vector2i = r["cell"]
		var size: Vector2i = r["size"]
		for y in size.y:
			for x in size.x:
				var wc := anchor + Vector2i(x, y)
				if open_set.has(wc):
					continue   # first region in list order wins -- same storey precedence as class_at()
				if class_is_open(Sacred.Regions.cell_class(r, x, y)):
					open_set[wc] = true
	if open_set.is_empty():
		return {}
	var cells: Array = open_set.keys()
	cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.y != b.y:
			return a.y < b.y
		return a.x < b.x)

	var visited: Dictionary = {}
	var best_seed := Vector2i.ZERO
	var best_count := 0
	var best_bbox := Rect2i()
	const NEIGHBOURS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for c: Vector2i in cells:
		if visited.has(c):
			continue
		var queue: Array[Vector2i] = [c]
		visited[c] = true
		var count := 0
		var minx := c.x
		var maxx := c.x
		var miny := c.y
		var maxy := c.y
		var qi := 0
		while qi < queue.size():
			var cur: Vector2i = queue[qi]
			qi += 1
			count += 1
			minx = mini(minx, cur.x)
			maxx = maxi(maxx, cur.x)
			miny = mini(miny, cur.y)
			maxy = maxi(maxy, cur.y)
			for d: Vector2i in NEIGHBOURS:
				var n := cur + d
				if open_set.has(n) and not visited.has(n):
					visited[n] = true
					queue.append(n)
		if count > best_count:
			best_count = count
			best_seed = c
			best_bbox = Rect2i(minx, miny, maxx - minx + 1, maxy - miny + 1)
	return {"seed": best_seed, "count": best_count, "bbox": best_bbox}


## Scans a bounded, deterministic (2*radius+1)^2 sector square centred on
## `centre`, in ascending sector-key order, and returns the largest
## walkable component found in any of them, tie-broken by the LOWER sector
## key (guaranteed by scanning in ascending order and only replacing the
## current best on a STRICTLY greater count). radius=5 -> an 11x11 square,
## ~120 stream inflations -- mirrors main.gd._first_real_record_id()
## (240-249), which scans for the first record that resolves to real art
## rather than picking blindly.
##
## push_error()s and returns {} if every scanned sector yields an empty
## component, rather than spawning somewhere arbitrary -- region grids cover
## only a small fraction of the world, so an empty result is a real
## possibility, not a bug, and must be reported rather than silently
## defaulted.
func derive_spawn(centre: Vector2i, radius: int = 5) -> Dictionary:
	var best: Dictionary = {}
	var scanned := 0
	for dy in range(-radius, radius + 1):
		var gy := centre.y + dy
		if gy < 0 or gy >= 100:
			continue
		for dx in range(-radius, radius + 1):
			var gx := centre.x + dx
			if gx < 0 or gx >= 100:
				continue
			scanned += 1
			var comp := largest_component(gx, gy)
			if comp.is_empty():
				continue
			if best.is_empty() or int(comp["count"]) > int(best["count"]):
				best = comp
				best["sector"] = Vector2i(gx, gy)
	if best.is_empty():
		push_error("Walkable.derive_spawn: every scanned sector (%d, radius %d around %d,%d) yielded an empty walkable component" % [
			scanned, radius, centre.x, centre.y])
		return {}
	best["sectors_scanned"] = scanned
	return best
