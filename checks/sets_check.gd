extends "res://checks/check.gd"
## sets_check.gd -- the ONE runnable check for Sacred.Sets, the bin/sets.bin
## item-set table (autoresearch rows 923, 924).
##
##   godot --headless --path godot-port --script checks/sets_check.gd
##
## WHAT THIS PROTECTS. Two independent things say the layout is right, and both
## are load-bearing:
##
##   1. `4 + 66*112` is the file exactly, which fixes the stride.
##   2. Field 11 equals `(index << 8) | member_count` for 65 of 65, which ties
##      each record to its OWN POSITION. A stride that has slipped by a record
##      still satisfies (1) and fails (2) on every row -- so the reader rejects
##      the file rather than quietly returning a neighbour's set.
##
## Sacred.Sets asserts (2) on load, so `found` already carries it; this check
## pins the counts and then the part a reader cannot self-check: that field 10
## really is a global.res key. It is negative because it is ALREADY HASHED, and
## reading it as a plain id resolves nothing. All 65 must come back as English.
##
## The named spot check is deliberately recognisable: set 6 is "Uriel's Legacy"
## and it is the Seraphim's own nine pieces. If the name column and the member
## columns ever drift apart, an aggregate "65 resolved" still passes and only
## this notices.
const WANT_COUNT := 65
const WANT_MEMBERS := 378
## Slot occupancy [0..9]. Sets are filled from the front, so this must be
## non-increasing -- that is what says members are packed rather than sparse.
const WANT_OCCUPANCY: Array[int] = [65, 65, 65, 60, 52, 41, 19, 8, 2, 1]

const URIEL := 6
const URIEL_NAME := "Uriel's Legacy"
const URIEL_MEMBERS := 9


func _init() -> void:
	super()
	var install := Sacred.find_install()
	assert(install != "", "no retail install found; pass --install=/path/to/install")
	var s := Sacred.Sets.new(install)
	assert(s.found, "bin/sets.bin did not decode -- the self-index check was rejected")
	assert(s.count == WANT_COUNT, "set count moved: want %d, got %d" % [WANT_COUNT, s.count])
	assert(s.members == WANT_MEMBERS,
		"member slots moved: want %d, got %d" % [WANT_MEMBERS, s.members])

	var res := Sacred.Resources.new(install.path_join("scripts/us/global.res"))
	assert(res.count() > 0, "global.res did not load, so the name column cannot be checked")

	_names(s, res)
	_occupancy(s)
	_uriel(s, res, install)
	_reverse(s)

	print("sets_check OK sets=%d members=%d named=%d" % [s.count, s.members, WANT_COUNT])
	finish(0)


## Field 10 is a pre-hashed global.res key. Every set must resolve, and the
## control is built in: reading the same value as a PLAIN id must resolve
## almost nothing, because a negative number is not a resource number.
func _names(s, res) -> void:
	var ok := 0
	var as_plain := 0
	for i in s.set_indices():
		var key: int = s.name_key(i)
		expect(key < 0, "set %d's name key %d is not negative -- it is not a pre-hashed key" % [i, key])
		if s.name_of(i, res) != "":
			ok += 1
		# The same bits read the way a naive reader would: hash the decimal
		# form instead of masking. If THIS also resolved 65 times the test
		# above would be meaningless.
		if res.by_id(absi(key)) != "":
			as_plain += 1
	expect(ok == WANT_COUNT, "resolved set names moved: want %d, got %d" % [WANT_COUNT, ok])
	expect(as_plain < ok,
		"reading the name key as a plain id resolves %d of %d, as many as the pre-hashed reading -- the control has stopped discriminating"
			% [as_plain, ok])


## Members are packed from slot 0, so occupancy must fall monotonically.
func _occupancy(s) -> void:
	var occ: Array[int] = []
	occ.resize(10)
	occ.fill(0)
	for i in s.set_indices():
		var m: PackedInt32Array = s.members_of(i)
		for k in m.size():
			occ[k] += 1
	for k in 10:
		expect(occ[k] == WANT_OCCUPANCY[k],
			"slot %d occupancy moved: want %d, got %d" % [k, WANT_OCCUPANCY[k], occ[k]])
	for k in 9:
		expect(occ[k] >= occ[k + 1],
			"occupancy rose from slot %d to %d -- members are no longer packed from the front" % [k, k + 1])


## The set a human can name. Uriel's Legacy is the Seraphim suite.
func _uriel(s, res, install: String) -> void:
	expect(s.name_of(URIEL, res) == URIEL_NAME,
		"set %d is %s, not %s" % [URIEL, s.name_of(URIEL, res), URIEL_NAME])
	var m: PackedInt32Array = s.members_of(URIEL)
	if not expect(m.size() == URIEL_MEMBERS,
			"set %d has %d members, want %d" % [URIEL, m.size(), URIEL_MEMBERS]):
		return
	var items := Sacred.Items.new(Sacred.Pak.new(install.path_join("pak/items.pak")))
	for rec in m:
		var nm: String = items.name_of(rec).to_upper()
		expect(nm.begins_with("SERA"),
			"set %d (%s) should be all Seraphim pieces but carries %s" % [URIEL, URIEL_NAME, nm])


## The reverse lookup is the direction the engine actually wants: item in hand,
## which suite does it complete. Every member must find its way home.
func _reverse(s) -> void:
	var wrong := 0
	for i in s.set_indices():
		for rec in s.members_of(i):
			if s.set_of_item(rec) != i:
				wrong += 1
	expect(wrong == 0, "%d members do not resolve back to their own set" % wrong)
	expect(s.set_of_item(-1) == -1, "an unknown item resolved to a set")
