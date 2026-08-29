class_name NpcDressing
extends RefCounted
## NPC-SPAWN DRESSING: at spawn time, choose which items this NPC wears.
##
## Wire F's whole point: the equipment-pool table (Sacred.Equipment) and the
## modifier table (Sacred.Wpmod) are both decoded and gated, but until this
## class lands nothing calls them at runtime. The retail wiring is `equipe` in
## `cEngine::initGame` reading per-class `equip=<class>,<slot>,<itemid>` lines
## out of balance text (autoresearch row 1101) -- except this install ships
## none of those lines, so even retail starts a hero bare. This class is the
## port's reading of the same intent: at NPC-spawn, ask Equipment for the
## weighted draw of pool `pool`, and for every drawn item ask Wpmod for the
## stat block it grants.
##
## WHAT THIS CLASS IS NOT. It does not choose a pool -- there is no measured
## creature-id -> pool map (autoresearch row 1166: every items.pak and
## creature.pak column scanned, none agrees), so a pool argument is REQUIRED.
## A caller that wants to choose from a creature id alone has nothing to
## choose from, and inventing a column would be the kind of behaviour the
## readiness row says not to write.
##
## The repeats on `dress_creature` are PRESERVED: this class hands the array
## straight back so a caller can RNG over it as-is. De-duplication belongs to
## the caller, not to the consumer that is wired into the spawn loop.
##
## Hooking into the items reading path: `Sacred.Items.with_modifier_stats`
## below wraps Sacred.Wpmod.apply_to_item so the items-reading call sites in
## main.gd can stay one-liners without growing an extra import.

const Wpmod := preload("res://formats/wpmod.gd")

var equipment: Sacred.Equipment
var wpmod: Sacred.Wpmod
## Per-record-id memo: avoid re-walking the modifier table for the same item
## twice in one spawn wave. Cleared only at destruction; an NPC's items do not
## change between spawn and death.
var _stats_cache: Dictionary = {}


## Either reader may be null -- degraded mode mirrors Sacred.Equipment's own
## `_init` (push_warning, found=false, no errors raised). A call against the
## null reader returns an empty array / an empty dict.
func _init(eq: Sacred.Equipment, wm: Sacred.Wpmod) -> void:
	equipment = eq
	wpmod = wm


## Every items.pak record id the NPC wears from `pool`, repeats preserved.
## A thin wrapper over Sacred.Equipment.dress_creature kept here so spawn
## code has ONE consumer to import, not two.
func dress_for_spawn(creature: int, pool: int) -> Array[int]:
	if equipment == null or not equipment.found:
		return [] as Array[int]
	return equipment.dress_creature(creature, pool)


## The modifier-stat dict for ONE drawn item, applied additively to `stats`.
## Empty dict on no record, on an out-of-range id, or when Wpmod is absent.
## The cache key is the items.pak record id -- a single NPC's items are read
## at most once even if a spawn wave visits the same record twice.
func stats_for_item(item: int, stats: Dictionary) -> Dictionary:
	if wpmod == null or not wpmod.found:
		return stats.duplicate()
	if _stats_cache.has(item):
		var seed_stats: Dictionary = stats.duplicate()
		for k in _stats_cache[item]:
			seed_stats[k] = int(seed_stats.get(k, 0)) + int(_stats_cache[item][k])
		return seed_stats
	var fresh := wpmod.apply_to_item(item, {})
	_stats_cache[item] = fresh
	var out: Dictionary = stats.duplicate()
	for k in fresh:
		out[k] = int(out.get(k, 0)) + int(fresh[k])
	return out


## The aggregated modifier stats over a whole dressed inventory -- every item
## in `items` applied in order onto a fresh copy of `stats`. Convenient for a
## spawn site that wants one roll-up, not N.
func stats_for_dressed(items: Array, stats: Dictionary) -> Dictionary:
	var out: Dictionary = stats.duplicate()
	for it in items:
		out = stats_for_item(it, out)
	return out
