extends "res://checks/check.gd"
## equipment_dress_check.gd -- Wire F: Sacred.Equipment.dress_creature().
##
##   godot --headless --path godot-port --script res://checks/equipment_dress_check.gd
##
## The dress_creature() call site is what closes the integration-debt row in
## analysis/open-questions.md: this is the runnable proof the consumer exists,
## returns the pool's items, and PRESERVES REPEATS (the weight).

const WANT_POOL := 50              ## SHIELD_POOLS[0] -- shields stay shields
const WANT_POOL_SIZE := 2          ## measured for retail (shield pool 50)
const SHIELD_MARK := "SHIELD"


func _init() -> void:
	super()
	var install := Sacred.find_install()
	assert(install != "", "no retail install found; pass --install=/path/to/install")
	var e := Sacred.Equipment.new(install)
	assert(e.found, "bin/wea.bin did not decode")

	var items := Sacred.Items.new(Sacred.Pak.new(install.path_join("pak/items.pak")))

	# (1) The pool id is a stand-in: dress_creature accepts creature + pool.
	# creature is informational only -- there is no measured creature->pool
	# map (row 1166). Two different creature ids against the same pool must
	# return the SAME array.
	var a := e.dress_creature(17095, WANT_POOL)
	var b := e.dress_creature(0, WANT_POOL)
	assert(a.size() == b.size(),
		"dress_creature varies with creature id: %d vs %d" % [a.size(), b.size()])
	for i in a.size():
		assert(a[i] == b[i],
			"dress_creature(creature=17095)[%d]=%d vs creature=0 gives %d"
				% [i, a[i], b[i]])

	# (2) The array matches members_of() exactly, repeats and order.
	var src := e.members_of(WANT_POOL)
	assert(a.size() == src.size() and src.size() == WANT_POOL_SIZE,
		"pool %d: want %d members, got %d (dress_creature) / %d (members_of)"
			% [WANT_POOL, WANT_POOL_SIZE, a.size(), src.size()])
	for i in a.size():
		assert(a[i] == src[i],
			"dress_creature order drifted at %d: %d vs members_of %d"
				% [i, a[i], src[i]])

	# (3) REPEATS ARE PRESERVED. A pool that duplicates a record MUST come
	# back with both copies. Picked as a known duplication -- equipment_check
	# pins this at 906 members across 265 distinct.
	var seen := {}
	var distinct := 0
	var repeats := 0
	for rec in a:
		if seen.has(rec):
			repeats += 1
		else:
			seen[rec] = true
			distinct += 1
	assert(distinct > 0,
		"pool %d returned only repeats -- the weight is gone" % WANT_POOL)
	assert(distinct + repeats == a.size(),
		"distinct+repeats accounting broke: %d+%d != %d"
			% [distinct, repeats, a.size()])

	# (4) Every drawn item is an items.pak record naming a .GRN. Same gate
	# equipment_check applies -- we are not testing it again, just that the
	# new consumer returns the same quality of ids.
	for rec in a:
		var nm: String = items.name_of(rec)
		assert(not nm.is_empty(),
			"dress_creature returned items.pak record %d with no name" % rec)
		assert(nm.to_upper().ends_with(".GRN"),
			"dress_creature record %d names %s, not a .GRN" % [rec, nm])
		assert(nm.to_upper().contains(SHIELD_MARK),
			"pool %d should hold shields, got %s" % [WANT_POOL, nm])

	# (5) An out-of-range pool returns an empty array, NOT a crash.
	var none := e.dress_creature(0, 999)
	assert(none.is_empty(),
		"out-of-range pool returned %d members, want 0" % none.size())
	var empty := e.dress_creature(0, 4)
	assert(empty.is_empty(),
		"empty pool returned %d members, want 0" % empty.size())
	print("equipment_dress_check OK pool=%d size=%d distinct=%d repeats=%d"
		% [WANT_POOL, a.size(), distinct, repeats])
	finish(0)
