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
## ALLOWLIST, not a blocklist (decisions D-08 and D-09): only
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
## sector key -> PackedByteArray of the sector's 64x64 WldxEntry byte-26 values.
## See _terrain_open: byte 26 is NOT the walkability field this cache was built
## for, and the rule reading it is unsupported. Kept, with that stated, because
## deleting it would silently open the whole outdoor world instead.
var _terrain_cache: Dictionary = {}
## sector key -> PackedByteArray of the sector's 64x64 WldxEntry +0x1f HIGH
## nibbles, the animated-liquid material selector (row 669). Separate cache from
## the byte-26 plane because the two are read on different code paths and one of
## them is going away once outdoor walkability is actually found.
var _liquid_cache: Dictionary = {}
## sector key -> PackedByteArray of the sector's 64x64 WldxEntry +0x1e bytes,
## the cell-by-cell door/structure/room-interior flag byte (world-sectors.md).
## Bit 2 of this byte is the door signal; the rest of the door-bit logic
## (static-chain walk, blocker flag & 0x200, mask lookup) reads from Sacred.
## Statics and Sacred.TriggerType, both injected through bind_statics_and_types.
var _door_cache: Dictionary = {}
## sector key -> PackedInt32Array of the sector's 64x64 WldxEntry +0x04 static
## chain heads, the entry points for the door-bit blocker lookup. u32 per cell
## is 16 KB per sector; kept separate from _terrain_cache so the door path and
## the byte-26 fallback can be invalidated independently.
var _static_cache: Dictionary = {}
var _statics: Sacred.Statics
var _trigger_type: Sacred.TriggerType

## Wire A (rows 1148-1157): the door-bit path needs both readers -- Sacred.
## Statics walks the per-cell static chain for the blocker (flag & 0x200) and
## reads its object mask at +0x2b, Sacred.TriggerType resolves the per-type
## collision mask. Either may be null and the door-bit branch is then
## bypassed (returns false on a door cell, which is the safe default --
## "wrongness visible" per the file header).
func bind_statics_and_types(statics: Sacred.Statics, trigger_type: Sacred.TriggerType) -> void:
	_statics = statics
	_trigger_type = trigger_type



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


