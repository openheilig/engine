class_name Combat
extends RefCounted
## The combat arithmetic, as recovered from retail rather than designed here.
##
## RETAIL RUNS ONE CURVE AND USES IT TWICE (research/engine/combat-formulas.md,
## rows 1034-1036, confirmed live under gdb against the retail Linux binary):
##
##     curve(a2, a3, a4, a5):
##         a5 = clamp(a5, 0, 0.99);  a4 = max(a4, -1)
##         k  = -ln(1 - a5) / ln(a4 + 1)
##         r  = |a3| > 0.001 ? a2/a3 : 10000
##         f  = 1 - 1/(r + 1)^k          # the FRACTION
##         return a2 * f                 # the fraction APPLIED
##
## To-hit takes the fraction; damage takes the product. Retail's to-hit call
## site passes a4 = 1.0 and a5 = 0.5 as literals, which makes k = 1 and
## collapses the fraction to plain `AT/(AT+PA)` -- no level term, NO CLAMP.
##
## THIS REPLACED A FORMULA THAT WAS WRONG FOR RETAIL. Until row 1034 this file
## carried `clamp(200*AT/(AT+PA) * ALVL/(ALVL+DLVL), 5, 95)`, transcribed from
## the two 2001 PRERELEASE binaries -- and retail is a different game: no level
## term in accuracy, no 5/95 floor and ceiling. The level difference does exist,
## but it lives in the DAMAGE step as the curve's exponent; see `level_term`.
## The prerelease formula stays in the research document, not here, because the
## port targets retail.
##
## THE ROLL IS READ FROM THE CALL SITE, not chosen: `rand() % 1001` scaled by
## the literal 0.001, so 1001 discrete outcomes over [0.000, 1.000], and
## `roll < chance` hits. The strictness is MEASURED rather than assumed -- 11
## of 11 rolls below the chance proceeded into the damage step and 7 of 7 at or
## above it left through the miss path.
##
## Nothing here touches the scene tree or a node (R10.1), and nothing here
## holds state: the RNG is passed in, because a fixed-tick sim that records and
## replays cannot have a hidden random source.

## The DERIVED-STAT KERNEL, from FUN_0820ef48: every attribute-to-combat-number
## conversion in retail goes through this one line.
##
##     K(S) = (156 - BalStatOff)*S/156 + BalStatOff + 9
##
## It is a straight line in the attribute, pinned so K(0) = BalStatOff + 9 and
## K(156) = 165 whatever BalStatOff is. Retail ships BalStatOff = 20 in
## balance.bin (key at offset 32, f32 20.0), making it K(S) = 0.8718*S + 29.
##
## Read off retail Linux and confirmed only there -- unlike to_hit below, which
## agrees in two binaries. Recorded as the weaker of the two.
const STAT_SPAN := 156.0
const STAT_CEILING := 165.0
const BAL_STAT_OFF := 20.0      ## balance.bin BalStatOff; the file's number, not a choice

## Every one of retail's five curve call sites pushes a4 = 1.0, so ln(a4+1) is
## ln 2 throughout and k reduces to -log2(1 - a5).
const CURVE_A4 := 1.0
## a5 at the to-hit site is the literal 0.5, giving k = 1. The damage sites
## scale this same 0.5 by the level term.
const A5_BASE := 0.5
const A5_CEILING := 0.99        ## the curve's own clamp, at its top
const FLAT_ARMOUR := 0.001      ## |a3| at or under this takes the no-armour branch
const NO_ARMOUR_RATIO := 10000.0
const ROLL_STEPS := 1001        ## rand() % 1001, so 0..1000 inclusive
const ROLL_SCALE := 0.001       ## the literal at 0x86e6ba8, exactly 1/1000
const CHANNELS := 4
const LEVEL_STEP := 0.01        ## the literal at 0x86e6b9c, per level of advantage
const RESIST_FULL := 100.0


## THE SHARED CURVE, `sub_815D44C`, transcribed. Returns the FRACTION -- what
## retail hands back through the `a6` out-param. Multiply by `a2` yourself to
## get what the function returns; the two consumers want different halves.
##
## No guard is added for a2 = 0 or a3 = 0: retail's own two guards (the a5 clamp
## and the |a3| test) already cover them, and a3 = 0 legitimately means "no
## armour", which the 10000 ratio turns into approximately full effect.
static func curve_fraction(a2: float, a3: float,
		a4: float = CURVE_A4, a5: float = A5_BASE) -> float:
	var s := clampf(a5, 0.0, A5_CEILING)
	var e := maxf(a4, -1.0)
	var k := -log(1.0 - s) / log(e + 1.0)
	var r := (a2 / a3) if absf(a3) > FLAT_ARMOUR else NO_ARMOUR_RATIO
	return 1.0 - 1.0 / pow(r + 1.0, k)


## Retail's chance to land a blow, as a fraction in [0,1].
##
## With a4 = 1 and a5 = 0.5 this is algebraically AT/(AT+PA). It is written
## through the curve anyway, rather than as the reduced form, so that the one
## transcribed function stays the only place the arithmetic lives.
static func hit_chance(at: float, pa: float) -> float:
	return curve_fraction(at, pa, CURVE_A4, A5_BASE)


