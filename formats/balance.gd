extends RefCounted
const Pak := preload("res://formats/pak.gd")
## bin/balance.bin -- the global tuning table, read at the offsets the key map
## names (research/formats/generated/balance-keymap.tsv, 354 of 379 keys
## resolved to offsets).
##
## The file is a FLAT BLOB: the key NAMES are not in it. Retail's loader
## (`sub_812BA04`) parses a `KEY=value` text file and stores each value into a
## global, and the key map was recovered by pairing those stores with their
## offsets. So a caller here asks by OFFSET and the names live in constants
## beside the offsets, which is the only honest arrangement while the names are
## outside the file.
##
## Only the offsets this project actually consumes are named. Adding one means
## looking it up in the key map, not guessing.

const F32 := 4

## The saturating-rating triplets. Each family stores {off, s, w} at three
## consecutive f32 slots, and the family's name is retail's own key prefix.
## AW is Angriffswert (attack rating), VW Verteidigungswert (defence rating).
## See Combat.skill_rating for what the three numbers do.
const AW := {
	"STK": 188, "SK": 116, "AK": 140, "KK": 164, "FK": 92, "BK": 212,
	"FEK": 236, "W": 380, "HR": 404,
}
const VW := {"W": 392, "HP": 416}
## Boss and champion defence multipliers, from the same table.
const VW_FAK_BOSS := 2252
const VW_FAK_CHAMP := 2256
## The derived-stat kernel's offset, used by Combat.stat_kernel.
const BAL_STAT_OFF := 32

## THE DIFFICULTY LEVEL-BAND ADJUSTMENTS, and they were the last unread input to
## the creature-level clamp (Sacred.SpawnLevels.level_for).
##
## Both are SIX-ELEMENT int32 ARRAYS, indexed by the difficulty index. The key
## map names only the first element of each, which is why they read as scalars:
## the gap to the next named key is exactly 24 bytes in both cases (`OffLevel`
## 1932 -> `Respawn` 1956, `LevelKap` 2448 -> `ObereEXPAnteil` 2472), and the
## parser that fills them (`sub_812BA04`) splits a `key = a,b,c,d,e,f` line and
## caps the count at six.
##
##   OffLevel  = [0, 35,  70, 128,   0, 0]   added to the band's LOW bound
##   LevelKap  = [50, 120, 190, 250, 250, 0] added to the band's HIGH bound
##
## They are int32 despite sitting in a float table: the writers are `fistp`
## after `strtod` with the FPU rounding forced to truncate (`0x8130cf0`) and a
## plain store after `strtol` (`0x8130b1f`). Read as floats they are denormals.
const OFF_LEVEL := 1932
const LEVEL_KAP := 2448
const DIFFICULTIES := 6
## Index 5 is the fallback and is {0, 0} -- no adjustment at all, so the band's
## own bounds are used verbatim. Index 4 is dead data: no code path selects it.
const DIFF_FALLBACK := 5

var found := false
var _b := PackedByteArray()


func _init(install: String) -> void:
	_b = FileAccess.get_file_as_bytes(Pak.resolve(install.path_join("bin/balance.bin")))
	found = _b.size() > 0


## The f32 at `offset`, or `fallback` when the file is missing or too short.
## A missing balance.bin must not silently become zero: every value here is a
## divisor or a curve bound, and zero changes the arithmetic rather than
## disabling it.
func f32(offset: int, fallback: float = 0.0) -> float:
	if not found or offset < 0 or offset + F32 > _b.size():
		return fallback
	return _b.decode_float(offset)


func i32(offset: int, fallback: int = 0) -> int:
	if not found or offset < 0 or offset + F32 > _b.size():
		return fallback
	return _b.decode_s32(offset)


## One family's {off, s, w} as a Vector3, reading the three consecutive slots.
## `table` is AW or VW.
func triplet(table: Dictionary, family: String) -> Vector3:
	if not table.has(family):
		return Vector3.ZERO
	var o: int = table[family]
	return Vector3(f32(o), f32(o + F32), f32(o + F32 * 2))


## Every family in a table, sorted, so a gate can sweep them without repeating
## the list.
func families(table: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for k in table:
		out.append(k)
	out.sort()
	return out


## The difficulty INDEX retail derives from the selected difficulty, exactly as
## `sub_81806DC` and ~20 other sites do it:
##
##     4 -> 3,  3 -> 2,  2 -> 1,  1 -> 0,  anything else -> 5
##
## `difficulty` is 1..4 = Silver / Gold / Platinum / Niob. The odd shape is
## retail's own: the default arm is `5 * (d != 1)`, so 1 falls through to 0 and
## everything else lands on the no-adjustment fallback.
static func difficulty_index(difficulty: int) -> int:
	match difficulty:
		4: return 3
		3: return 2
		2: return 1
		1: return 0
	return DIFF_FALLBACK


## `(OffLevel[i], LevelKap[i])` for a difficulty, as the two amounts added to a
## sector band's low and high bounds. Zero-zero when balance.bin is missing,
## which is the identity and leaves the band untouched rather than inventing a
## shift.
func difficulty_adjust(difficulty: int) -> Vector2i:
	var i := difficulty_index(difficulty)
	if i < 0 or i >= DIFFICULTIES:
		return Vector2i.ZERO
	return Vector2i(i32(OFF_LEVEL + i * 4), i32(LEVEL_KAP + i * 4))


## One of the six-element int arrays, whole. For a caller that wants to see the
## whole progression rather than one difficulty's slot.
func int_array(offset: int, n: int = DIFFICULTIES) -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in n:
		out.append(i32(offset + i * 4))
	return out


## `ProzAW[difficulty]` -- the factor a NON-HERO's attack and defence ratings
## are multiplied by. The two getters (sub_81FA5AA, sub_81FA622) apply it only
## when the creature's type-id exceeds 0x10, and the eight playable classes are
## 1..9, so it never touches the player. Retail ships
## [1.0, 1.5, 2.5, 4.5, 1.04, 0.65]: a monster on Niob hits and blocks at four
## and a half times its own numbers.
const PROZ_AW := 1812

func proz_aw(difficulty: int) -> float:
	var i := difficulty_index(difficulty)
	if i < 0 or i >= DIFFICULTIES:
		return 1.0
	return f32(PROZ_AW + i * 4, 1.0)
