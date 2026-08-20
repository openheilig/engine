class_name Regen
extends RefCounted
## COMBAT-ART REGENERATION, transcribed from retail (findings log rows
## 1043-1046). This is Sacred's answer to a mana pool, and it is not one: an
## art costs TIME, each art has its own clock, and nothing is shared between
## them. There is no mana in Sacred -- no element, no attribute, no field (row
## 1042) -- so there is nothing here for an orb to read.
##
## Nothing in this file reads the scene tree or owns a frame loop (R10.1): the
## caller supplies `dt` and holds the state.
##
## THE WHOLE CHAIN, and each step is a function below:
##
##     total     = base + level*step          per art, LINEAR, attribute-free
##                 (+ half the temporary level's extra)
##     rate      = bonus * (1 + attribute/100)     per creature, per kind
##     remaining = clamp(remaining - dt*mult*rate, 0, total)
##     fraction  = 1 - remaining/total        what the art slot draws

## Art kinds, as `sub_81ADA76` tags them when an art is learned: it resolves the
## id through the SPELL table for 1 and the COMBAT-ART table for 2.
enum { SPELL = 1, COMBAT_ART = 2 }

## A temporary level (from an item) buys HALF what a permanent one (from a rune)
## does. `sub_82047D4` computes the curve at both levels and adds half the gap.
const TEMP_WEIGHT := 0.5

## One attribute point is ONE PERCENT faster, multiplicatively on the
## accumulated rate (`flt_86E7454`, read from the image). Multiplicative, so it
## can never reach zero or turn the clock backwards.
const ATTR_PERCENT := 0.01

## Retail's own ready test, at `sub_8218774`. NOT `== 0.0`, and the difference
## is not pedantry: a float countdown decremented by a frame delta does not
## land on zero.
const READY_EPSILON := 0.01

## The per-art multiplier `sub_82047D4` resets on every recompute. Effects bend
## this rather than the total.
const ART_MULT := 1.0

## A buff at the combat block's +320 makes ONE kind regenerate faster by
## multiplying the delta before it lands.
const BUFF_FACTOR := 0.8


## The art's own regeneration time, in seconds. LINEAR in the level, with both
## coefficients stored per art -- floats at +64/+68 of the combat-art table for
## an art, u16 at +62/+64 of the spell record for a spell.
##
## A STRONGER ART COMES BACK MORE SLOWLY: that is the whole cost model, and it
## is why levelling one is a trade rather than a gift.
static func total(base: float, step: float, perm: int, temp: int = 0) -> float:
	var at_perm := base + step * float(perm)
	var at_both := base + step * float(perm + temp)
	if at_both > at_perm:
		return at_perm + (at_both - at_perm) * TEMP_WEIGHT
	return at_perm


## One creature's regeneration rate for one KIND. `bonus` is the accumulated
## item and buff total that `sub_820E04C` builds; `attribute` is Mental
## Regeneration for spells and Physical Regeneration for combat arts --
## `creature.pak` names the two columns REMAG and REPHY, which is where the
## port already reads them.
static func rate(bonus: float, attribute: int) -> float:
	return bonus * (1.0 + float(attribute) * ATTR_PERCENT)


## The two rates a creature has, keyed by kind, from its own two attributes.
static func rates(bonus: float, rephy: int, remag: int) -> Dictionary:
	return {SPELL: rate(bonus, remag), COMBAT_ART: rate(bonus, rephy)}


## One frame of one art's countdown. Clamped at BOTH ends by retail, which is
## what keeps a long frame from overshooting into a negative clock.
static func tick(remaining: float, art_total: float, dt: float,
		art_rate: float, mult: float = ART_MULT, buffed := false) -> float:
	var d := dt * mult * art_rate
	if buffed:
		d *= BUFF_FACTOR
	return clampf(remaining - d, 0.0, art_total)


## What the art slot draws: 0 just after the art is used, 1 when it is ready.
## `view/hud.gd` slices the slot at this fraction exactly as the health ring is
## sliced -- retail draws both the same way.
static func fraction(remaining: float, art_total: float) -> float:
	if art_total <= 0.0:
		return 1.0
	return clampf(1.0 - remaining / art_total, 0.0, 1.0)


## Retail's own test, verbatim.
static func ready(remaining: float) -> bool:
	return remaining <= READY_EPSILON