## One attack. `rng` is the caller's -- a Sim that records and replays must own
## its own seeded generator, or a replay diverges the first time anyone swings.
##
## Returns {hit, roll, chance}, all of `roll` and `chance` floats in [0,1].
## `hit` is `roll < chance`, the strict test measured at the call site.
static func resolve(at: float, pa: float, rng: RandomNumberGenerator) -> Dictionary:
	var chance := hit_chance(at, pa)
	# 1001 outcomes, not 101 and not a continuous float: retail's modulus is the
	# distribution, and a port that rolls randf() would be subtly wrong at both
	# ends. The glibc SEQUENCE is not reproducible here and is not attempted.
	var roll := float(rng.randi_range(0, ROLL_STEPS - 1)) * ROLL_SCALE
	return {"hit": roll < chance, "roll": roll, "chance": chance}


## THE LEVEL TERM, and the surprise of row 1036: it is a DAMAGE effect, not an
## accuracy one. `sub_81FAC30` raises the curve's exponent when the attacker
## outranks the defender, and to-hit never sees a level at all.
##
##     delta = max(0, attackerLevel - defenderLevel)     # one-sided
##     a5    = 0.5 * (1 + 0.01*delta)
##     k     = 1 - log2(1 - delta/100)
##
## One-sided is retail's own `jbe`, measured live: a level-2 attacker on a
## level-1 target produced 1.010000, and the same pair reversed produced 1.0.
## The curve's a5 ceiling makes the bonus SATURATE at delta = 98 (k = 6.64)
## rather than reaching ln(0), which is deliberate rather than lucky.
##
## Retail also gates this on the attacker's type (`[atk+0x0c] > 0x10`). That
## gate is not applied here because what the type id means is not recovered;
## a caller that knows better should pass equal levels to suppress the term.
static func level_term(attacker_level: int, defender_level: int) -> float:
	return 1.0 + LEVEL_STEP * float(maxi(0, attacker_level - defender_level))


## ONE DAMAGE CHANNEL. `raw` is the attacker's damage in this channel, `armour`
## the defender's in the same channel, `resist_percent` the defender's byte from
## its creature-info resistance table.
##
##     dmg = raw * curve_fraction(raw, armour, 1, 0.5*lvl) * (100 - resist)/100
##
## Confirmed live at 64 of 64 channels over 16 swings and four attacker/target
## pairings in both directions.
static func damage_channel(raw: float, armour: float, resist_percent: int = 0,
		lvl_term: float = 1.0) -> float:
	var f := curve_fraction(raw, armour, CURVE_A4, A5_BASE * lvl_term)
	return raw * f * (RESIST_FULL - float(resist_percent)) / RESIST_FULL


## All four channels of one landed blow. `resist` is the defender's four bytes
## for the CURRENT difficulty -- retail reads them at `[info + difficulty +
## 0x42 + 5*i]`, i.e. one column of a 4-channel x 5-difficulty table.
##
## Short inputs are read as zero rather than refused, because a caller that has
## only physical damage (which is every caller until inventory exists) should
## not have to build three empty channels to say so.
static func damage(raw: PackedFloat32Array, armour: PackedFloat32Array,
		resist: PackedByteArray, attacker_level: int = 0,
		defender_level: int = 0) -> PackedFloat32Array:
	var lvl := level_term(attacker_level, defender_level)
	var out := PackedFloat32Array()
	out.resize(CHANNELS)
	for i in CHANNELS:
		var r := raw[i] if i < raw.size() else 0.0
		var a := armour[i] if i < armour.size() else 0.0
		var p := resist[i] if i < resist.size() else 0
		out[i] = damage_channel(r, a, p, lvl)
	return out


## The derived-stat kernel. `bal_stat_off` defaults to the value balance.bin
## ships; a caller that reads the file can pass its own and the two pinned
## points still hold.
static func stat_kernel(attr: float, bal_stat_off: float = BAL_STAT_OFF) -> float:
	return (STAT_SPAN - bal_stat_off) * attr / STAT_SPAN + bal_stat_off + 9.0


