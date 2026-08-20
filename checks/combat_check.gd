extends "res://checks/check.gd"
## combat_check.gd -- the ONE runnable check for Combat, the recovered to-hit
## formula (research/engine/combat-formulas.md).
##
##   godot --headless --path godot-port --script checks/combat_check.gd
##
## WHAT THIS PROTECTS. The arithmetic is transcribed from retail and then
## CONFIRMED LIVE under gdb, so the risk is not that it was fitted -- it is that
## a port QUIETLY CHANGES IT while still looking plausible. Every assertion is
## chosen so that a natural "improvement" breaks it:
##
##   - re-introducing the 5/95 clamp, which retail does not have
##   - re-introducing a level term into ACCURACY, where retail has none
##   - `roll <= chance` instead of `roll < chance` (measured strict)
##   - rolling randf() or 0..100 instead of retail's 1001 discrete outcomes
##   - making the level term two-sided, which would penalise the weaker attacker
##   - dropping the a5 ceiling, which is what stops k reaching ln(0)
##
## THE LIVE FIXTURES are the load-bearing part. Every number in `_retail_*`
## below was printed by the retail binary itself at a breakpoint, so they check
## the implementation against the subject rather than against its own algebra.
const SEED := 20260816

## Captured at 0x81fc733 in install/sacred: the to-hit curve's own inputs and
## the fraction it produced. 19.5/(19.5+26.4) to six places.
const RETAIL_AT := 19.5
const RETAIL_PA := 26.4
const RETAIL_CHANCE := 0.424837

## Captured at 0x81FD08D/0x81FD1F5: raw damage, armour, and the result, all on
## channel 0 with every resist byte zero. The first four ran at k = 1; the last
## two ran with the level term forced to 1.5, i.e. k = 2.
const RETAIL_ARMOUR := 2.241398
const RETAIL_DMG_K1 := [
	[23.291998, 21.247356], [23.184000, 21.140194],
	[20.844000, 18.820223], [21.824999, 19.792351]]
const RETAIL_DMG_K2 := [[21.185999, 20.992071], [23.210999, 23.030998]]


func _init() -> void:
	super()
	_curve()
	_retail_hit_chance()
	_no_clamp()
	_levels()
	_strictness()
	_retail_damage()
	_determinism()
	_kernel()
	_ratings()
	_base_ratings()
	print("combat_check OK chance(%.1f,%.1f)=%.6f expected %.6f" % [
		RETAIL_AT, RETAIL_PA, Combat.hit_chance(RETAIL_AT, RETAIL_PA), RETAIL_CHANCE])
	finish(0)


## THE SHARED CURVE. Its two guards are the parts a rewrite would drop, because
## both look like defensive noise until you need them.
func _curve() -> void:
	# k = 1 reduces the fraction to a2/(a2+a3), which is the whole reason
	# to-hit can be written as a ratio. A wrong exponent breaks this at once.
	for a in [1.0, 7.5, 50.0, 1234.0]:
		for b in [0.5, 7.5, 99.0]:
			var f := Combat.curve_fraction(a, b, 1.0, 0.5)
			expect(absf(f - a / (a + b)) < 1e-5,
				"k=1 curve(%.1f,%.1f) is %.6f, expected %.6f" % [a, b, f, a / (a + b)])
	# The a5 CEILING. Anything at or past 1.0 is 0.99, so k tops out at 6.64
	# instead of reaching ln(0). Without this the level term goes undefined.
	expect(absf(Combat.curve_fraction(10.0, 3.0, 1.0, 1.5)
		- Combat.curve_fraction(10.0, 3.0, 1.0, Combat.A5_CEILING)) < 1e-9,
		"an a5 past 1.0 is not clamped to the ceiling")
	# The NO-ARMOUR branch: |a3| under the threshold takes the 10000 ratio, so
	# an unarmoured target takes essentially everything and not a division by 0.
	var bare := Combat.curve_fraction(10.0, 0.0, 1.0, 0.5)
	expect(absf(bare - (1.0 - 1.0 / (Combat.NO_ARMOUR_RATIO + 1.0))) < 1e-9,
		"zero armour is %.6f, expected the 10000-ratio branch" % bare)
	expect(bare > 0.9999, "zero armour does not pass essentially full effect")
	# Monotone in both arguments, which a sign slip would break while leaving
	# the reduced form intact at single points.
	expect(Combat.curve_fraction(20.0, 5.0) > Combat.curve_fraction(10.0, 5.0),
		"more attack does not raise the fraction")
	expect(Combat.curve_fraction(10.0, 5.0) > Combat.curve_fraction(10.0, 20.0),
		"more defence does not lower the fraction")


