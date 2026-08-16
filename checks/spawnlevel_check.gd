extends "res://checks/check.gd"
## spawnlevel_check.gd -- the ONE runnable check for Sacred.SpawnLevels: the
## per-sector level band that a spawned creature's level is drawn from
## (autoresearch row 953).
##
##   godot --headless --path godot-port --script checks/spawnlevel_check.gd
##
## THE CONTROL IS GEOGRAPHIC, and it is the whole reason this reads as a LEVEL
## band rather than a percentage, a weight or a spawn count. Seven of the nine
## classes declare a StartPosition in a sector that carries a band, and every
## one of those seven is the LOWEST band in the game, (1, 4). A number that was
## not a level would not land that way on exactly the sectors where a level-1
## character begins.
##
## The Daemoness is the counter-example that keeps the test honest: she starts
## at 5,26 in a (45, 80) band, so "every start is (1,4)" is NOT what is being
## asserted -- the claim is that starts sit where their own class begins, and
## hers is a high-level region in retail too.
const TREE := "bin/type_npc_seraphim"
const WANT_SECTORS := 5666
## Sectors declaring MORE THAN ONE band. Pinned so the ambiguity is a measured
## fact in the gate rather than a warning nobody reads.
const WANT_MULTI := 60
const LOWEST := Vector2i(1, 4)
## Class start cells, from Startcode.start_cell (row 939), as sectors.
const STARTS_LOW: Array[Vector2i] = [
	Vector2i(50, 39),   # seraphim
	Vector2i(51, 39),   # magician
	Vector2i(53, 42),   # darkelve
	Vector2i(54, 43),   # zwerg
	Vector2i(59, 5),    # gladiator / netscriptcamp
]
const DAEMON_START := Vector2i(5, 26)
const DAEMON_BAND := Vector2i(45, 80)
const UNDERWORLD_START := Vector2i(97, 60)


func _init() -> void:
	super()
	var install := Sacred.find_install()
	assert(install != "", "no retail install found; pass --install=/path/to/install")
	var sl = Sacred.SpawnLevels.new(install.path_join(TREE))
	assert(sl.found, "no SpawnValues bands were read")
	assert(sl.sectors == WANT_SECTORS,
		"sectors carrying a band moved: want %d, got %d" % [WANT_SECTORS, sl.sectors])
	assert(sl.multi == WANT_MULTI,
		"sectors with several bands moved: want %d, got %d" % [WANT_MULTI, sl.multi])

	_ordering(sl)
	_starts(sl)
	print("spawnlevel_check OK sectors=%d multi=%d records=%d start=%s daemon=%s" % [
		sl.sectors, sl.multi, sl.records, sl.band(50, 39),
		sl.band(DAEMON_START.x, DAEMON_START.y)])
	finish(0)


## Every band is ordered and inside the range the corpus shows. The reader
## already refuses an unordered triple, so this is checking that the refusal
## has not quietly emptied the table.
func _ordering(sl) -> void:
	var lo_min := 999
	var hi_max := 0
	var bad := 0
	for cx in 100:
		for cy in 128:
			if not sl.has_band(cx, cy):
				continue
			var b: Vector2i = sl.band(cx, cy)
			if b.x > b.y or b.x < 1 or b.y > 100:
				bad += 1
			lo_min = mini(lo_min, b.x)
			hi_max = maxi(hi_max, b.y)
	expect(bad == 0, "%d sectors carry a band outside 1..100 or unordered" % bad)
	expect(lo_min == 1, "the lowest band floor is %d, expected 1" % lo_min)
	expect(hi_max == 80, "the highest band ceiling is %d, expected 80" % hi_max)


## THE GEOGRAPHIC CONTROL.
func _starts(sl) -> void:
	for s in STARTS_LOW:
		expect(sl.has_band(s.x, s.y), "start sector %d,%d carries no band" % [s.x, s.y])
		expect(sl.band(s.x, s.y) == LOWEST,
			"start sector %d,%d is band %s, expected the game's lowest %s" % [
				s.x, s.y, sl.band(s.x, s.y), LOWEST])
	# The counter-example. If this ever became (1,4) the test above would have
	# stopped discriminating -- it would just be saying every sector is low.
	expect(sl.band(DAEMON_START.x, DAEMON_START.y) == DAEMON_BAND,
		"the Daemoness's start is band %s, expected %s" % [
			sl.band(DAEMON_START.x, DAEMON_START.y), DAEMON_BAND])
	expect(sl.band(UNDERWORLD_START.x, UNDERWORLD_START.y) != LOWEST,
		"the Underworld start is the lowest band, which would make the control vacuous")
	# And the population as a whole is NOT mostly the lowest band, or landing on
	# it five times would be chance.
	var lowest := 0
	var total := 0
	for cx in 100:
		for cy in 128:
			if not sl.has_band(cx, cy):
				continue
			total += 1
			if sl.band(cx, cy) == LOWEST:
				lowest += 1
	expect(total > 1000, "only %d sectors carry a band" % total)
	expect(float(lowest) / float(total) < 0.25,
		"%d of %d sectors are the lowest band (%.1f%%) -- hitting it on five starts proves nothing"
			% [lowest, total, 100.0 * lowest / total])
