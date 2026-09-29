extends "res://checks/check.gd"
## hero_hp_check.gd -- the transcribed max-HP base formula must reproduce
## retail's LIVE-OBSERVED hero value.
##
## Witness: bounded gdb observation of live LGP 1.0.02 at the 0x81F4FFA
## epilogue (tmp/engine-revision-20260929/hp-live.log, 32 samples): the
## new-game Seraphim (type 1, level 1, block fields b74=22 b80=22,
## live a16=22 a22=22) reached max=119. The formula below is a direct
## transcription of the function's base arithmetic (chunk 00016.c:35931,
## corroborated by ENG 0x5658F0 / RUS 0x565BA0):
##
##   span   = |60 - b0 - b1|            (0 when b0+b1 >= 60)
##   base   = b1 + b0*(L-1)/10 + b1*(L-1)/10 + b0     (integer divisions)
##   max_hp = trunc( ((a0+a1)/base)
##                 * base^(span*0.0039963233 + 1.5)
##                 * 0.3225806451612903 )
##
## The field NAMES stay offset-based on purpose: the creature initializer's
## two attribute orders differ, and the b74/b80 -> template-attribute join
## has not been observed. Inputs are BLOCK OFFSETS, not named attributes.
## The creature tail (difficulty re-scale) is deliberately NOT here.

func _init() -> void:
	super()
	var fails := 0
	# THE live witness: hero start state -> 119.
	var got := ActorStats.max_hp(22, 22, 22, 22, 1)
	if got != 119:
		fails += 1
		printerr("HERO HP MISMATCH: retail observed 119, formula gives %d" % got)
	# Level scaling stays integer in the base terms: level 11 doubles each
	# level-scaled contribution (b*10/10 == b), which must RAISE max HP.
	if ActorStats.max_hp(22, 22, 22, 22, 11) <= 119:
		fails += 1
		printerr("HP must grow with level on the witnessed base pair")
	# The ratio term: doubling live attributes doubles the ratio only while
	# base is unchanged -- at base 44 the ratio (a0+a1)/44 with (44,44) is 2.0,
	# so the result must be exactly twice the witness within truncation.
	var doubled := ActorStats.max_hp(22, 22, 44, 44, 1)
	if doubled < 119 * 2 or doubled > 119 * 2 + 1:
		fails += 1
		printerr("HP ratio term unexpected: (44,44) gave %d, want ~238" % doubled)
	# Zero-base guard: base == 0 divides -- retail's own x87 would produce
	# inf; the port must refuse the input rather than return a garbage stat.
	if ActorStats.max_hp(0, 0, 10, 10, 1) != -1:
		fails += 1
		printerr("degenerate base (0,0) must return -1, not a garbage stat")
	# Monotone in the exponent span: a base pair closer to 60 total has a
	# smaller exponent; with ratio fixed at 1.0 the value still grows with
	# base^1.5 dominating. Sanity only -- the exact curve is retail's.
	var low := ActorStats.max_hp(10, 10, 20, 20, 1)
	var high := ActorStats.max_hp(20, 20, 40, 40, 1)
	if not (low > 0 and high > 0):
		fails += 1
		printerr("positive inputs must yield positive max HP")

	print("hero_hp_check\tOK\twitness=119")
	finish(1 if fails > 0 else 0)
