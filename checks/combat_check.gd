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
	_ratings()
	_base_ratings()
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


## THE RATING CURVE and the balance triplets that feed it.
##
## The load-bearing assertion is the LAST one: exactly two families carry a VW
## triplet. That is the whole answer to "which attribute becomes PA" -- none
## does, and defence comes from Agility and Constitution. If a future edit
## added a family to VW because it looked symmetric with AW, this fails.
func _ratings() -> void:
	# Algebra first, independent of any file. f(1) = off for every triplet,
	# because the (S-1) term vanishes -- a curve that returned `off` for S < 1
	# too would pass every rate check and fail this pair.
	for off in [4.0, 7.0, 13.0]:
		expect(absf(Combat.skill_rating(off, 1.0, 50.0, 200.0) - off) < 1e-4,
			"f(1) with off %.1f is %.4f, expected %.1f" % [off, Combat.skill_rating(off, 1.0, 50.0, 200.0), off])
		expect(Combat.skill_rating(off, 0.99, 50.0, 200.0) == 0.0,
			"an untrained skill returns %.4f, expected 0" % Combat.skill_rating(off, 0.99, 50.0, 200.0))
	# Saturating and monotone, approaching off + 2*(w-off) without reaching it.
	var off2 := 13.0
	var w2 := 225.0
	var ceiling := off2 + 2.0 * (w2 - off2)
	var prev := -1.0
	for lv in [1.0, 2.0, 10.0, 50.0, 200.0, 5000.0]:
		var v := Combat.skill_rating(off2, lv, 50.0, w2)
		expect(v > prev, "the rating fell from %.3f to %.3f" % [prev, v])
		expect(v < ceiling, "the rating reached %.3f, at or past its %.3f ceiling" % [v, ceiling])
		prev = v
	# At the half-way scale the curve is exactly half of its own span.
	expect(absf(Combat.skill_rating(off2, 1.0 + 50.0, 50.0, w2) - (off2 + (w2 - off2))) < 1e-3,
		"f(1+s) is not off + (w-off)")

	# Now the file. The triplets must actually be there and be ordered off < w,
	# or the offsets in Sacred.Balance name the wrong slots.
	var install := Sacred.find_install()
	var bal = Sacred.Balance.new(install)
	expect(bal.found, "bin/balance.bin did not load")
	for fam in bal.families(Sacred.Balance.AW):
		var t: Vector3 = bal.triplet(Sacred.Balance.AW, fam)
		expect(t.x > 0.0 and t.z > t.x,
			"AW triplet %s is %s, expected 0 < off < w" % [fam, t])
		expect(t.y > 0.0, "AW triplet %s has a zero scale" % fam)
	for fam in bal.families(Sacred.Balance.VW):
		var t: Vector3 = bal.triplet(Sacred.Balance.VW, fam)
		expect(t.x > 0.0 and t.z > t.x,
			"VW triplet %s is %s, expected 0 < off < w" % [fam, t])
	# Named values, so a shifted offset is caught by a number a human can check
	# against the key map rather than by a range.
	var w_aw: Vector3 = bal.triplet(Sacred.Balance.AW, "W")
	var w_vw: Vector3 = bal.triplet(Sacred.Balance.VW, "W")
	expect(w_aw.is_equal_approx(Vector3(7.0, 50.0, 125.0)),
		"WoffAW/W__sAW/W__wAW is %s, expected (7, 50, 125)" % w_aw)
	expect(w_vw.is_equal_approx(Vector3(13.0, 50.0, 225.0)),
		"WoffVW/W__sVW/W__wVW is %s, expected (13, 50, 225)" % w_vw)
	expect(absf(bal.f32(Sacred.Balance.VW_FAK_BOSS) - 2.0) < 1e-4, "VWFakBoss is not 2.0")
	expect(absf(bal.f32(Sacred.Balance.BAL_STAT_OFF) - Combat.BAL_STAT_OFF) < 1e-4,
		"balance.bin BalStatOff disagrees with the constant Combat ships")

	# THE FINDING. Ten families have an attack rating; exactly TWO have a
	# defence rating. Defence is Agility and Constitution, and nothing else.
	expect(Sacred.Balance.AW.size() == 9,
		"AW families moved: %d, expected 9 that map to a skill" % Sacred.Balance.AW.size())
	expect(Sacred.Balance.VW.size() == 2,
		"VW families moved: %d, expected 2 (Agility and Constitution)" % Sacred.Balance.VW.size())
	expect(Sacred.Balance.VW.has("W") and Sacred.Balance.VW.has("HP"),
		"the two VW families are no longer Agility and Constitution")


