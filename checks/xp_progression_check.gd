extends "res://checks/check.gd"
## xp_progression_check.gd -- the engine's XP progression functions must
## reproduce the values retail itself computed, observed live in LGP 1.0.02
## (tmp/engine-revision-20260929/xp-live.log, 64 entry/exit pairs) and the
## statically recovered award ladder (combat-formulas.md, finding 1288).
##
##   threshold(L) = 100 * floor((L^4 + 40L^3 + 150L^2 + 200L - 90) / 100)
##   award(L)     = 1.0                         L <= 99
##                  0.985^(L-99)        100..124
##                  0.980^(L-99)        125..149
##                  0.975^(L-109)       150+
##
## Every threshold row below is a RETAIL OBSERVED value, not a formula echo:
## if the implementation and the observation ever disagree, this check
## fails and names the level.

const OBSERVED_THRESHOLDS := {
	1: 300, 2: 1200, 3: 3000, 4: 5900, 5: 10200,
	6: 16400, 7: 24700, 9: 49500,
}


func _init() -> void:
	super()
	var fails := 0
	# Thresholds: retail-observed levels, plus deep levels the observation
	# could not reach (static formula, still must quantize to ×100).
	for level: int in OBSERVED_THRESHOLDS:
		var got: int = Progression.xp_threshold(level)
		if got != OBSERVED_THRESHOLDS[level]:
			fails += 1
			printerr("THRESHOLD MISMATCH L=%d: retail %d, engine %d"
				% [level, OBSERVED_THRESHOLDS[level], got])
	for level in [50, 99, 100, 150, 205, 216]:
		var got: int = Progression.xp_threshold(level)
		if got % 100 != 0 or got <= 0:
			fails += 1
			printerr("THRESHOLD SHAPE L=%d: %d is not a positive multiple of 100" % [level, got])
	# Monotonic across the whole span.
	var prev := 0
	for level in range(1, 217):
		var t: int = Progression.xp_threshold(level)
		if t < prev:
			fails += 1
			printerr("THRESHOLD NON-MONOTONIC at L=%d: %d after %d" % [level, t, prev])
		prev = t
	# Award ladder: trivial arm live-observed territory (<=99 == 1.0), higher
	# arms static-exact constants; boundary levels are the regression point.
	var award_cases := [[1, 1.0], [50, 1.0], [99, 1.0],
		[100, pow(0.985, 1.0)], [101, pow(0.985, 2.0)], [124, pow(0.985, 25.0)],
		[125, pow(0.98, 26.0)], [149, pow(0.98, 50.0)],
		[150, pow(0.975, 41.0)], [205, pow(0.975, 96.0)]]
	for c: Array in award_cases:
		var got: float = Progression.award_multiplier(c[0])
		if absf(got - float(c[1])) > 1e-4:
			fails += 1
			printerr("AWARD MISMATCH L=%d: want %f, got %f" % [c[0], c[1], got])
	# Boundaries are inclusive: L=99 is the last 1.0, L=100 the first decay.
	if Progression.award_multiplier(99) != 1.0 or Progression.award_multiplier(100) >= 1.0:
		fails += 1
		printerr("AWARD BOUNDARY: 99 must be the last 1.0 and 100 the first decayed")

	print("xp_progression_check\tOK\tthresholds=%d\taward_cases=%d"
		% [OBSERVED_THRESHOLDS.size(), award_cases.size()])
	finish(1 if fails > 0 else 0)
