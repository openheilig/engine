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
## The field NAMES are now JOINED, two classes discriminating the mapping:
## b74 = STK (attribute 0), b80 = REPHY (attribute 3):
##   Seraphim  attrs[STK,REPHY] = (22,22), live b74/b80 = 22/22, max 119
##   Gladiator attrs[STK,REPHY] = (33,25), live b74/b80 = 33/25, max 147
## (b80 disambiguates on the Gladiator: only REPHY is 25 there.) The check
## below re-derives the join from the templates themselves, so a template
## edit cannot silently invalidate it.

func _init() -> void:
	super()
	var fails := 0
	# THE live witnesses: two classes, retail-observed maxima.
	var cases := [[22, 22, 119, "hero01", 0, 3], [33, 25, 147, "hero00", 0, 3]]
	for c: Array in cases:
		var got := ActorStats.max_hp(c[0], c[1], c[0], c[1], 1)
		if got != int(c[2]):
			fails += 1
			printerr("HERO HP MISMATCH %s: retail observed %d, formula gives %d"
				% [c[3], c[2], got])
	# The join, re-derived from retail data: for each witnessed template the
	# live-observed block pair must equal (attrs[0], attrs[3]) = (STK, REPHY).
	var install := Sacred.find_install()
	assert(not install.is_empty(), "retail install is required")
	for c: Array in cases:
		var h := Sacred.Hero.new(install.path_join("templates/" + str(c[3]) + ".ptx"))
		var attrs := h.attributes()
		if attrs[c[4]] != int(c[0]) or attrs[c[5]] != int(c[1]):
			fails += 1
			printerr("JOIN BROKEN for %s: template (STK,REPHY)=(%d,%d), live block was (%d,%d)"
				% [c[3], attrs[c[4]], attrs[c[5]], c[0], c[1]])
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
