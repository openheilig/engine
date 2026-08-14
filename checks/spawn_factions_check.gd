extends "res://checks/check.gd"
## spawn_factions_check.gd -- the ONE runnable check for the JOIN between the
## three decoded systems: what a sector spawns (Sacred.Funk), what class each
## of those creatures is (Sacred.Creatures) and who fights whom
## (Sacred.Factions).
##
##   godot --headless --path godot-port --script spawn_factions_check.gd
##
## The join is one line -- factions.hostile(HELD, creatures.class_of(id)) -- and
## it needs no renderer, which is the point: it answers "what would actually
## fight the hero in this sector" from data alone, while creatures still cannot
## be drawn.
##
## WHAT THIS CHECK PINS DOWN, and it is a CORRECTION to how rows 729/736
## described the two spawn populations. The tag 0x36 split is NOT a hostility
## split. It correlates strongly with one and it has exceptions in BOTH
## directions, measured over all 14,000 weighted entries:
##
##   0x36 == 100 ("wildlife")  5610 Tier + 132 Untoter        -> 132 hero-hostile
##   0x36 == 310 ("hostile")   12 classes, incl. Soeldner,
##                             Tier and even Pferd            -> 7051 of 8258
##
## So a wildlife roll can put undead on the map, and a hostile roll can put
## mercenaries, animals and horses on it. Calling 0x36 a hostility flag would
## be wrong; calling it a population selector is what the data supports.
##
## The 132 undead inside the wildlife population are worth naming, because they
## look like a bug and are not one to fix: they are ids 524, 526 and 528, 44
## rolls each, and all three name COW.GRN. Every cow in the game carries
## creature.pak class 5, Untoter -- which the matrix turns into hostile-to-the-
## hero. Whether that is a data slip or a deliberate joke, it is what retail
## ships, and reproducing retail exactly is the rule here.
const HELD := 1
const TIER := 6
const UNTOTER := 5
const WANT_WILD_TIER := 5610
const WANT_WILD_UNTOTER := 132
const WANT_HOSTILE_TOTAL := 8258
const WANT_HOSTILE_VS_HERO := 7051


func _init() -> void:
	super()
	var install := Sacred.find_install()
	assert(install != "", "no retail install found; pass --install=/path/to/install")

	var funk := Sacred.Funk.new(install.path_join("bin/type_npc_seraphim"))
	var creatures := Sacred.Creatures.new(install.path_join("pak"))
	var factions := Sacred.Factions.new(install)
	assert(creatures.count() > 400, "creature.pak read %d records" % creatures.count())
	assert(factions.found, "the class matrix was not found")

	var wild: Dictionary[int, int] = {}
	var hostile: Dictionary[int, int] = {}
	for roll in funk.rolls:
		var into: Dictionary[int, int] = (wild if roll["kind"] == Sacred.Funk.WILDLIFE
			else hostile)
		for e: Vector3i in roll["entries"]:
			# JOIN INTEGRITY: every id the spawn tables name must resolve to a
			# class the matrix can index. This is what breaks first if either
			# reader drifts.
			assert(creatures.has(e.x), "spawn id %d is not in creature.pak" % e.x)
			var c := creatures.class_of(e.x)
			assert(c >= 1 and c < Sacred.Factions.N, "id %d has class %d" % [e.x, c])
			into[c] = into.get(c, 0) + 1

	assert(wild.get(TIER, 0) == WANT_WILD_TIER and wild.get(UNTOTER, 0) == WANT_WILD_UNTOTER,
		"wildlife composition moved: %s" % wild)
	assert(wild.size() == 2, "the wildlife population grew a third class: %s" % wild)

	var total := 0
	var vs_hero := 0
	for c: int in hostile:
		total += hostile[c]
		if factions.hostile(HELD, c):
			vs_hero += hostile[c]
	assert(total == WANT_HOSTILE_TOTAL, "hostile entries moved: %d" % total)
	assert(vs_hero == WANT_HOSTILE_VS_HERO,
		"hero-hostile entries moved: want %d, got %d" % [WANT_HOSTILE_VS_HERO, vs_hero])
	# Both directions of the exception must survive, or the correction above has
	# quietly been undone.
	assert(vs_hero < total, "every hostile-population entry now fights the hero")
	assert(wild.get(UNTOTER, 0) > 0, "the wildlife population lost its undead")

	# The per-sector answer, which is the reason the join exists. Sample the
	# busiest sector and report what it would put on the map.
	var best := Vector2i(-1, -1)
	var best_n := 0
	for s: Vector2i in funk.by_sector:
		var n := 0
		for roll in funk.rolls_for(s.x, s.y):
			n += roll["entries"].size()
		if n > best_n:
			best_n = n
			best = s
	var enemy_ids: Dictionary[int, int] = {}
	for roll in funk.rolls_for(best.x, best.y):
		for e: Vector3i in roll["entries"]:
			if factions.hostile(HELD, creatures.class_of(e.x)):
				enemy_ids[e.x] = e.y
	print("spawn_factions_check: join clean over %d entries; wildlife %s, hostile %d of %d fight the hero"
		% [WANT_HOSTILE_TOTAL + WANT_WILD_TIER + WANT_WILD_UNTOTER, wild, vs_hero, total])
	print("  busiest sector %s: %d rolled entries, %d of them hostile to the hero"
		% [best, best_n, enemy_ids.size()])
	finish(0)