## Outdoor walkability of one WORLD cell, used where no region grid covers it.
##
## THE BYTE-26 RULE BELOW IS UNSUPPORTED AND THIS COMMENT SAYS SO RATHER THAN
## REPEATING WHAT IT USED TO CLAIM. It was taken from Armalion's canWalk
## (sub_4B0220) and credited here to "the retail canWalk rule". Three
## measurements, 2026-08-17, all against the retail data and binary this port
## actually targets:
##
##   1. BYTE 26 IS A TERRAIN HEIGHT CORNER, NOT A WALKABILITY ENUM. Offsets
##      +0x18, +0x19, +0x1a and +0x1b are statistically indistinguishable over
##      36,864 start-area cells -- min -6, max 78, mean 0.062, sd 1.357 and 26
##      distinct values, ALL FOUR IDENTICAL -- and +0x1a correlates with its
##      neighbour +0x1b at r = +0.86. That is exactly the "signed per-corner
##      second height" research/formats/world-sectors.md documents at
##      +0x18..0x1b, and 26 == 0x1a is inside that span.
##   2. RETAIL NEVER READS IT THIS WAY. A byte-pattern search of the 1.0.02
##      Linux binary for `cmp byte ptr [reg+0x1A], 1` and `..., 4` returns ZERO
##      hits, while the control `cmp byte ptr [reg+0x1A], <anything>` returns
##      matches -- so the search works and the idiom is simply absent.
##   3. EVEN ARMALION SAYS MORE THAN THIS. sub_4B0220 is
##      `byte26 != 1 && byte26 != 4 && *(int*)cell >= 0`, and then DISCARDS that
##      answer entirely when `*(DWORD*)cell & 4`, substituting a static-object
##      chain lookup. The port implements two of the three terms and none of the
##      second branch. (The missing `>= 0` term is harmless: 0 of 110,592 cells
##      have a negative tile id.)
##
## The cost is measured, not estimated: this rule opens 96.9% of all cells, the
## region grids cover only 26.55% of the start area, and 96.06% of the walkable
## ground the port offers therefore comes from a comparison against terrain
## height. That is the reported "hero walks randomly against the actual map".
##
## It is LEFT IN PLACE rather than deleted or inverted. Blocking every uncovered
## cell strands the player in the 2026-08-13 way this file's header describes;
## finding retail's real outdoor walkability is open research, tracked in
## research/open-questions.md. What this function does NOT do any more is claim
## a provenance it does not have.
##
## LIQUID IS BLOCKED, and that part IS retail-grounded. Row 669 recovered the
## animated-liquid system from disassembly -- 14 materials, a reflection flag,
## quest-gated water -- selected by +0x1f's HIGH nibble, 9 and 10. Corroborated
## geometrically before it was trusted: the 514 such cells in the start block
## form exactly THREE connected bodies of 356, 121 and 37 cells with ZERO
## isolated singles, which is a river system and not a mis-read nibble. Blocking
## them does not strand the hero -- the start cell is not liquid and the flood
## fill from it saturates the probe's 60,000-cell bound both with and without
## the block, so no reachability is measurably lost.
## Wire A (rows 1148-1157) re-routes the door-bit branch onto a real retail
## gate. For cells whose WldxEntry +0x1e bit 2 is set (the door bit, per
## world-sectors.md), the byte-26 fallback is bypassed entirely and the cell
## is decided by the 16-bit collision-class bitmask:
##   1. Walk the cell's static chain (WldxEntry +0x04 is the chain head,
##      Statics.chain() follows NEXT_OFF=0x1f).
##   2. The first node whose flag at +0x08 has bit 0x200 set is the blocker
##      cWorld::canWalk names.
##   3. Read the blocker's 16-bit object mask at +0x2b and the type id at
##      +0x27; resolve the per-type 16-bit mask through Sacred.TriggerType.
##   4. Walkable iff (object_mask & type_mask) != 0 -- the polarity correction
##      row 1155 closed, after which retail verified it (rows 625/626/676).
## Cells without the door bit keep the byte-26 fallback exactly as it was.
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
	if is_liquid(cx, cy):
		return false
	# Door-bit branch takes priority over the byte-26 fallback. The two readers
	# are bound separately so a partial setup (Statics without TriggerType, or
	# vice versa) fails closed: an unbound door-bit cell is BLOCKED, not opened.
	if _door_bit_at(sx, sy, lx, ly):
		return _door_decision(sx, sy, lx, ly)
	var b := bytes[ly * Sacred.SECT + lx]
	return b != 1 and b != 4


## True iff the cell at sector (sx,sy) local (lx,ly) has WldxEntry +0x1e bit 2
## set (the door signal). Returns false on a missing sector or out-of-range
## local cell so a corrupt file degrades to the byte-26 rule, not a crash.
func _door_bit_at(sx: int, sy: int, lx: int, ly: int) -> bool:
	var door_bytes := _door_bytes_for(sx, sy)
	if door_bytes.is_empty():
		return false
	if lx < 0 or ly < 0 or lx >= Sacred.SECT or ly >= Sacred.SECT:
		return false
	return (door_bytes[ly * Sacred.SECT + lx] & 0x04) != 0


## Resolves the door-bit blocker for one cell and returns the polarity-
## corrected walkability decision: walkable iff the blocker's object mask
## AND the type table mask is non-zero. Returns false on any missing
## reader / empty chain / no flagged blocker, so a degenerate state can
## never widen the player's walkable area.
func _door_decision(sx: int, sy: int, lx: int, ly: int) -> bool:
	if _statics == null or _trigger_type == null:
		return false
	var heads := _static_heads_for(sx, sy)
	if heads.is_empty():
		return false
	var head := heads[ly * Sacred.SECT + lx]
	if head <= 0:
		return false
	# Walk the chain manually so the blocker STATIC INDEX stays in scope --
	# Sacred.Statics.chain() returns type/flags/pos dicts that lose the
	# index, and the mask + type id at +0x2b / +0x27 must be read off the
	# raw record. Same cycle guard (zero / out-of-range / repeat) as chain().
	var cur := head
	var seen: Dictionary[int, bool] = {}
	while cur > 0 and cur < _statics.count() and not seen.has(cur):
		seen[cur] = true
		var blob: PackedByteArray = _statics.blob(cur)
		if blob.size() < 64:
			return false
		if (blob.decode_u32(8) & 0x200) != 0:
			var obj_mask := blob.decode_u32(0x2b)
			var type_id := blob.decode_u32(0x27)
			var type_mask := _trigger_type.mask(type_id)
			return (obj_mask & type_mask) != 0
		cur = blob.decode_u32(0x1f)
	return false



