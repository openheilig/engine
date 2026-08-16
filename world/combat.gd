class_name Combat
extends RefCounted
## The combat arithmetic, as recovered from retail rather than designed here.
##
## TO-HIT IS RECOVERED AND CONFIRMED IN TWO BINARIES
## (research/engine/combat-formulas.md):
##
##     hit% = clamp( 200*AT/(AT+PA) * ALVL/(ALVL+DLVL), 5, 95 )
##
## AT is Angriffswert (attack rating), PA Verteidigungswert (defence rating),
## ALVL/DLVL the two levels. In armalion.exe it is inlined into
## cCreature::receive_event; in armalion_us.exe it is its own function at
## sub_428790. The two are algebraically identical, which is why this is
## transcribed rather than fitted.
##
## THE ROLL IS ALSO READ, from the call site: `rand(0,100)` and `roll < hit%`
## hits -- a STRICT comparison, so a 5% floor really does miss 95 times in 100
## and not 96.
##
## WHAT IS NOT RECOVERED, and is therefore not invented here: the RESOLUTION
## step. How damage meets resistance, what criticals do, and what the weapon
## slot flag selects are all undecoded (combat-formulas.md's `## Open`). So
## `resolve()` returns WHETHER a blow lands and leaves the damage to its
## caller; there is no damage formula in this file to be wrong about.
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

const HIT_MIN := 5
const HIT_MAX := 95
const ROLL_MAX := 100


## The recovered to-hit percentage. Integer, clamped, exactly as retail clamps.
##
## The int64 cast in the original truncates toward zero after the multiply, so
## the arithmetic is done in float and floored once at the end rather than
## rounded -- rounding would disagree with retail on every fractional case.
static func to_hit(at: int, pa: int, alvl: int, dlvl: int) -> int:
	# Retail divides by (PA + AT) and by (DLVL + ALVL) without guarding either.
	# A port cannot afford that, and returning the floor is the conservative
	# answer: a defender who somehow has no rating at all does not become
	# unmissable.
	if at + pa <= 0 or alvl + dlvl <= 0:
		return HIT_MIN
	var v := (float(at) + float(at)) / float(pa + at) * 100.0 \
		* (float(alvl) * 1.0 / float(dlvl + alvl))
	var h := int(v)
	if h < HIT_MIN:
		return HIT_MIN
	if h > HIT_MAX:
		return HIT_MAX
	return h


## One attack. `rng` is the caller's -- a Sim that records and replays must own
## its own seeded generator, or a replay diverges the first time anyone swings.
##
## Returns {hit, roll, chance}. `hit` is `roll < chance`, the strict test from
## the call site. No damage: see the class doc.
static func resolve(at: int, pa: int, alvl: int, dlvl: int,
		rng: RandomNumberGenerator) -> Dictionary:
	var chance := to_hit(at, pa, alvl, dlvl)
	var roll := rng.randi_range(0, ROLL_MAX)
	return {"hit": roll < chance, "roll": roll, "chance": chance}


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
