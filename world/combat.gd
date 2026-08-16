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