## THE ATTACK AND DEFENCE RATINGS, and the answer is that no BASE ATTRIBUTE
## becomes either of them. They accumulate from SKILL LEVELS.
##
## Read off `sub_81F596E`, the creature stat builder: it dispatches on skill
## TYPE through a jump table and, for each skill the creature has, feeds that
## skill's LEVEL into this one shared curve twice, once per balance triplet of
## the skill's family. Case 8 (Agility, family `W`) computes AW from
## WoffAW/W__sAW/W__wAW and VW from WoffVW/W__sVW/W__wVW off the SAME level;
## case 3 (Long-handled Weapons, family `STK`) computes AW and then SP, so the
## second output's meaning is per-family rather than fixed.
##
## `sub_81F55B0`, verbatim:
##
##     f(off, S, s, w):
##         if S < 1: return 0
##         v = (1 - 1/((S-1)/s + 1)) * (w - off)
##         return off + 2*v
##
## A saturating curve in the skill level: f(1) = off, and f rises towards
## off + 2*(w - off) without reaching it. `s` is the half-way scale.
##
## WHICH SKILLS. Ten balance families carry an AW triplet -- STK Long-handled
## Weapons, SK Sword Lore, AK Axe Lore, KK Blade Combat, FK Unarmed Combat,
## BK Dual Wielding, FEK Ranged Combat, W Agility, HR Constitution, and WT
## which no skill maps to. Exactly TWO carry a VW triplet: W Agility and
## HP Constitution. So defence comes from Agility and Constitution and from
## nothing else, and attack comes from the weapon skill in use plus Agility and
## Constitution.
##
## `VWFakBoss` (2.0) and `VWFakChamp` (1.5) multiply the defence rating; they
## are in the same table and are not applied here, because what marks a
## creature boss or champion is not recovered.
static func skill_rating(off: float, level: float, s: float, w: float) -> float:
	# Retail's own guard, and it is a floor rather than a clamp: an untrained
	# skill contributes NOTHING, not `off`.
	if level < 1.0:
		return 0.0
	var v := (1.0 - 1.0 / ((level - 1.0) / s + 1.0)) * (w - off)
	return off + v + v


## THE BASE ATTACK AND DEFENCE RATINGS -- the numbers `skill_rating`'s
## multipliers multiply, and the last invented quantity in the fight.
##
## `cCreatureHero::CalcResults` (sub_820E04C) zeroes both at 0x820E512 and then
## accumulates, at 0x8210331:
##
##     C = &per-class coefficient record       ; flt_8793720[class * 16]
##     base_AT += 0.01 * (STR*C[0] + DEX*C[1])
##     base_PA += 0.01 * (STR*C[3] + DEX*C[4])
##
## and at 0x820EE2F adds the equipment aggregate, `+= 0.01 * gear * C[2]` and
## `C[5]` respectively.
##
## EVERY CLASS RECORD IN RETAIL IS IDENTICAL -- C = [50, 50, 100, 20, 80, 100]
## -- so the per-class table is a lever the shipped game does not pull, and the
## coefficients reduce to the constants below. They are kept as named constants
## rather than folded into the arithmetic so that a build which DOES vary them
## has somewhere to put the numbers.
##
## `flt_8793720` is statically initialised in .data with exactly two xrefs, both
## the reads above, and no writer was found -- so it is compiled in rather than
## loaded from creature.pak or balance.bin. (An absence of xrefs cannot rule out
## a memcpy through a computed pointer; recorded as the weaker claim.)
##
## WHICH TWO ATTRIBUTES. The struct's six u16 sit at +0x10..+0x1A and the
## reads are +0x10 and +0x14, i.e. the FIRST and THIRD -- which in
## `creature.pak`'s own order (STK, RES, GES, REPHY, REMAG, CHARISMA) are
## Strength and Dexterity. The 20/80 split favouring Dexterity on defence is
## what the game plays like, and is the corroboration rather than the source.
const AT_STR := 0.5      ## C[0] * 0.01
const AT_DEX := 0.5      ## C[1] * 0.01
const AT_GEAR := 1.0     ## C[2] * 0.01
const PA_STR := 0.2      ## C[3] * 0.01
const PA_DEX := 0.8      ## C[4] * 0.01
const PA_GEAR := 1.0     ## C[5] * 0.01


## Base attack rating. `gear` is the aggregated equipment bonus (u16 at the
## gear struct's +0x2C); zero for a bare creature.
static func base_attack(strength: int, dexterity: int, gear: int = 0) -> float:
	return maxf(0.0, AT_STR * float(strength) + AT_DEX * float(dexterity)
		+ AT_GEAR * float(gear))


## Base defence rating. `gear` is the equipment aggregate at the gear struct's
## +0x2E. Dexterity carries four times the weight Strength does.
static func base_defence(strength: int, dexterity: int, gear: int = 0) -> float:
	return maxf(0.0, PA_STR * float(strength) + PA_DEX * float(dexterity)
		+ PA_GEAR * float(gear))


## One finished rating, as the two getters `sub_81FA5AA` (attack) and
## `sub_81FA622` (defence) assemble it:
##
##     rating = base * multiplier * proz
##
## `multiplier` is the creature-struct's +0xE6 or +0xEA -- 1.0 before any skill
## folds in, which is what a level-1 character with no weapon skill has.
##
## `proz` is `ProzAW[difficulty]` and applies ONLY to non-heroes: the getters
## gate it on `type-id > 0x10`, and the eight playable classes are 1..9. Retail
## ships [1.0, 1.5, 2.5, 4.5] for Silver / Gold / Platinum / Niob, so a monster
## on Niob hits and blocks at four and a half times its own numbers.
static func rating(base: float, multiplier: float = 1.0, proz: float = 1.0) -> float:
	return maxf(0.0, base * multiplier * proz)
