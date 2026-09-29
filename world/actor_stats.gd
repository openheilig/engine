class_name ActorStats
extends RefCounted
## Derived actor statistics transcribed from retail, one formula at a time,
## each landing only with a live witness. NOTHING mutates here: pure
## functions over the block fields retail reads, named by OFFSET until the
## attribute-order join lands (the creature initializer's two attribute
## orders differ — naming them now would encode a guess).
##
## Sources (research/engine/combat-formulas.md, findings 1286-1290):
##   max_hp  LGP sub_81F4FFA (called from CalcResults 0x820E04C), base
##           arithmetic corroborated in ENG 0x5658F0 / RUS 0x565BA0, and
##           reached live: the new-game Seraphim (22,22,22,22,1) -> 119.
##           The creature difficulty tail (stored_max x curve x ProzHP) is
##           deliberately NOT implemented — its composition is open.

## HP power constant from 0x81F4FFA (and identical in ENG/RUS).
const HP_EXP_STEP := 0.0039963233
const HP_RATIO := 0.3225806451612903   ## 10/31 as a double


## Max HP from the combat block's base pair (b74/b80), the live pair
## (a16/a22), and the level. Inputs are BLOCK OFFSETS, not named
## attributes. Returns -1 for a degenerate base (retail's own x87 would
## divide by zero; the port refuses rather than inventing a stat).
static func max_hp(b0: int, b1: int, live0: int, live1: int, level: int) -> int:
	var base := b1 + b0 * (level - 1) / 10 + b1 * (level - 1) / 10 + b0
	if base <= 0:
		return -1
	var span := 60 - b0 - b1
	if span < 0:
		span = 0
	var exponent := float(span) * HP_EXP_STEP + 1.5
	# Retail computes ((a0+a1)/base) * base^exponent in x87 and truncates
	# once, at the final int store — one truncation, here.
	var value := (float(live0 + live1) / float(base)) * pow(float(base), exponent) * HP_RATIO
	return int(value)