## THE RETAIL FIXTURE. Not algebra -- this pair of ratings and this fraction
## were read out of the running binary.
func _retail_hit_chance() -> void:
	var c := Combat.hit_chance(RETAIL_AT, RETAIL_PA)
	expect(absf(c - RETAIL_CHANCE) < 5e-6,
		"retail's own fight is %.6f here, but the binary printed %.6f" % [c, RETAIL_CHANCE])


## THERE IS NO CLAMP. The prerelease formula floored at 5% and capped at 95%;
## retail does neither, so both extremes have to be reachable.
func _no_clamp() -> void:
	var lo := Combat.hit_chance(1.0, 100000.0)
	var hi := Combat.hit_chance(100000.0, 1.0)
	expect(lo < 0.05, "the low end is %.6f -- a 5%% floor is back" % lo)
	expect(hi > 0.95, "the high end is %.6f -- a 95%% ceiling is back" % hi)
	expect(lo > 0.0, "the low end collapsed to certainty of missing")
	# hit_chance takes NO level arguments at all. That is enforced by the
	# signature rather than by a value, which is the point: a level term cannot
	# be smuggled back into accuracy without changing this call.
	expect(Combat.hit_chance(50.0, 50.0) == Combat.hit_chance(50.0, 50.0),
		"hit_chance is not a pure function of the two ratings")


## THE LEVEL TERM, and it is a DAMAGE term. One-sided, and saturating.
func _levels() -> void:
	# Retail printed exactly this for a level-2 attacker on a level-1 target.
	expect(absf(Combat.level_term(2, 1) - 1.01) < 1e-6,
		"a one-level advantage is %.6f, expected 1.01" % Combat.level_term(2, 1))
	# ONE-SIDED: the weaker attacker gets 1.0, not 0.99. Retail's own `jbe`.
	expect(Combat.level_term(1, 2) == 1.0, "the level term is two-sided")
	expect(Combat.level_term(1, 50) == 1.0, "a large deficit is not clamped to 1.0")
	expect(Combat.level_term(7, 7) == 1.0, "equal levels are not neutral")
	# 50 levels up is exactly k = 2, which is the doubling the curve is built on.
	var k50 := -log(1.0 - Combat.A5_BASE * Combat.level_term(51, 1)) / log(2.0)
	expect(absf(k50 - 2.0) < 1e-6, "50 levels up gives k = %.6f, expected 2" % k50)
	# SATURATION rather than a domain error at 98 levels and beyond.
	var kbig := -log(1.0 - clampf(Combat.A5_BASE * Combat.level_term(500, 1),
		0.0, Combat.A5_CEILING)) / log(2.0)
	expect(kbig < 7.0 and kbig > 6.0, "the saturated exponent is %.4f" % kbig)
	# Monotone: more advantage never damages less.
	var prev := -1.0
	for lv in [1, 2, 5, 10, 25, 50, 99]:
		var d := Combat.damage_channel(30.0, 5.0, 0, Combat.level_term(lv, 1))
		expect(d >= prev, "damage fell from %.4f to %.4f as the attacker levelled" % [prev, d])
		prev = d


