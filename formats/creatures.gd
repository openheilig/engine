extends RefCounted
const Pak := preload("res://formats/pak.gd")
## pak/creature.pak -- the creature type table (autoresearch rows 693, 949).
##
## A FLAT CIF table, not a Sacred.Pak container: the magic passes but the bytes
## at 0x100 are header, not an index, so reading it through Pak silently
## misreads it. 474 records of 86 bytes from offset 256, and
## 256 + 474*86 == 41020 == the file length is what fixes the stride.
##
## THE FIELD MAP IS TRANSCRIBED, NOT FITTED. Retail compiles this file from
## `SCRIPTS\CREATURE.TXT` and ships the writer that dumps it back out
## (`sub_8150646`), whose fprintf calls name every field and read it straight
## off the record. Its own header comments are the documentation:
##
##     // CLASS: 0=UNK 1=HERO 2=MONSTER 3=NPC
##     // EXP:  <a>, <b>     exp = A+level*B
##     // BASE: <STK>, <RES>, <GES>, <REPHY>, <REMAG>, <CHARISMA>
##
##   +0x00 u32   id -- ALSO the items.pak record naming the Granny model, so
##               appearance needs no field of its own
##   +0x04 u8    CLASS, the 1..15 enum Sacred.Factions indexes by
##   +0x06 u8    FLAGS: 01 FLY, 02 BIG, 10 NOSHADOW, 20 GHOST, 40 BANANE,
##               80 KURVE
##   +0x08 u16   EXP a          exp awarded = a + level*b
##   +0x0a u16   EXP b
##   +0x0c u8[6] BASE: STK, RES, GES, REPHY, REMAG, CHARISMA
##   +0x14 u8[2] SKILLS       skill-type enum; see
##                            research/formats/generated/skill-families.tsv
##   +0x16 u8[16] SKILLSX     further skills
##   +0x26 u16   SPEED a
##   +0x28 u16   SPEED b
##   +0x2a 6 x {u8 kind, u8 target}   BONUS pairs
##   +0x36 u8[6] bonus value
##   +0x3c u8[6] bonus class filter (the same CL_ enum as CLASS)
##   +0x42 u8[5] Damping:RP   +0x47 RF   +0x4c RM   +0x51 RG
##
## 0x51 + 5 = 0x56 = 86, so the map accounts for every byte of the record.
##
## TWO SOURCES AGREE, AND THE MAP IS NOW COMPLETE. An outside table decoded
## about 60 of the 86 bytes (Creature.pak.txt, SacredModdingStuff1.zip) and
## this transcription reproduces every field it describes -- id, class, flags,
## the xp pair, the six attributes, the eighteen skill bytes, the speed pair,
## the six bonus pairs and their values. It then accounts for the 26 bytes that
## table left undescribed: +0x3c..0x41 is the bonus CLASS FILTER and
## +0x42..0x55 is four five-byte Damping blocks. Independent agreement on the
## described part is what licenses the new part.
##
## THE VALIDATION WORTH KEEPING is the FLAGS byte: across all 474 records,
## ZERO bits are set outside the six the writer names. A wrong offset does not
## produce that -- it produces garbage bits. The attribute ranges corroborate
## (STK 2..80, GES 5..70, REPHY 1..80), as does SPEED being 19 and 20 distinct
## round values.
##
## WHAT IS STILL NOT HERE, so a caller does not go looking: HP, and the attack
## and defence RATINGS the to-hit formula wants. This file carries base
## ATTRIBUTES; retail derives combat numbers from them through the kernel in
## research/engine/combat-formulas.md (`K(S) = (156-BalStatOff)*S/156 +
## BalStatOff + 9`) plus balance.bin, and that pass is only partly recovered.

const DATA := 256
const REC := 86

const O_ID := 0
const O_CLASS := 4
const O_FLAGS := 6
const O_EXP_A := 8
const O_EXP_B := 10
const O_BASE := 12          ## 6 x u8
const O_SKILL := 20         ## 2 x u8
const O_SKILLX := 22        ## 16 x u8
const O_SPEED_A := 38
const O_SPEED_B := 40
const O_BONUS := 42         ## 6 x {u8 kind, u8 target}
const O_BONUS_VALUE := 54   ## 6 x u8
const O_BONUS_CLASS := 60   ## 6 x u8
const O_DAMP := 66          ## 4 blocks of 5 u8: RP, RF, RM, RG

const N_BASE := 6
const N_BONUS := 6
const N_DAMP := 5
const N_SKILLX := 16

const FLAG_FLY := 0x01
const FLAG_BIG := 0x02
const FLAG_NOSHADOW := 0x10
const FLAG_GHOST := 0x20
const FLAG_BANANE := 0x40
const FLAG_KURVE := 0x80
## Every bit the writer names. Nothing outside this is set in the shipped file,
## which is the check that says the offset is right.
const FLAG_KNOWN := 0xF3

