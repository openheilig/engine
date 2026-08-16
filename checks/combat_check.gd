extends "res://checks/check.gd"
## combat_check.gd -- the ONE runnable check for Combat, the recovered to-hit
## formula (research/engine/combat-formulas.md).
##
##   godot --headless --path godot-port --script checks/combat_check.gd
##
## WHAT THIS PROTECTS. The formula was transcribed from two binaries, so the
## risk is not that it was fitted -- it is that a port QUIETLY CHANGES IT while
## still looking plausible. Every assertion below is chosen so that a natural
## "improvement" breaks it:
##
##   - rounding instead of truncating (retail's int64 cast truncates)
##   - clamping to [0,100] instead of [5,95]
##   - `roll <= chance` instead of `roll < chance` (the call site is strict)
##   - dropping the level term, which leaves equal-rating fights unchanged and
##     only shows up when the levels differ
##
## THE EQUAL-RATING IDENTITY is the one worth stating: with AT == PA and
## ALVL == DLVL the formula is exactly 50, because 200*AT/(2*AT) * 1/2 = 50.
## That is a property of the algebra, not a measurement, so it holds for every
## pair and is checked over a range rather than at one point.
const SEED := 20260816


func _init() -> void:
	super()
	_identity()
	_clamps()
	_levels()
	_strictness()
	_determinism()
	_kernel()
	print("combat_check OK to_hit(100,100,10,10)=%d floor=%d ceiling=%d" % [
		Combat.to_hit(100, 100, 10, 10),
		Combat.to_hit(1, 10000, 1, 10000),
		Combat.to_hit(10000, 1, 10000, 1)])
	finish(0)


## Equal ratings and equal levels is exactly 50, for every pair.
func _identity() -> void:
	for v in [1, 7, 50, 100, 999, 12345]:
		for lv in [1, 5, 50]:
			var h := Combat.to_hit(v, v, lv, lv)
			expect(h == 50, "to_hit(%d,%d,%d,%d) is %d, expected 50" % [v, v, lv, lv, h])


## The clamps are 5 and 95, not 0 and 100.
func _clamps() -> void:
	var lo := Combat.to_hit(1, 100000, 1, 100000)
	var hi := Combat.to_hit(100000, 1, 100000, 1)
	expect(lo == Combat.HIT_MIN, "the floor is %d, expected %d" % [lo, Combat.HIT_MIN])
	expect(hi == Combat.HIT_MAX, "the ceiling is %d, expected %d" % [hi, Combat.HIT_MAX])
	# Degenerate input must not become certainty.
	expect(Combat.to_hit(0, 0, 0, 0) == Combat.HIT_MIN,
		"an all-zero fight is not the floor")


## The LEVEL term. Equal ratings but unequal levels must move the answer, and
## in the right direction -- a higher attacker level helps. Dropping the term
## leaves every one of these at 50.
func _levels() -> void:
	var lowlv := Combat.to_hit(100, 100, 5, 50)
	var highlv := Combat.to_hit(100, 100, 50, 5)
	expect(lowlv < 50, "a level-5 attacker against level 50 scores %d, expected below 50" % lowlv)
	expect(highlv > 50, "a level-50 attacker against level 5 scores %d, expected above 50" % highlv)
	expect(highlv > lowlv, "the level term does not order the two fights")
	# Monotone in the attacker's level, which a sign-flipped term would break.
	var prev := -1
	for lv in [1, 2, 5, 10, 25, 50, 100]:
		var h := Combat.to_hit(100, 100, lv, 20)
		expect(h >= prev, "to-hit fell from %d to %d as the attacker levelled" % [prev, h])
		prev = h


## `roll < chance` is STRICT. At the 5% floor a roll of exactly 5 must MISS;
## `<=` would make it hit and would be invisible in an aggregate hit rate.
func _strictness() -> void:
	var rng := RandomNumberGenerator.new()
	var hits := 0
	var n := 20000
	rng.seed = SEED
	for i in n:
		if Combat.resolve(100, 100, 10, 10, rng)["hit"]:
			hits += 1
	# 50% chance over rand(0..100) inclusive: 50 of 101 outcomes hit, so the
	# expected rate is 0.495 rather than 0.5. Asserting 0.5 exactly would be
	# asserting the wrong arithmetic.
	var rate := float(hits) / float(n)
	expect(absf(rate - 50.0 / 101.0) < 0.02,
		"a 50%% fight hit %.4f of the time, expected about %.4f" % [rate, 50.0 / 101.0])
	# The floor really is nearly always a miss.
	rng.seed = SEED
	var floor_hits := 0
	for i in n:
		if Combat.resolve(1, 100000, 1, 100000, rng)["hit"]:
			floor_hits += 1
	var frate := float(floor_hits) / float(n)
	expect(absf(frate - 5.0 / 101.0) < 0.01,
		"the 5%% floor hit %.4f of the time, expected about %.4f" % [frate, 5.0 / 101.0])


## The same seed must give the same fight, or record/replay cannot survive
## anyone swinging a sword.
func _determinism() -> void:
	var a: Array[int] = []
	var b: Array[int] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	for i in 64:
		a.append(int(Combat.resolve(120, 80, 12, 10, rng)["roll"]))
	rng.seed = SEED
	for i in 64:
		b.append(int(Combat.resolve(120, 80, 12, 10, rng)["roll"]))
	expect(a == b, "two runs from the same seed disagree -- combat is not replayable")


## The derived-stat kernel's two PINNED POINTS, which are properties of the
## algebra rather than measurements: K(0) = BalStatOff + 9 for any offset, and
## K(156) = 165 for any offset. A transcription error in either coefficient
## breaks at least one of them, and the second is the sharper -- it holds only
## because the slope and intercept are tied to each other.
func _kernel() -> void:
	for off in [0.0, 20.0, 77.0, 156.0]:
		expect(absf(Combat.stat_kernel(0.0, off) - (off + 9.0)) < 1e-4,
			"K(0) with offset %.1f is %.4f, expected %.4f" % [off, Combat.stat_kernel(0.0, off), off + 9.0])
		expect(absf(Combat.stat_kernel(Combat.STAT_SPAN, off) - Combat.STAT_CEILING) < 1e-4,
			"K(156) with offset %.1f is %.4f, expected %.1f" % [
				off, Combat.stat_kernel(Combat.STAT_SPAN, off), Combat.STAT_CEILING])
	# Retail's shipped offset gives the reduced form 0.8718*S + 29.
	expect(absf(Combat.stat_kernel(0.0) - 29.0) < 1e-4, "retail K(0) is not 29")
	expect(absf(Combat.stat_kernel(100.0) - (0.8717948 * 100.0 + 29.0)) < 1e-3,
		"retail K(100) does not match 0.8718*S + 29")
	# Monotone increasing, which a sign error would break while leaving the two
	# pinned points intact.
	var prev := -1.0
	for s2 in [0.0, 1.0, 35.0, 80.0, 156.0]:
		var v := Combat.stat_kernel(s2)
		expect(v > prev, "the kernel fell from %.3f to %.3f" % [prev, v])
		prev = v
