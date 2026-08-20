extends "res://checks/check.gd"
## COMBAT-ART REGENERATION, gated against retail's own arithmetic
## (findings log rows 1043-1046).
##
## These are RELATIONS, not literals, for the reason hud_check spells out: a
## transcribed constant only proves someone typed it twice. What is asserted
## here is what would break if a sign, a clamp or a weight were wrong.


func _init() -> void:
	super()
	_total()
	_rate()
	_tick()
	_fraction()
	_ready()
	_hero()
	_table()
	print("regen_check OK\ttotal(4,0.5,10)=%.2f\trate(1,100)=%.2f\teps=%.2f" % [
		Regen.total(4.0, 0.5, 10), Regen.rate(1.0, 100), Regen.READY_EPSILON])
	finish()


## THE TOTAL IS LINEAR AND RISES WITH LEVEL. A stronger art coming back MORE
## SLOWLY is the cost model; if this ever inverts, the model inverted with it.
func _total() -> void:
	var base := 4.0
	var step := 0.5
	for lvl in [0, 1, 5, 20]:
		expect(is_equal_approx(Regen.total(base, step, lvl), base + step * lvl),
			"total at level %d is not base + level*step" % lvl)
	expect(Regen.total(base, step, 10) > Regen.total(base, step, 1),
		"levelling an art must LENGTHEN its regeneration, not shorten it")

	# A TEMPORARY LEVEL BUYS HALF. Retail computes the curve at perm and at
	# perm+temp and adds half the gap -- so +2 temporary is worth +1 permanent
	# exactly, and that equality is the cleanest way to state it.
	var t_perm := Regen.total(base, step, 6, 0)
	var t_temp := Regen.total(base, step, 4, 4)
	expect(is_equal_approx(t_temp, Regen.total(base, step, 4, 0) + 2.0 * step),
		"four temporary levels must be worth two permanent ones, got %f" % t_temp)
	expect(t_temp < Regen.total(base, step, 8, 0),
		"a temporary level must not be worth a full one")
	expect(is_equal_approx(t_perm, Regen.total(base, step, 6, 0)), "sanity")
	# A NEGATIVE step must not let the temporary branch fire: retail guards it
	# with `if (both > total)`, so a curve that falls with level stays at perm.
	expect(is_equal_approx(Regen.total(10.0, -1.0, 2, 5), 8.0),
		"a falling curve must ignore the temporary level, not add half a drop")


## ONE POINT IS ONE PERCENT, and multiplicative. The multiplicative part is the
## invariant that matters: no attribute value may drive the rate to zero or
## negative, which a subtractive model would do.
func _rate() -> void:
	expect(is_equal_approx(Regen.rate(1.0, 0), 1.0),
		"zero attribute must leave the accumulated bonus alone")
	expect(is_equal_approx(Regen.rate(1.0, 100), 2.0),
		"100 points must double the rate")
	expect(Regen.rate(2.0, 50) > Regen.rate(1.0, 50),
		"the bonus must scale the rate")
	for a in [0, 1, 50, 1000]:
		expect(Regen.rate(1.0, a) > 0.0,
			"attribute %d drove the rate to zero or below" % a)

	# THE TWO KINDS TAKE DIFFERENT ATTRIBUTES, and crossing them is the one
	# mistake that would still "work" and be silently wrong all game.
	var r := Regen.rates(1.0, 10, 90)
	expect(is_equal_approx(r[Regen.COMBAT_ART], Regen.rate(1.0, 10)),
		"combat arts must take PHYSICAL regeneration")
	expect(is_equal_approx(r[Regen.SPELL], Regen.rate(1.0, 90)),
		"spells must take MENTAL regeneration")


## THE COUNTDOWN IS CLAMPED AT BOTH ENDS. The lower clamp is what stops a long
## frame overshooting into a negative clock; the upper one holds when an art's
## total shrinks under it.
func _tick() -> void:
	var total := 10.0
	expect(is_equal_approx(Regen.tick(10.0, total, 1.0, 2.0), 8.0),
		"one second at rate 2 must serve 2 seconds of the clock")
	expect(is_equal_approx(Regen.tick(1.0, total, 100.0, 2.0), 0.0),
		"a long frame must clamp at zero, not run negative")
	expect(is_equal_approx(Regen.tick(10.0, total, -100.0, 2.0), total),
		"the clock must not exceed the art's own total")
	# The buff multiplies the DELTA, so it serves more of the clock per second.
	expect(Regen.tick(10.0, total, 1.0, 2.0, Regen.ART_MULT, true)
			> Regen.tick(10.0, total, 1.0, 2.0),
		"the buff must leave LESS remaining, not more")

	# A whole recharge must land exactly ready, from a real starting state.
	var rem := total
	for i in 100:
		rem = Regen.tick(rem, total, 0.1, 1.0)
	expect(Regen.ready(rem), "10 s at rate 1 did not finish a 10 s art: %f" % rem)