## THE BASE RATINGS (row 959) -- the last invented quantity in a fight, and the
## thing `_ratings` above could only describe the shape of.
##
## Every assertion is a property of the transcribed coefficients rather than a
## measured number, so a coefficient typo breaks at least one:
##
##   attack weights STR and DEX EQUALLY   (0.5 / 0.5)
##   defence weights DEX FOUR TIMES STR   (0.2 / 0.8)
##   both are 1.0 per point of gear
##
## The asymmetry is the load-bearing part: an implementation that used the same
## split for both would pass a spot check on equal attributes and fail here.
func _base_ratings() -> void:
	# Equal attributes: attack is that value, defence is that value. Both
	# coefficient pairs sum to 1, which is what makes this hold.
	for v in [10, 25, 47, 100]:
		expect(absf(Combat.base_attack(v, v) - float(v)) < 1e-4,
			"base_attack(%d,%d) is %.3f, expected %d" % [v, v, Combat.base_attack(v, v), v])
		expect(absf(Combat.base_defence(v, v) - float(v)) < 1e-4,
			"base_defence(%d,%d) is %.3f, expected %d" % [v, v, Combat.base_defence(v, v), v])
	# UNEQUAL is where the two formulas separate. Dexterity is worth four times
	# Strength on defence and exactly as much on attack.
	expect(absf(Combat.base_attack(100, 0) - Combat.base_attack(0, 100)) < 1e-4,
		"attack is not symmetric in STR and DEX")
	expect(absf(Combat.base_defence(0, 100) - 4.0 * Combat.base_defence(100, 0)) < 1e-4,
		"defence does not weight DEX four times STR")
	# Gear is a flat point-for-point add on both.
	expect(absf(Combat.base_attack(10, 10, 7) - (10.0 + 7.0)) < 1e-4, "gear is not 1:1 on attack")
	expect(absf(Combat.base_defence(10, 10, 7) - (10.0 + 7.0)) < 1e-4, "gear is not 1:1 on defence")
	# Never negative: CalcResults clamps both at 0 after the modifier pass.
	expect(Combat.base_attack(-100, -100) == 0.0, "a negative base attack was not clamped")

	# THE RATING ASSEMBLY. base x multiplier x proz, and the multiplier is 1.0
	# for a character with no skill in an AW or VW family.
	expect(absf(Combat.rating(20.0) - 20.0) < 1e-4, "a bare rating is not its base")
	expect(absf(Combat.rating(20.0, 2.0, 1.5) - 60.0) < 1e-4, "the rating product is wrong")

	# THE TWO REAL SUBJECTS, so the gate breaks if either data source moves.
	# A new Seraphim is STK 22 / GES 25; the Ghoul at monster107 is 33 / 24.
	var sera_at := Combat.base_attack(22, 25)
	var ghoul_pa := Combat.base_defence(33, 24)
	expect(absf(sera_at - 23.5) < 1e-4, "the new Seraphim's attack base is %.2f" % sera_at)
	expect(absf(ghoul_pa - 25.8) < 1e-4, "the Ghoul's defence base is %.2f" % ghoul_pa)
	# She is the WEAKER of the two on these numbers, which is why the fight is
	# not a foregone conclusion in either direction.
	expect(sera_at < ghoul_pa, "the level-1 Seraphim now out-attacks the Ghoul's defence")
	var hit := Combat.to_hit(int(sera_at), int(ghoul_pa), 1, 2)
	expect(hit > Combat.HIT_MIN and hit < 50,
		"the MVP fight is %d%%, expected between the floor and even" % hit)

	# ProzAW, the one balance.bin key on this path. It multiplies a NON-HERO's
	# ratings only, and it rises steeply: a monster on Niob is 4.5x its own
	# numbers. If this ever read 1.0 across the board the difficulty tiers have
	# stopped differing.
	var bal2 = Sacred.Balance.new(Sacred.find_install())
	var proz := PackedFloat32Array()
	for d in [1, 2, 3, 4]:
		proz.append(bal2.proz_aw(d))
	expect(absf(proz[0] - 1.0) < 1e-4, "ProzAW on Silver is %.2f, expected 1.0" % proz[0])
	expect(absf(proz[3] - 4.5) < 1e-4, "ProzAW on Niob is %.2f, expected 4.5" % proz[3])
	for i in 3:
		expect(proz[i + 1] > proz[i], "ProzAW does not rise from difficulty %d to %d" % [i + 1, i + 2])
	print("combat_check\tbase OK\tsera_AT=%.1f\tghoul_PA=%.1f\thit=%d%%\tProzAW=%s" % [
		sera_at, ghoul_pa, hit, proz])
