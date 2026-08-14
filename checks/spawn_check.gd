extends "res://checks/check.gd"
## spawn_check.gd -- the ONE runnable check for Sacred.Funk, the spawn tables in
## bin/TYPE_NPC_*/funkcode.bin.
##
##   godot --headless --path godot-port --script spawn_check.gd
##
## THE FINDING THIS CHECK EXISTS TO PROTECT (autoresearch rows 728-730): opcodes
## 51/115 are the random monster spawn system, and the proof is an id join --
## every creature id they name is a creature.pak id. If a future edit to the tag
## widths or the record walk breaks, that join is what stops agreeing first: a
## mis-sized tag shifts the cursor and the ids turn into garbage that is still
## structurally parseable, because every unlisted tag below 0xa2 is a zero-width
## no-op in the engine and absorbs the damage silently.
##
## The counts below are for ONE class's funkcode.bin. All ten shipped copies are
## byte-identical in these records, so any of them serves.
const CREATURE_DATA := 256
const CREATURE_REC := 86
const CREATURE_COUNT := 474
const WANT_ROLLS := 5309
const WANT_WILDLIFE := 2854
const WANT_HOSTILE := 2455
const WANT_GROUPS := 22762
const WANT_SECTOR := 11498
const WANT_SUM100 := 3906           ## rolls whose percents sum to exactly 100
const WILDLIFE_IDS := 12            ## distinct ids in the wildlife population
const WANT_SECTORS := 5684          ## grid sectors carrying at least one spawn record
const WANT_REAL := 5659             ## of those, how many the world actually has
const WANT_HOSTILE_SECTORS := 2453  ## grid sectors carrying a hostile roll
const WANT_DUNGEON := 93            ## records in the id-keyed "Sector%d" procedures