## True when this cell carries one of the 14 animated liquid materials (row
## 669): +0x1f high nibble 9 or 10. Public because the renderer needs the same
## answer this walkability path does, and two independent readings of one nibble
## is how a field drifts out of agreement with itself.
func is_liquid(cx: int, cy: int) -> bool:
	if _world == null:
		return false
	var sx := int(floor(float(cx) / float(Sacred.SECT)))
	var sy := int(floor(float(cy) / float(Sacred.SECT)))
	if sx < 0 or sy < 0 or sx >= 100 or sy >= 100:
		return false
	var nibbles := _liquid_nibbles_for(sx, sy)
	if nibbles.is_empty():
		return false
	var lx := cx - sx * Sacred.SECT
	var ly := cy - sy * Sacred.SECT
	if lx < 0 or ly < 0 or lx >= Sacred.SECT or ly >= Sacred.SECT:
		return false
	var h := nibbles[ly * Sacred.SECT + lx]
	return h == 9 or h == 10


## WldxEntry +0x1f HIGH nibble for every cell of one sector, row-major, or an
## empty array if the sector is absent. Same shape and caching posture as
## _terrain_bytes_for below, including caching the miss.
func _liquid_nibbles_for(gx: int, gy: int) -> PackedByteArray:
	var key := gy * 100 + gx
	if _liquid_cache.has(key):
		return _liquid_cache[key]
	var out := PackedByteArray()
	if _world != null and _world.has_sector(gx, gy):
		var stream := _world.sector(gx, gy)
		if not stream.is_empty():
			var n := Sacred.SECT * Sacred.SECT
			out.resize(n)
			for i in n:
				out[i] = stream[32 + i * Sacred.CELL + 0x1f] >> 4
	_liquid_cache[key] = out
	return out


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

## WldxEntry +0x1e (the door/structure/room-interior flag byte) for every cell
## of one sector, in row-major order, or empty if the sector is absent. Same
## caching posture as _terrain_bytes_for above. Bit 2 of this byte is the door
## signal _door_bit_at() reads; the other two set bits (structure / room
## interior) are not consumed by this file but are kept verbatim so a future
## consumer does not need to re-extract.
func _door_bytes_for(gx: int, gy: int) -> PackedByteArray:
	var key := gy * 100 + gx
	if _door_cache.has(key):
		return _door_cache[key]
	var out := PackedByteArray()
	if _world != null and _world.has_sector(gx, gy):
		var stream := _world.sector(gx, gy)
		if not stream.is_empty():
			var n := Sacred.SECT * Sacred.SECT
			out.resize(n)
			for i in n:
				out[i] = stream[32 + i * Sacred.CELL + 0x1e]
	_door_cache[key] = out
	return out


## WldxEntry +0x04 (the static.pak chain head) for every cell of one sector,
## row-major, or empty if the sector is absent. u32 per cell is 16 KB per
## sector -- a separate cache from _door_bytes_for so the door path and the
## byte-26 fallback can be invalidated independently when one of them is
## corrected without touching the other.
func _static_heads_for(gx: int, gy: int) -> PackedInt32Array:
	var key := gy * 100 + gx
	if _static_cache.has(key):
		return _static_cache[key]
	var out := PackedInt32Array()
	if _world != null and _world.has_sector(gx, gy):
		var stream := _world.sector(gx, gy)
		if not stream.is_empty():
			var n := Sacred.SECT * Sacred.SECT
			out.resize(n)
			for i in n:
				out[i] = stream.decode_u32(32 + i * Sacred.CELL + 4)
	_static_cache[key] = out
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
