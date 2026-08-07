class_name RecordStore
extends RefCounted
## The immutable half of OpenMW's split (R10.4): definitions are shared and
## read-only; ActorState (the mutable half) holds only a record_id reference
## into this store. Two actors that share a record_id observe the SAME
## Dictionary object -- copying a definition per actor would silently
## reintroduce per-actor state for data that is supposed to be shared.
##
## THE ID SPACE (decided at Plan 02's Task 1 blocking checkpoint, recorded in
## .planning/PROJECT.md "Record Id Space Decision" -- option-b selected):
##   record_id = (kind << RECORD_KIND_SHIFT) | source_index
## KIND_STATIC_ART is the only kind this phase defines, resolving through
## pak/mixed.pak (art) and pak/items.pak (name/interior/level predicates).
## Every later record table -- Phase 3's models.pak mesh entries, Phase 5's
## equipment-slot families, Phase 8's balance.bin creature and item records
## -- becomes a new KIND_* constant and a new branch in def(). No id already
## written into an ActorState, a replay dump, or a save ever changes when a
## new kind is added; that is the whole reason this shape was chosen over a
## bare mixed.pak index (option-a, rejected) or a separate store per kind
## with a two-field handle (option-c, rejected).
##
## RECORD_KIND_SHIFT := 24 gives RECORD_SOURCE_MASK = 16,777,215 source
## indices per kind -- headroom against mixed.pak's 32096 entries, stated
## rather than left looking arbitrary.
##
## Resolution is O(1): no startup enumeration of mixed.pak's 32096 entries.
## `def()` bounds-checks kind and source before any read and returns the
## SAME shared read-only empty Dictionary for anything outside range --
## never a fresh {} -- so an unknown record id can never be mistaken for "a
## record that happens to be empty" by is_same() or mutated by a careless
## caller (T-01-08, T-01-09).
##
## Nothing here references a node type, the scene tree, the camera, or
## ActorState. It reads Sacred.* and returns plain values.

const RECORD_KIND_SHIFT := 24
const RECORD_SOURCE_MASK := (1 << RECORD_KIND_SHIFT) - 1
const KIND_STATIC_ART := 1

## Generous, not measured: not every one of mixed.pak's 32096 entries is ever
## resolved in one playthrough. The cache does NOT evict -- an evicted
## definition under a live actor's record_id would be exactly the silent
## state loss this store exists to prevent (T-01-10) -- so exceeding this
## bound is reported loudly via push_error rather than fixed silently.
const CACHE_BOUND := 8192

var _items: Sacred.Items
var _mixed: Sacred.Mixed
var _cache: Dictionary[int, Dictionary] = {}
var _empty := {}
var _overflow_warned := false


## Either reader may be null -- the store then opens degraded, exactly as
## main.gd already treats _statics / _mixed / _items (is_open() false,
## count() 0, never an error).
func _init(items: Sacred.Items, mixed: Sacred.Mixed) -> void:
	_items = items
	_mixed = mixed
	_empty.make_read_only()


## `source` outside [0, RECORD_SOURCE_MASK] is rejected loudly rather than
## silently aliased into a different, in-range id by the `&` below --
## matching the house pattern in sacred.gd (Mixed.sprite(),
## Statics.get_object()): push_error + a safe fallback, not assert, because
## assert() is stripped from release builds (see sim.gd's _init() radius
## check for the same reasoning). This is a static helper reachable from
## data-driven callers, so it cannot raise -- it warns and falls back to
## source 0 for the offending call rather than propagating a bad index into
## the id space.
static func make_id(kind: int, source: int) -> int:
	if source < 0 or source > RECORD_SOURCE_MASK:
		push_error("RecordStore.make_id: source %d out of range [0, %d]; using 0" % [source, RECORD_SOURCE_MASK])
		source = 0
	return (kind << RECORD_KIND_SHIFT) | (source & RECORD_SOURCE_MASK)


static func kind_of(record_id: int) -> int:
	return record_id >> RECORD_KIND_SHIFT


static func source_of(record_id: int) -> int:
	return record_id & RECORD_SOURCE_MASK


func is_open() -> bool:
	return _mixed != null


## The mixed.pak entry count, i.e. the size of the KIND_STATIC_ART partition
## -- NOT the size of the whole id space, which is unbounded across kinds.
func count() -> int:
	return _mixed.count() if _mixed != null else 0


## The single resolver. An unknown kind, or a source index that is <= 0 or
## >= count(), returns the SAME shared read-only empty Dictionary -- this is
## the `empty` edge in must_haves.truths, and it is checked BEFORE any read
## so an out-of-range source never indexes into mixed.pak or items.pak.
func def(record_id: int) -> Dictionary:
	var kind := kind_of(record_id)
	var source := source_of(record_id)
	if kind != KIND_STATIC_ART or source <= 0 or source >= count():
		return _empty
	if _cache.has(record_id):
		return _cache[record_id]
	var spr := _mixed.sprite(source)
	var d := {
		"id": record_id,
		"kind": kind,
		"sprite": source,
		"name": _items.name_of(source) if _items != null else "",
		"size": spr.get("size", Vector2i.ZERO) as Vector2i,
		"anchor": spr.get("anchor", Vector2i.ZERO) as Vector2i,
		# Tile COUNT, not the tile array -- def() hands out a summary, not the
		# raw geometry Sacred.Mixed.sprite() already owns.
		"tiles": (spr["tiles"] as Array).size() if spr.has("tiles") else 0,
		"interior": _items.is_interior(source) if _items != null else false,
		"levels": _items.levels(source) if _items != null else 0,
		"top_level": _items.is_top_level(source) if _items != null else false,
	}
	# make_read_only() BEFORE caching: a caller that mutates a def gets a
	# loud engine error instead of silently rewriting the definition every
	# other actor sharing this record_id is reading (T-01-09). Verified by
	# temporarily removing this call: readonly flips to false (recorded in
	# analysis/autoresearch-results.tsv).
	d.make_read_only()
	if _cache.size() >= CACHE_BOUND and not _overflow_warned:
		push_error("RecordStore: def cache exceeded CACHE_BOUND (%d); continuing without eviction, per T-01-10" % CACHE_BOUND)
		_overflow_warned = true
	_cache[record_id] = d
	return d


## Convenience wrapper over def(). "" for an unresolvable record_id.
func name_of(record_id: int) -> String:
	return String(def(record_id).get("name", ""))
