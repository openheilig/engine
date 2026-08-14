extends "res://checks/check.gd"
## factions_check.gd -- the ONE runnable check for Sacred.Factions, the 16x16
## creature-class friend/foe matrix (autoresearch row 735).
##
##   godot --headless --path godot-port --script factions_check.gd
##
## THE FINDING THIS CHECK EXISTS TO PROTECT: the matrix is located by its own
## SHAPE, not by an offset, because the retail builds disagree about where it
## sits. A shape search can in principle match the wrong window -- so this check
## does not stop at "found something": it asserts the three facts that make the
## window unmistakably this table, each of which independently agrees with the
## class enum recovered from creature.pak (row 693).
const HELD := 1
const PFERD := 4
const TIER := 6
const FEIND := 13
const WANT_ASYM := 11               ## asymmetric pairs in the shipped matrix
const WANT_ASYM_PFERD := 9          ## of those, how many involve the horse
const HELD_HOSTILE := [2, 5, 8, 9, 10, 11, 12, 13, 14, 15]


func _init() -> void:
	super()
	var install := Sacred.find_install()
	assert(install != "", "no retail install found; pass --install=/path/to/install")
	var f := Sacred.Factions.new(install)
	assert(f.found, "the class matrix was not found in any engine binary under %s" % install)

	# 1. Feind (13) is hostile to everything, itself included. Row 693 called
	#    this class unused in retail; an all-zero row and column is why.
	for i in Sacred.Factions.N:
		assert(f.hostile(FEIND, i), "Feind is friendly to class %d" % i)
		assert(f.hostile(i, FEIND), "class %d is friendly to Feind" % i)

	# 2. Tier is hostile to nothing but Feind -- the wildlife population of the
	#    spawn tables (row 729's tag 0x36 == 100 group) is exactly this class.
	for i in range(1, Sacred.Factions.N):
		if i != FEIND:
			assert(not f.hostile(TIER, i),
				"Tier turned hostile to %s" % Sacred.Factions.CLASS_NAMES[i])

	# 3. The hero's enemy list, which is the recognisable one.
	for i in range(1, Sacred.Factions.N):
		var want: bool = HELD_HOSTILE.has(i)
		assert(f.hostile(HELD, i) == want,
			"Held vs %s: want hostile=%s" % [Sacred.Factions.CLASS_NAMES[i], want])

	# 4. The asymmetry is real and is mostly the horse: enemies ignore the
	#    mount and attack its rider. If a future edit "fixes" the matrix into a
	#    symmetric one, that is a behaviour change, not a cleanup.
	var asym := 0
	var asym_pferd := 0
	for a in range(Sacred.Factions.N):
		for b in range(a + 1, Sacred.Factions.N):
			if f.hostile(a, b) != f.hostile(b, a):
				asym += 1
				if a == PFERD or b == PFERD:
					asym_pferd += 1
	assert(asym == WANT_ASYM, "asymmetric pairs moved: want %d, got %d" % [WANT_ASYM, asym])
	assert(asym_pferd == WANT_ASYM_PFERD,
		"horse asymmetries moved: want %d, got %d" % [WANT_ASYM_PFERD, asym_pferd])

	var enemies: Array[String] = []
	for i in range(1, Sacred.Factions.N):
		if f.hostile(HELD, i):
			enemies.append(Sacred.Factions.CLASS_NAMES[i])
	print("factions_check: matrix at %s+0x%x; Held is hostile to %s; %d asymmetric pairs (%d involve Pferd)"
		% [f.source, f.offset, ", ".join(enemies), asym, asym_pferd])
	finish(0)
