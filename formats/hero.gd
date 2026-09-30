extends RefCounted
## THE NEW-GAME HERO, read from retail rather than invented.
##
## `templates/hero00.ptx` .. `hero07.ptx` are `.pax` hero saves in all but
## extension -- same `AMH\x1b` magic, same 16-slot section table -- and they
## hold the character each class starts with. Sacred.Pax already framed them;
## this class reads the `0xC7` character stream inside.
##
## WHY THIS MATTERS TO THE PORT: Encounter used to invent the hero's level,
## attack rating and defence rating because "nothing recovered says which
## attribute becomes which rating". The templates carry SKILL LEVELS, and skill
## level is what the recovered rating curve actually consumes
## (Combat.skill_rating), so the invented numbers can go.
##
## CHARACTERTYPE IS A ONE-BASED INDEX INTO global.res's class-name list.
## Type N is slot N-1, and every one of the eight is corroborated twice --
## once by the name, once by the character it describes:
##
##   type 1  Seraphim     Magic Lore + Weapon Lore, magic and melee balanced
##   type 2  Gladiator    STK 33, the highest, and REMAG exactly 0
##   type 3  Battle Mage  Magic Lore + Meditation, REMAG 30, the highest
##   type 4  Dark Elf     Weapon Lore + Concentration, REMAG 0
##   type 5  Wood Elf     the Agility SKILL, and GES 29, the highest
##   type 6  Vampiress    the Vampirism skill, which no other class has
##   type 8  Dwarf        Weapon Lore + Constitution, CHARISMA 8, the lowest
##   type 9  Daemon       STK 35 and REMAG 28, both near the top
##
## TYPE 7 IS ABSENT and that is not a gap: slot 6 repeats "Vampiress", so the
## name list has two entries for one class and no template claims the second.
##
## Every class starts at LEVEL 1 with 5000 gold and exactly TWO skills at
## level 1. Findings log row 955.

## `0xC7` character-stream offsets. Underworld build; see
## research/formats/pax-saves.md for the ones this class does not read.
const O_TYPE := 0x03DD          ## u32 CharacterType
const O_EXP := 0x03E1           ## u32 experience
const O_ATTR := 0x03E5          ## u16 x6 base attributes
const O_SKILL_ID := 0x03F9      ## u8 x8
const O_SKILL_LEVEL := 0x0401   ## u8 x8
const O_ATTR_NOW := 0x041F      ## u16 x6, the same six again -- see attributes()
const O_GOLD := 0x041B          ## u32
const O_LEVEL := 0x042B         ## u32
const O_CA := 0x04CB            ## u16 combat-art count
const O_CA_LIST := 0x04CD       ## the records themselves, straight after it
## THE SAVED RECORD IS THE LIVE ONE. Each entry is the same 22-byte struct
## retail keeps in memory at the combat block's +250 (findings log row 1044),
## written out field for field -- so the template is not a compact description
## of a starting art, it is a snapshot of the art already installed.
const CA_STRIDE := 22
const CA_KIND := 0x00           ## u32: 1 = spell, 2 = combat art
const CA_ID := 0x04             ## u16
const CA_PERM := 0x06           ## u8, from runes
const CA_TEMP := 0x07           ## u8, from items
const CA_FLAGS := 0x08          ## u16, bit 0 = known
const CA_TOTAL := 0x0A          ## f32, regeneration seconds
const CA_MULT := 0x0E           ## f32, the per-art multiplier -- 1.0 in every template
const CA_REMAINING := 0x12      ## f32, 0.0 in every template: a new hero's arts are ready

const SECTION := 0xC7
const ITEMS := 0xC8
const ATTRS := 6
const SKILLS := 8
## The six attributes, in `creature.pak`'s own order -- the same six columns
## retail's `creature.txt` writer prints for a monster, so hero and monster
## share one attribute vocabulary.
const ATTR_NAMES := ["STK", "RES", "GES", "REPHY", "REMAG", "CHARISMA"]

var found := false
var character_type := 0
var level := 0
var experience := 0
var gold := 0
var combat_arts := 0
var _attr := PackedInt32Array()
var _attr_now := PackedInt32Array()
var _skill_id := PackedInt32Array()
var _skill_level := PackedInt32Array()
var _items := PackedInt32Array()
var _ca := PackedByteArray()


## CharacterType (one-based, GetTypeName's table at 0x8735AC0; 7 is absent
## on purpose -- sub_8265BF6 remaps it to 6) -> the bin/<dir> class
## directory name. G1: --class= resolution and template matching.
const TYPE_DIR := {
	1: "type_npc_seraphim", 2: "type_npc_gladiator", 3: "type_npc_magician",
	4: "type_npc_darkelve", 5: "type_npc_elve", 6: "type_npc_vampirelady",
	8: "type_npc_zwerg", 9: "type_npc_daemonin",
}


