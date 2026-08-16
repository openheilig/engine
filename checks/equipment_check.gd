extends "res://checks/check.gd"
## equipment_check.gd -- the ONE runnable check for Sacred.Equipment, the
## bin/wea.bin equipment pools (autoresearch row 923).
##
##   godot --headless --path godot-port --script checks/equipment_check.gd
##
## WHAT THIS PROTECTS. wea.bin has no header of any kind -- no magic, no
## version, no count. The only thing that says the layout is right is that 256
## groups of `u32 n` + n ids consume the file exactly, so Sacred.Equipment
## refuses to report found unless they do and the first assertion is the whole
## decode.
##
## The reader deliberately does NOT validate members against items.pak, so that
## a 4.6 KB table does not cost every caller a 4.5 MB items.pak load. That
## corroboration lives here instead: all 906 members must name a `.GRN`. If
## fixed-width ids ever stop being items.pak records, this is what says so.
##
## THE REPEATS ARE THE WEIGHTING and this check pins that too. 906 member slots
## span only 265 distinct records, so a pool is a weighted draw and a caller
## that deduplicates changes the odds. `members > distinct` is asserted for
## exactly that reason -- if a future edit makes members_of() return a set, the
## counts collapse and this fails.
const WANT_POOLS := 256
const WANT_FILLED := 114
const WANT_MEMBERS := 906
const WANT_DISTINCT := 265
const WANT_MIN_SIZE := 1
const WANT_MAX_SIZE := 32

## Four pools a human can verify at a glance: all shields, and they stay
## shields. An aggregate count cannot tell anyone the table was transposed.
const SHIELD_POOLS: Array[int] = [50, 51, 52, 224]


func _init() -> void:
	super()
	var install := Sacred.find_install()
	assert(install != "", "no retail install found; pass --install=/path/to/install")
	var e := Sacred.Equipment.new(install)
	assert(e.found, "bin/wea.bin did not decode -- the 256-group parse was rejected")
	assert(e.pools == WANT_POOLS, "pool count moved: want %d, got %d" % [WANT_POOLS, e.pools])
	assert(e.filled == WANT_FILLED, "filled pools moved: want %d, got %d" % [WANT_FILLED, e.filled])
	assert(e.members == WANT_MEMBERS, "member slots moved: want %d, got %d" % [WANT_MEMBERS, e.members])

	var items := Sacred.Items.new(Sacred.Pak.new(install.path_join("pak/items.pak")))
	_members_are_items(e, items)
	_weighting(e)
	_shields(e, items)

	print("equipment_check OK pools=%d filled=%d members=%d distinct=%d"
		% [e.pools, e.filled, e.members, WANT_DISTINCT])
	finish(0)


## Every member is an items.pak record naming a mesh. This is the range check
## the reader leaves to the gate.
func _members_are_items(e, items) -> void:
	var bad := 0
	for p in e.pools:
		for rec in e.members_of(p):
			var nm: String = items.name_of(rec)
			if not nm.to_upper().ends_with(".GRN"):
				bad += 1
	expect(bad == 0,
		"%d of %d wea.bin members do not name a .GRN -- they are not items.pak records"
			% [bad, e.members])


## Repeats are the weighting, not noise. See the header.
func _weighting(e) -> void:
	var seen: Dictionary[int, bool] = {}
	var lo := 1 << 30
	var hi := 0
	for p in e.pools:
		var g: PackedInt32Array = e.members_of(p)
		if g.is_empty():
			continue
		lo = mini(lo, g.size())
		hi = maxi(hi, g.size())
		for rec in g:
			seen[rec] = true
	expect(seen.size() == WANT_DISTINCT,
		"distinct pool members moved: want %d, got %d" % [WANT_DISTINCT, seen.size()])
	expect(e.members > seen.size(),
		"member slots (%d) no longer exceed distinct members (%d) -- the pools have been deduplicated and the draw weights are gone"
			% [e.members, seen.size()])
	expect(lo == WANT_MIN_SIZE and hi == WANT_MAX_SIZE,
		"pool size range moved: want %d..%d, got %d..%d" % [WANT_MIN_SIZE, WANT_MAX_SIZE, lo, hi])


## The named spot check: four shield pools stay shields.
func _shields(e, items) -> void:
	for p in SHIELD_POOLS:
		var g: PackedInt32Array = e.members_of(p)
		if not expect(g.size() > 0, "shield pool %d is empty" % p):
			continue
		for rec in g:
			var nm: String = items.name_of(rec).to_upper()
			expect(nm.contains("SHIELD"),
				"pool %d should hold shields but carries %s" % [p, nm])