## The writer's own order, so a caller can label a value without restating it.
const BASE_NAMES: Array[String] = ["STK", "RES", "GES", "REPHY", "REMAG", "CHARISMA"]
const B_STK := 0
const B_RES := 1
const B_GES := 2
const B_REPHY := 3
const B_REMAG := 4
const B_CHARISMA := 5

## Damping block order, from the four fprintf calls.
const DAMP_NAMES: Array[String] = ["RP", "RF", "RM", "RG"]

var _rec: Dictionary[int, PackedByteArray] = {}
var _order := PackedInt32Array()


func _init(pak_dir: String) -> void:
	var b := FileAccess.get_file_as_bytes(Pak.resolve(pak_dir.path_join("creature.pak")))
	if b.size() < DATA or (b.size() - DATA) % REC != 0:
		push_error("Creatures: creature.pak missing or stride broken")
		return
	for i in (b.size() - DATA) / REC:
		var o := DATA + i * REC
		var id := b.decode_u32(o + O_ID)
		# First record wins on a duplicate id, matching how the engine's own
		# tables resolve one. Measured: no id repeats in the shipped file.
		if _rec.has(id):
			continue
		_rec[id] = b.slice(o, o + REC)
		_order.append(id)


func count() -> int:
	return _rec.size()


func has(id: int) -> bool:
	return _rec.has(id)


## Every creature id, in file order.
func ids() -> PackedInt32Array:
	return _order


## The creature's class, or 0 for an id the table does not carry. Feed it
## straight to Sacred.Factions.hostile().
func class_of(id: int) -> int:
	return _rec[id][O_CLASS] if _rec.has(id) else 0


func flags_of(id: int) -> int:
	return _rec[id][O_FLAGS] if _rec.has(id) else 0


func has_flag(id: int, flag: int) -> bool:
	return (flags_of(id) & flag) != 0


## Experience awarded for killing this creature at `level`, as retail's own
## comment states it: `exp = A + level*B`. Transcribed, not fitted.
func experience(id: int, level: int) -> int:
	if not _rec.has(id):
		return 0
	var r: PackedByteArray = _rec[id]
	return r.decode_u16(O_EXP_A) + level * r.decode_u16(O_EXP_B)


func exp_pair(id: int) -> Vector2i:
	if not _rec.has(id):
		return Vector2i.ZERO
	var r: PackedByteArray = _rec[id]
	return Vector2i(r.decode_u16(O_EXP_A), r.decode_u16(O_EXP_B))


## One BASE attribute by index; use the B_* constants. 0 for an unknown id.
func base(id: int, which: int) -> int:
	if not _rec.has(id) or which < 0 or which >= N_BASE:
		return 0
	return _rec[id][O_BASE + which]


## All six, in the writer's order.
func base_all(id: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for k in N_BASE:
		out.append(base(id, k))
	return out


## The two SPEED values. Retail's writer prints them as a BARE PAIR and does
## not say what each governs, so this returns a pair. An outside table (the
## Creature.pak.txt in SacredModdingStuff1.zip, cited by checks/
## creature_check.gd) calls them walk and run; that is a second source rather
## than a reading of this file, so the names are recorded and not applied.
func speed(id: int) -> Vector2i:
	if not _rec.has(id):
		return Vector2i.ZERO
	var r: PackedByteArray = _rec[id]
	return Vector2i(r.decode_u16(O_SPEED_A), r.decode_u16(O_SPEED_B))


## The creature's skill types, primary pair first then the SKILLSX tail, with
## zeros dropped. Values index research/formats/generated/skill-families.tsv.
func skills(id: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	if not _rec.has(id):
		return out
	var r: PackedByteArray = _rec[id]
	for k in 2:
		if r[O_SKILL + k] != 0:
			out.append(r[O_SKILL + k])
	for k in N_SKILLX:
		if r[O_SKILLX + k] != 0:
			out.append(r[O_SKILLX + k])
	return out


## The six bonus slots as {kind, target, value, class}. An empty slot -- both
## bytes zero -- is dropped, matching the writer, which prints a slot only when
## the u16 at its pair offset is non-zero.
func bonuses(id: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not _rec.has(id):
		return out
	var r: PackedByteArray = _rec[id]
	for i in N_BONUS:
		var kind: int = r[O_BONUS + i * 2]
		var target: int = r[O_BONUS + i * 2 + 1]
		if kind == 0 and target == 0:
			continue
		out.append({"kind": kind, "target": target,
			"value": r[O_BONUS_VALUE + i], "class": r[O_BONUS_CLASS + i]})
	return out


## One damping block, five values; `which` indexes DAMP_NAMES. All zero when
## the creature declares none, which is the ordinary case -- only 11 to 13
## records carry each block.
func damping(id: int, which: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	if not _rec.has(id) or which < 0 or which >= DAMP_NAMES.size():
		return out
	var r: PackedByteArray = _rec[id]
	for k in N_DAMP:
		out.append(r[O_DAMP + which * N_DAMP + k])
	return out