## `roll < chance` is STRICT, and the roll has 1001 outcomes, not 101.
func _strictness() -> void:
	var rng := RandomNumberGenerator.new()
	var n := 40000
	# An even fight: hits are roll in {0.000 .. 0.499}, i.e. 500 of 1001.
	rng.seed = SEED
	var hits := 0
	for i in n:
		if Combat.resolve(100.0, 100.0, rng)["hit"]:
			hits += 1
	var rate := float(hits) / float(n)
	var want := 500.0 / float(Combat.ROLL_STEPS)
	expect(absf(rate - want) < 0.01,
		"an even fight hit %.4f of the time, expected about %.4f" % [rate, want])
	# The retail fixture, as a rate: roll in {0.000 .. 0.424} is 425 of 1001.
	rng.seed = SEED
	var rhits := 0
	for i in n:
		if Combat.resolve(RETAIL_AT, RETAIL_PA, rng)["hit"]:
			rhits += 1
	var rrate := float(rhits) / float(n)
	var rwant := 425.0 / float(Combat.ROLL_STEPS)
	expect(absf(rrate - rwant) < 0.01,
		"retail's fight hit %.4f of the time, expected about %.4f" % [rrate, rwant])
	# THE GRANULARITY. Every roll must be a multiple of 1/1000 and never exceed
	# 1.0 -- randf() would pass both rate checks above and fail this.
	rng.seed = SEED
	for i in 500:
		var roll: float = Combat.resolve(50.0, 50.0, rng)["roll"]
		expect(roll >= 0.0 and roll <= 1.0, "a roll of %.6f is outside [0,1]" % roll)
		expect(absf(roll * 1000.0 - roundf(roll * 1000.0)) < 1e-4,
			"a roll of %.6f is not a multiple of 1/1000" % roll)


## THE DAMAGE FIXTURES -- retail's own inputs and its own outputs, at two
## different exponents. This is the check that would catch a plausible-looking
## rewrite of the resolution step.
func _retail_damage() -> void:
	for pair in RETAIL_DMG_K1:
		var got := Combat.damage_channel(pair[0], RETAIL_ARMOUR, 0, 1.0)
		expect(absf(got - pair[1]) < 2e-3,
			"raw %.6f vs armour %.6f gives %.6f, but retail produced %.6f" % [
				pair[0], RETAIL_ARMOUR, got, pair[1]])
	for pair in RETAIL_DMG_K2:
		var got := Combat.damage_channel(pair[0], RETAIL_ARMOUR, 0, 1.5)
		expect(absf(got - pair[1]) < 2e-3,
			"at k=2, raw %.6f gives %.6f, but retail produced %.6f" % [
				pair[0], got, pair[1]])
	# RESISTANCE is a straight percentage off the top, and 100 means immune.
	expect(absf(Combat.damage_channel(50.0, 10.0, 50)
		- 0.5 * Combat.damage_channel(50.0, 10.0, 0)) < 1e-4,
		"50%% resistance does not halve the channel")
	expect(Combat.damage_channel(50.0, 10.0, 100) == 0.0,
		"100%% resistance is not immunity")
	# FOUR CHANNELS, and a short input is read as zero rather than refused.
	var out := Combat.damage(PackedFloat32Array([RETAIL_DMG_K1[0][0]]),
		PackedFloat32Array([RETAIL_ARMOUR]), PackedByteArray(), 1, 1)
	expect(out.size() == Combat.CHANNELS, "damage() returned %d channels" % out.size())
	expect(absf(out[0] - RETAIL_DMG_K1[0][1]) < 2e-3, "channel 0 disagrees with retail")
	for i in range(1, Combat.CHANNELS):
		expect(out[i] == 0.0, "channel %d invented %.4f from no input" % [i, out[i]])


## The same seed must give the same fight, or record/replay cannot survive
## anyone swinging a sword.
func _determinism() -> void:
	var a: Array[float] = []
	var b: Array[float] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	for i in 64:
		a.append(Combat.resolve(120.0, 80.0, rng)["roll"])
	rng.seed = SEED
	for i in 64:
		b.append(Combat.resolve(120.0, 80.0, rng)["roll"])
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
	var hit := Combat.hit_chance(sera_at, ghoul_pa)
	expect(hit > 0.0 and hit < 0.5,
		"the MVP fight is %.4f, expected under even and above impossible" % hit)
	# She is at a level DISADVANTAGE here (1 against 2), and under retail's rules
	# that costs her nothing in accuracy and nothing in damage -- the level term
	# is one-sided. Before row 1034 the port docked her for it.
	expect(Combat.level_term(1, 2) == 1.0,
		"the level-1 hero is still being penalised for the Ghoul's level")

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
	print("combat_check\tbase OK\tsera_AT=%.1f\tghoul_PA=%.1f\thit=%.1f%%\tProzAW=%s" % [
		sera_at, ghoul_pa, hit * 100.0, proz])
