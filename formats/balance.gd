extends RefCounted
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

var found := false
var _b := PackedByteArray()


func _init(install: String) -> void:
	_b = FileAccess.get_file_as_bytes(install.path_join("bin/balance.bin"))
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
