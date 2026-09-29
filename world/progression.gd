class_name Progression
extends RefCounted
## XP progression arithmetic, transcribed from retail and verified against
## live observation. NOTHING ELSE lives here: no hero state, no leveling
## side effects — those belong to their own owners when C3 lands.
##
## Sources (research/engine/combat-formulas.md, findings 1286/1288):
##
##   THRESHOLDS  LGP sub_8216294, observed live at 64 entry/exit pairs:
##               threshold(L) = 100 * floor(N / 100),
##               N(L) = L^4 + 40L^3 + 150L^2 + 200L - 90.
##               The final fistp rounds to nearest but the magic-multiply
##               (0x51EB851F >> 37) is the floor; every observed value
##               (L=1..7,9) reproduces exactly.
##
##   AWARD       LGP sub_8213ED6, static with exact binary constants:
##               level <= 99 -> 1.0; then 0.985^(L-99), 0.980^(L-99),
##               0.975^(L-109) per tier. The decompile's "returns the base"
##               is the known pow artifact; asm returns the pow result.
##               Static-only above 99 (finding 1288's evidence note) — the
##               arithmetic is exact but no live witness exists past the
##               tutorial. The >205 hero-context extra factor is NOT
##               implemented: its argument semantics are unresolved and a
##               guess is forbidden.

const TIER2 := 99    ## last level at which awarded XP is unmodified
const TIER3 := 124   ## last level of the 0.985 tier
const TIER4 := 149   ## last level of the 0.980 tier

const B2 := 0.985    ## flt_86E78A0
const B3 := 0.980    ## flt_86E789C
const B4 := 0.975    ## flt_86E7898


## Cumulative XP retail requires to advance FROM level `level`.
## Integer-exact: the four terms stay in int64 until the single float
## division retail performs, mirroring sub_8216294's own int arithmetic.
static func xp_threshold(level: int) -> int:
	var L := level
	var n: int = L * L * L * L \
		+ 40 * L * L * L \
		+ 150 * L * L \
		+ 200 * L \
		- 90
	# floor(n / 100) * 100 without float drift, matching the magic-multiply
	# division exactly for every positive n.
	return 100 * (n / 100)


## The multiplier applied to XP awarded for a kill, by the HERO's level.
static func award_multiplier(level: int) -> float:
	if level <= TIER2:
		return 1.0
	if level <= TIER3:
		return pow(B2, float(level - TIER2))
	if level <= TIER4:
		return pow(B3, float(level - TIER2))
	return pow(B4, float(level - 109))