## THE FRACTION IS WHAT THE SLOT DRAWS, 0 just used and 1 ready -- the same
## orientation view/hud.gd slices the health ring with.
func _fraction() -> void:
	expect(is_equal_approx(Regen.fraction(10.0, 10.0), 0.0),
		"a just-used art must read EMPTY, not full")
	expect(is_equal_approx(Regen.fraction(0.0, 10.0), 1.0),
		"a ready art must read FULL")
	expect(is_equal_approx(Regen.fraction(5.0, 10.0), 0.5), "half must read half")
	expect(is_equal_approx(Regen.fraction(1.0, 0.0), 1.0),
		"a zero-length art must read ready rather than divide by zero")
	expect(Regen.fraction(20.0, 10.0) >= 0.0 and Regen.fraction(-5.0, 10.0) <= 1.0,
		"the fraction must stay inside 0..1 for out-of-range input")


## RETAIL'S READY TEST IS AN EPSILON, NOT ZERO. A float clock decremented by a
## frame delta does not land on 0.0, so `== 0.0` would leave arts permanently
## one tick short of usable.
func _ready() -> void:
	expect(Regen.ready(0.0) and Regen.ready(0.005),
		"the ready test must be an epsilon, not an equality")
	expect(not Regen.ready(0.5), "half a second left is not ready")
	expect(is_equal_approx(Regen.READY_EPSILON, 0.01),
		"retail's epsilon is 0.01 (sub_8218774)")


## THE COMBAT-ART TABLE, read out of retail's own executable. The signature is
## the point of the test: a wrong offset here does not crash, it returns floats
## that look exactly like balance data.
func _table() -> void:
	var install := Sacred.find_install()
	if install == "":
		print("regen_check\tSKIP\tno install tree")
		return
	var arts := CombatArts.new(install)
	if not expect(arts.found, "combat-art table not read: %s" % arts.reason):
		return
	var ids := arts.ids()
	expect(ids.size() == 94, "read %d arts, retail scans 94" % ids.size())
	expect(arts.has(1000) and not arts.has(1), "the id index is not keyed by art id")

	# EVERY art must produce a usable clock: positive, finite, and rising.
	for id in ids:
		var c := arts.coefficients(id)
		expect(c["base"] > 0.0, "art %d has a non-positive base" % id)
		expect(c["step"] >= 0.0, "art %d speeds up as it levels" % id)
		var t0 := arts.total(id, 0)
		var t9 := arts.total(id, 9)
		expect(t0 > 0.0 and is_finite(t0), "art %d has no clock at level 0" % id)
		expect(t9 >= t0, "art %d regenerates faster at level 9 than at 0" % id)
		expect(arts.elements(id).size() == 3, "art %d has no element triple" % id)

	# The table must AGREE with the standalone formula, not merely coexist with
	# it -- this is the join between the reader and world/regen.gd.
	var c1 := arts.coefficients(1000)
	expect(is_equal_approx(arts.total(1000, 4),
			Regen.total(c1["base"], c1["step"], 4)),
		"CombatArts.total and Regen.total disagree")
	expect(is_equal_approx(arts.total(1000, 0), 5.0),
		"art 1000 at level 0 is %.2f, retail ships base 5" % arts.total(1000, 0))
	expect(is_equal_approx(arts.total(1000, 1), 8.0),
		"art 1000 at level 1 is %.2f, expected 5 + 3" % arts.total(1000, 1))

	# And it must feed a real countdown end to end: retail's own coefficients
	# through the port's own tick, landing ready.
	var rate: float = Regen.rates(1.0, 30, 40)[Regen.COMBAT_ART]
	var total := arts.total(1000, 0)
	var rem := total
	var steps := 0

	while not Regen.ready(rem) and steps < 100000:
		rem = Regen.tick(rem, total, 0.01, rate)
		steps += 1
	expect(Regen.ready(rem), "art 1000 never finished: %f left" % rem)
	print("regen_check\ttable OK\tarts=%d\tart1000 lvl0=%.1fs lvl9=%.1fs\trecharge=%.2fs" % [
		ids.size(), arts.total(1000, 0), arts.total(1000, 9), float(steps) * 0.01])


## THE HERO'S OWN RATES, from retail's own template rather than from literals.
## This is the part that would break if the attribute columns were reordered.
func _hero() -> void:
	var install := Sacred.find_install()
	if install == "":
		print("regen_check\tSKIP\tno install tree")
		return
	for i in range(0, 8):
		var path := install.path_join("templates/hero%02d.ptx" % i)
		var h = Sacred.Hero.new(path)
		if not h.found:
			continue
		var r: Dictionary = Regen.rates(1.0, h.attribute("REPHY"), h.attribute("REMAG"))
		expect(r[Regen.COMBAT_ART] > 0.0 and r[Regen.SPELL] > 0.0,
			"hero%02d has a non-positive regeneration rate" % i)
		# Both attributes are real and non-zero in every shipped template, so a
		# rate of exactly 1.0 would mean the column read back as zero.
		expect(not is_equal_approx(r[Regen.COMBAT_ART], 1.0)
				or not is_equal_approx(r[Regen.SPELL], 1.0),
			"hero%02d read both regeneration attributes as zero" % i)
	# THE STATUS LINE encounter.gd emits, formatted here rather than trusted.
	# An empty dictionary is the real no-install case and must still format,
	# which is the only way this wiring can fail at runtime.
	for d in [{}, Regen.rates(1.0, 30, 40)]:
		var line := "\tregen_art=%.2f\tregen_spell=%.2f" % [
			d.get(Regen.COMBAT_ART, 0.0), d.get(Regen.SPELL, 0.0)]
		expect(line.begins_with("\tregen_art="), "status line did not format")
	print("regen_check\thero templates OK")