## The class directory for this hero's CharacterType, or "" when the type
## has no port class (7) or the hero did not read.
func class_dir() -> String:
	if not found or character_type <= 0:
		return ""
	return TYPE_DIR.get(character_type, "")


func _init(path: String) -> void:
	var pax = Sacred.Pax.new(path)
	if not pax.is_open():
		return
	var c: PackedByteArray = pax.section(SECTION)
	if c.size() < O_CA + 2:
		push_warning("Hero: %s has no readable 0xC7 stream" % path)
		return
	character_type = c.decode_u32(O_TYPE)
	experience = c.decode_u32(O_EXP)
	gold = c.decode_u32(O_GOLD)
	level = c.decode_u32(O_LEVEL)
	combat_arts = c.decode_u16(O_CA)
	var end := O_CA_LIST + combat_arts * CA_STRIDE
	if combat_arts > 0 and end <= c.size():
		_ca = c.slice(O_CA_LIST, end)
	for i in ATTRS:
		_attr.append(c.decode_u16(O_ATTR + i * 2))
		_attr_now.append(c.decode_u16(O_ATTR_NOW + i * 2))
	for i in SKILLS:
		_skill_id.append(c[O_SKILL_ID + i])
		_skill_level.append(c[O_SKILL_LEVEL + i])
	_read_items(pax)
	found = character_type > 0


## The starting inventory, as `items.pak` record indices (pax-saves.md settled
## that id space at 85% against a 34% control). Walks the 0xC8 section by its
## `FEEDF00D` record marker rather than by an assumed stride.
func _read_items(pax) -> void:
	var b: PackedByteArray = pax.section(ITEMS)
	var o := 4
	while o + 8 <= b.size():
		if b.decode_u32(o + 4) != 0xFEEDF00D:
			break
		_items.append(b.decode_u32(o))
		var nxt := o + 12
		while nxt + 4 <= b.size() and b.decode_u32(nxt) != 0xFEEDF00D:
			nxt += 1
		if nxt + 4 > b.size():
			break
		o = nxt - 4


## The class name's slot in global.res. CharacterType is one-based; see the
## class doc for the eight-way corroboration.
func class_slot() -> int:
	return character_type - 1


## The six base attributes, in ATTR_NAMES order.
##
## A SECOND COPY of the same six sits at O_ATTR_NOW and is byte-identical in
## all eight templates. Presumably base and current, equal because a level-1
## character's starting gear has not moved them -- but nothing recovered says
## so, and a template cannot tell the two apart, so both are exposed and
## neither is named "current".
func attributes() -> PackedInt32Array:
	return _attr


func attributes_second() -> PackedInt32Array:
	return _attr_now


func attribute(name: String) -> int:
	var i := ATTR_NAMES.find(name)
	return _attr[i] if i >= 0 and i < _attr.size() else 0


## The skills the character knows, as {id, level}. Only the filled slots: a
## zero id is an empty slot, not a skill with id 0.
func skills() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i in SKILLS:
		if _skill_id[i] != 0:
			out.append({"id": _skill_id[i], "level": _skill_level[i]})
	return out


## The combat arts the character starts with, as records in retail's own
## layout. Eight templates carry 19 between them: every class gets two, except
## the two that get three and four.
##
## THE TOTAL IS THE ONE RETAIL SAVED, not one recomputed here. Thirteen of the
## nineteen agree with `CombatArts` to the last bit; the other six are the
## table's value divided by exactly 1.12, which is per ART and not per hero --
## hero07 carries two of each. What that factor is has not been recovered, so
## the saved number is used and the discrepancy is recorded rather than
## smoothed over. See research/engine/combat-formulas.md.
func combat_arts_list() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _ca.is_empty():
		return out
	for i in combat_arts:
		var o := i * CA_STRIDE
		if o + CA_STRIDE > _ca.size():
			break
		out.append({
			"kind": _ca.decode_u32(o + CA_KIND),
			"id": _ca.decode_u16(o + CA_ID),
			"level": _ca[o + CA_PERM],
			"temp": _ca[o + CA_TEMP],
			"flags": _ca.decode_u16(o + CA_FLAGS),
			"total": _ca.decode_float(o + CA_TOTAL),
			"mult": _ca.decode_float(o + CA_MULT),
			"remaining": _ca.decode_float(o + CA_REMAINING),
		})
	return out


## The level a named skill is known at, or 0 when the character lacks it.
func skill_level(skill_id: int) -> int:
	for i in SKILLS:
		if _skill_id[i] == skill_id:
			return _skill_level[i]
	return 0


func items() -> PackedInt32Array:
	return _items