func _init() -> void:
	super()
	var install := Sacred.find_install()
	assert(install != "", "no retail install found; pass --install=/path/to/install")

	var dir := install.path_join("bin/type_npc_seraphim")
	assert(FileAccess.file_exists(dir.path_join("funkcode.bin")), "missing funkcode.bin in %s" % dir)
	assert(FileAccess.file_exists(dir.path_join("vectoren.bin")), "missing vectoren.bin in %s" % dir)
	var funk := Sacred.Funk.new(dir)

	assert(funk.rolls.size() == WANT_ROLLS,
		"opcode 51 count moved: want %d, got %d" % [WANT_ROLLS, funk.rolls.size()])
	assert(funk.groups.size() == WANT_GROUPS,
		"opcode 115 count moved: want %d, got %d" % [WANT_GROUPS, funk.groups.size()])
	assert(funk.sector_params.size() == WANT_SECTOR,
		"opcode 100 count moved: want %d, got %d" % [WANT_SECTOR, funk.sector_params.size()])

	# The creature id set, read the way creature_check.gd reads it: a flat CIF
	# table, NOT a Sacred.Pak container.
	var cb := FileAccess.get_file_as_bytes(install.path_join("pak/creature.pak"))
	assert(CREATURE_DATA + CREATURE_COUNT * CREATURE_REC == cb.size(), "creature.pak stride moved")
	var creature_ids := {}
	for i in CREATURE_COUNT:
		creature_ids[cb.decode_u32(CREATURE_DATA + i * CREATURE_REC)] = true

	var wildlife := {}
	var hostile := {}
	var sum100 := 0
	var entries := 0
	for roll in funk.rolls:
		var total := 0
		for e: Vector3i in roll["entries"]:
			entries += 1
			assert(creature_ids.has(e.x), "roll names id %d, which is not in creature.pak" % e.x)
			assert(e.y >= 0 and e.y <= 100, "weight %d out of range" % e.y)
			total += e.y
			if roll["kind"] == Sacred.Funk.WILDLIFE:
				wildlife[e.x] = true
			else:
				hostile[e.x] = true
		if total == 100:
			sum100 += 1
		# The 0x34/0x33 pair is the real discriminator: hostile records always
		# carry it, wildlife records never do. Entry COUNT is not -- it runs
		# 1..4 in both populations (hostile: 59/414/557/1425, wildlife:
		# 1724/132/238/760). An earlier note calling hostile records "exactly
		# four entries" read a median as a rule; this assertion is what caught it.
		assert(roll["entries"].size() >= 1 and roll["entries"].size() <= 4,
			"a roll has %d entries, want 1..4" % roll["entries"].size())
		if roll["kind"] == Sacred.Funk.HOSTILE:
			assert(roll["has_pairs"], "a hostile roll is missing the 0x34/0x33 fields")
		else:
			assert(roll["kind"] == Sacred.Funk.WILDLIFE,
				"unexpected tag 0x36 value %d" % roll["kind"])
			assert(not roll["has_pairs"],
				"a wildlife roll carries the hostile-only 0x34/0x33 fields")
		assert(roll["count_min"] <= roll["count_max"], "0x35 range is unordered")

	assert(sum100 == WANT_SUM100, "weight-sum-100 rolls moved: want %d, got %d" % [WANT_SUM100, sum100])
	assert(wildlife.size() == WILDLIFE_IDS,
		"wildlife population moved: want %d ids, got %d" % [WILDLIFE_IDS, wildlife.size()])
	assert(hostile.size() > 200, "hostile population collapsed to %d ids" % hostile.size())
	var w := 0
	var h := 0
	for roll in funk.rolls:
		if roll["kind"] == Sacred.Funk.WILDLIFE:
			w += 1
		else:
			h += 1
	assert(w == WANT_WILDLIFE and h == WANT_HOSTILE,
		"population split moved: %d wildlife / %d hostile" % [w, h])

	# Opcode 115's ids are creature ids too, and its first number is always 50
	# for opcode 100 (rows 728).
	for g in funk.groups:
		for id: int in g["ids"]:
			assert(creature_ids.has(id), "group names id %d, not in creature.pak" % id)
	for rec in funk.sector_params:
		var v: PackedInt32Array = rec["values"]
		assert(v.size() >= 1 and v[0] == 50, "opcode 100's first operand is not 50")

	# PLACEMENT (row 732). vectoren.bin is the procedure table and every spawn
	# record falls inside a Sector<gx><gy>{Init,Enter} procedure -- that is what
	# says WHERE a group spawns. Zero orphans is the load-bearing assertion: an
	# off-by-one in the procedure table or the record walk shows up here first.
	var orphan := 0
	var dungeon := 0
	var sectors := {}
	for rec in funk.rolls + funk.groups + funk.sector_params:
		var s: Vector2i = rec["sector"]
		if s == Vector2i(-1, -1):
			orphan += 1
		elif s.x < 0:
			dungeon += 1        # the id-keyed "Sector%d" form, not a grid sector
		else:
			sectors[s] = true
	assert(orphan == 0, "%d spawn records belong to no Sector procedure" % orphan)
	assert(dungeon == WANT_DUNGEON,
		"id-keyed sector records moved: want %d, got %d" % [WANT_DUNGEON, dungeon])
	assert(sectors.size() == WANT_SECTORS,
		"sector coverage moved: want %d, got %d" % [WANT_SECTORS, sectors.size()])
	# The name is Sector%d%3.3d and the format alone leaves the order open, so
	# the reading is pinned against the world: nearly every script sector must
	# be a sector the world actually has. Swapping gx/gy drops this to 4013.
	var world := Sacred.World.new(install.path_join("world"))
	var real := 0
	for s: Vector2i in sectors:
		if world.has_sector(s.x, s.y):
			real += 1
	assert(real == WANT_REAL,
		"only %d of %d script sectors exist in the world -- gx/gy are probably swapped"
			% [real, sectors.size()])
	# A town sector carries no monster roll; a wilderness one does.
	assert(funk.rolls_for(50, 39).is_empty(), "the chapel sector (50,39) grew a spawn roll")
	var hostile_sectors := 0
	for s: Vector2i in sectors:
		for roll in funk.rolls_for(s.x, s.y):
			if roll["kind"] == Sacred.Funk.HOSTILE:
				hostile_sectors += 1
				break
	assert(hostile_sectors == WANT_HOSTILE_SECTORS,
		"hostile sector count moved: want %d, got %d" % [WANT_HOSTILE_SECTORS, hostile_sectors])

	# The weighted pick only ever returns an id the record actually lists.
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	for roll in funk.rolls.slice(0, 200):
		var listed := {}
		for e: Vector3i in roll["entries"]:
			listed[e.x] = true
		for _i in 20:
			var got := funk.pick(roll, rng)
			assert(listed.has(got), "pick returned %d, which the record does not list" % got)

	print("spawn_check: %d rolls (%d wildlife / %d hostile), %d entries, %d groups, %d sector records; all ids in creature.pak; placed in %d sectors (%d real, %d hostile)"
		% [funk.rolls.size(), w, h, entries, funk.groups.size(), funk.sector_params.size(),
			sectors.size(), real, hostile_sectors])
	finish(0)
