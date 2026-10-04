extends RefCounted
## pak/items.pak -- the object DEFINITION table, and the only place retail keeps
## the German authoring names ("DCTower innenunten 1A_1", "TH01 Wand innen 1_02").
##
##   "ITM" v5, 32768 uniform 128-byte records.
##   +0x04 u32  texture.pak atlas id for static flags 0x20 (miniatures)
##   +0x10 u32  mixed.pak sprite id
##   +0x37      NUL-terminated name (ids 1..4 are SERAPHIM/GLADIATOR/MAGICIAN/DARKELVE.GRN)
##
## Why this class exists: Sacred does not fade roofs or depth-sort interiors
## against exteriors. It SWAPS the two sets -- from outside a house you see an
## unbroken roof and no interior at all, and from inside the roof and outer
## walls are gone entirely (manuals/Screenshots/sacred88.png and sacred86.png).
## Drawing both at once is what produced the "dark voids": unlit interior floors
## and walls painted over the roofs they belong under.
##
## The static's type indexes an items.pak RECORD, whose +0x10 selects MIX art:
##   static.pak +0x04 ----------> items.pak record
##   items.pak +0x10 -----------> mixed.pak sprite
##   items.pak +0x37 -----------> authoring name
## Direct miniatures instead select item +0x04; their MIX id may be zero.
##
## Do NOT use the items.pak index as a mixed.pak index. That reading gives 70.2%
## art for the innen entries against a 77.6% baseline (worse than chance) and
## resolves every DCTower innen* entry to a zero-tile sprite. Reading the id from
## +0x10 instead hits 100.0% for innen against 82.0% overall.

const Pak := preload("res://formats/pak.gd")
const Weapons := preload("res://formats/weapons.gd")

const SPRITE_OFF := 0x10
const MINIATURE_TEXTURE_OFF := 0x04
const SHADOW_RADIUS_OFF := 0x14
const NATIVE_TYPE_MAX := Weapons.MAX_TYPE
const NAME_OFF := 0x37
const REC_MIN := 0x40

## THE ITEM CARRIES ITS OWN SKIN, and the engine prefers it over the mesh's.
##
## `cGranny::bindTextures` (retail `0x80f7866`) reads an override at the
## cGranny's `+0x34` and uses it INSTEAD of looking the mesh's own texture name
## up in `texture.pak`, whenever it is non-zero. Its callers all follow one
## shape -- set override, draw, clear override -- and the value they set comes
## from `0x8136692(items, id)`, which is `*(u32*)(items + id*128 + 24)`. The
## sibling `0x81365f8` returns `items + id*128 + 71`, the authoring name this
## reader already takes from record `+0x37`, so the engine's table base sits 16
## bytes below record 0 and the override field is record **`+0x08`**.
##
## It is a direct `texture.pak` ENTRY INDEX. Not a name, not a hash.
##
## Why it has to exist: one mesh wears many skins. `SHIELD_KITE.GRN` is named by
## twelve items whose `+0x08` values are 8391..8402 -- exactly the twelve
## `SHIELD_KITE*.TGA` entries, one to one and onto -- while the mesh's own
## texture name, `Shield_kite_cross.tga`, ships in no pak at all. Over the 2652
## item records that name a `.GRN` and index `texture.pak`, model-name to
## texture-name token agreement is mean 0.630 against a permuted control at
## 0.012.
const TEXTURE_OFF := 0x08

## The item CATEGORY byte. Decoded 2026-08-17; see category_of below for the
## value table and how each value was named. REC_MIN is 0x40, so every record
## this reader accepts is long enough to carry it.
const CATEGORY_OFF := 0x2e

## Category 25, the whole of which is SeraWings01/02/05 and four siblings -- 7
## records in a 32,768-record corpus. Named as a constant because _dress_player
## skips it, and a bare 25 at that call site would read as a magic number.
const CATEGORY_WINGS := 25

## Category 18, boots -- named for the same reason as CATEGORY_WINGS: the
## garment-hiding rule in main.gd dispatches on it, and a bare 18 at that
## call site would read as a magic number. (Row 1125's category census:
## boots 18, belt 19, shoulder 21, arms 22.)
const CATEGORY_BOOTS := 18

## items.pak RECORD INDEX -> mixed.pak sprite id (the record's +0x10 field).
## static.pak +0x04 is an items.pak record index, NOT a mixed.pak index --
## Resacred's chain is PakStatic.itemTypeId -> PakItemType.mixedId ->
## PakMixedDesc (autoresearch row 659). For most records the two numbers are
## equal, which is why drawing mixed.sprite(type) directly looked right; they
## diverge for the shared furniture library, where record 9223 "Chair 2"
## carries sprite 655. Reading type as a sprite id therefore drew NOTHING for
## every chair, table, shelf, crate and bed in the world -- the missing
## chapel interior. Every map below is keyed by RECORD INDEX for the same
## reason: every caller has a static's type field, never a sprite id.
var _sprite: Dictionary[int, int] = {}
var _texture: Dictionary[int, int] = {}     ## items record -> texture.pak entry (+0x08)
var _miniature_texture := PackedInt32Array() ## direct atlas, NOT the +0x08 mesh skin
var _shadow_radius: Dictionary[int, int] = {}
var _static_shadows: Dictionary[int, Dictionary] = {}
var _initial_heading_degrees: Dictionary[int, float] = {}
var _interior: Dictionary[int, bool] = {}   ## items record -> is interior art
## items.pak record index -> bitmask of the building LEVELS this part belongs to.
## Names run <BUILDING>_<level>_<part>, and the level token is either a digit
## or a German "und" pair like 0U1 meaning the piece belongs to levels 0 AND 1
## (a stair or a shared wall). Token frequencies over all 17408 named entries:
## _1_ 455, _0_ 299, _2_ 249, _3_ 27, _4_ 17, _0U1_ 87, _0U2_ 63, _0U4_ 40.
## Two further forms are decoded since 2026-08-13 (the OZELT1 camp tents):
##   <B>_<level>_<part><letter>   -- a letter-suffixed part (`_0_00A`), the
##     four corner posts of a tent; the letter is part of the part number,
##     not a level marker.
##   <B>_<level>_<a>U<b>          -- a part RANGE (`_0_11U21` = parts 11..21
##     as one continuous strip). The U here binds part numbers, NOT levels;
##     the piece still belongs to the single level before the first
##     underscore. This is distinct from `_0U1_` where U follows the level
##     digit directly and means level 0 AND level 1.
var _levels: Dictionary[int, int] = {}
## items.pak record index -> true if this part sits on its BUILDING FAMILY's
## highest level. Verified as the interior on two structurally different
## buildings: BLACKSMITH (levels 0,1 -- hiding 0 opens the roof onto the
## forge, anvil and barrel) and KLOSTER_KAPELLE01 (levels 0,1,2 -- hiding
## 0,1 opens the roof onto the chapel floor and benches). Family is the name
## up to the level token, so DCHOUSE01_FINAL_1_07 belongs to DCHOUSE01_FINAL.
var _top: Dictionary[int, bool] = {}

var _fam_top: Dictionary[String, int] = {}   ## family -> highest level seen
var _fam_of: Dictionary[int, String] = {}    ## items record -> family
var _lvl_of: Dictionary[int, int] = {}       ## items record -> its own level

## items.pak record index -> that record's authoring name. Keyed by record,
## so it is exact: the older sprite-id keying collapsed every record sharing
## a +0x10 value onto whichever came last in file order. Still one-way:
## record -> a name, never name -> record.
var _name: Dictionary[int, String] = {}

## items record -> the +0x2e item category. See category_of for the decode.
var _category: Dictionary[int, int] = {}
## Raw definition flags used by retail's static draw-list routing.
var _draw_flags: PackedInt32Array = PackedInt32Array()

func _init(pak: Pak) -> void:
	var definitions: Array[PackedByteArray] = []
	definitions.resize(pak.count())
	for i in pak.count():
		definitions[i] = pak.blob(i)
	# Retail fills generated weapon types before consumers resolve their art.
	# A single ordered pass is significant for chained and forward parents.
	var weapons := Weapons.new(pak.requested_path.get_base_dir().path_join("weapon.pak"))
	weapons.apply_to(definitions)
	# Level-AND form (_0U1_) or single-level form (_1_), then a part number
	# that may carry a letter suffix (_00A) or a part-range (_11U21). The
	# part token is `\d+[A-Za-z]?(?:U\d+)?` -- the optional trailing letter
	# and optional U-range belong to the PART, never to the level.
	var lv := RegEx.create_from_string("_(\\d)(?:U(\\d))?_(\\d+[A-Za-z]?(?:U\\d+)?)$")
	_draw_flags.resize(pak.count())
	_miniature_texture.resize(pak.count())
	for i in pak.count():
		var r := definitions[i]
		if r.size() < REC_MIN:
			continue
		_draw_flags[i] = r.decode_u32(0)
		_miniature_texture[i] = r.decode_u32(MINIATURE_TEXTURE_OFF)
		_shadow_radius[i] = r.decode_u32(SHADOW_RADIUS_OFF)
		if r.size() >= 91:
			_initial_heading_degrees[i] = r.decode_float(87)
		if (_draw_flags[i] & 0x10000) != 0:
			if r.size() < 102:
				push_error("Items: shadow definition %d is truncated" % i)
			else:
				_static_shadows[i] = {
					"tile": r.decode_u16(91),
					"offset": Vector2(r.decode_s16(93) * 2, r.decode_s16(95) * 2),
					"skew": r[99] != 0, "radius": float(r.decode_u16(100)),
				}
		_sprite[i] = r.decode_u32(SPRITE_OFF)
		_category[i] = r[CATEGORY_OFF]
		var tex := r.decode_u32(TEXTURE_OFF)
		if tex != 0:
			_texture[i] = tex
		var nm := r.slice(NAME_OFF).get_string_from_ascii()
		if nm != "":
			_name[i] = nm
		var m := lv.search(nm)
		if m != null:
			var mask := 1 << int(m.get_string(1))
			var hi := int(m.get_string(1))
			if m.get_string(2) != "":
				mask |= 1 << int(m.get_string(2))
				hi = maxi(hi, int(m.get_string(2)))
			_levels[i] = mask
			var f := nm.substr(0, m.get_start())
			_fam_top[f] = maxi(_fam_top.get(f, 0), hi)
			_fam_of[i] = f
			_lvl_of[i] = hi
		# containsn: case-insensitive. The data mixes "innen", "Innenwand" and
		# separated forms like "innen mitte", so a substring test is the rule --
		# not a prefix or an exact match.
		if nm.containsn("innen"):
			_interior[i] = true

func count() -> int:
	return _interior.size()


## Total items.pak records (the _category map holds one entry per record).
## NOT count() -- that one counts interior-flagged items only, a name it
## carried from the interior-hiding work.
func record_count() -> int:
	return _category.size()

## The mixed.pak sprite id a static's type field resolves to, or 0 when absent.
## Zero means no MIX tiles, not necessarily no art: static flags 0x20 select
## miniature_texture_of() instead, using the placement's atlas metadata.
func sprite_of(record: int) -> int:
	return _sprite.get(record, 0)

## Direct miniature atlas at item +0x04. LGP sub_80E4AC2's miniature branch
## and Win 2.28 chunk 00017:8483-8651 bind this instead of item +0x10.
func miniature_texture_of(record: int) -> int:
	return _miniature_texture[record] if record >= 0 and record < _miniature_texture.size() else 0

## LGP 0x08139092: only a VALID type's stored zero means radius 50.
func shadow_radius_of(record: int) -> float:
	if record < 1 or record > NATIVE_TYPE_MAX or not _shadow_radius.has(record):
		return 0.0
	var radius: int = _shadow_radius[record]
	return float(radius if radius != 0 else 50)

## Static SHADOW_TREE00 geometry, not the actor blob radius at +20.
## LGP 0x080EA104; all 125 start-scene quads match live native vertices.
func static_shadow_of(record: int) -> Dictionary:
	return _static_shadows.get(record, {})

## cObjectManager::create (LGP chunk13:8467) sends item
## record+87 as event64; cObject3D converts that angle through 0x081654CE.
func initial_heading_degrees(record: int) -> float:
	if record < 1 or record > NATIVE_TYPE_MAX:
		return NAN
	return _initial_heading_degrees.get(record, NAN)

## Native definition admission precedes every property-based draw predicate.
func has_definition(record: int) -> bool:
	return record >= 1 and record <= NATIVE_TYPE_MAX and _sprite.has(record)

## Definition flags at record +0x00, not the placement's static.pak flags.
func draw_flags(record: int) -> int:
	return _draw_flags[record] if record >= 0 and record < _draw_flags.size() else 0

## True if this items record is building-interior art.
func is_interior(record: int) -> bool:
	return _interior.has(record)

## Bitmask of building levels this record belongs to, 0 if unnamed/unparsed.
func levels(record: int) -> int:
	return _levels.get(record, 0)

func level_count() -> int:
	return _levels.size()

## Building-family name parsed from this sprite's level token, or "" for
## an unlevelled/unnamed sprite. Public read accessor for Footprints: the
## family table stays owned and populated by Items rather than duplicated.
func family_of(record: int) -> String:
	return _fam_of.get(record, "")

## True if this sprite is on its family's TOP level, i.e. the interior set.
## Props (fences, flowers, market stalls) carry no level and return false --
## correctly, since a fence has no storey, though it also means interior
## props like an anvil or barrel are not caught by this and stay visible.
func is_top_level(record: int) -> bool:
	if not _fam_of.has(record):
		return false
	return _lvl_of[record] == _fam_top[_fam_of[record]]

## The authoring name of this items.pak record, or "" if it has none.
func name_of(record: int) -> String:
	return _name.get(record, "")


## The `texture.pak` entry index this item skins its mesh with, or -1 when the
## record carries none. See TEXTURE_OFF: -1 means "fall back to the mesh's own
## texture name", which is exactly what retail does when the override is zero.
func texture_of(record: int) -> int:
	return _texture.get(record, -1)


## ITEM CATEGORY -- what KIND of thing this record is, not which slot it fills.
##
## Decoded 2026-08-17 by censusing every byte of the 128-byte record against the
## six Seraphim garments, whose body parts are known: only `+0x20` (a running
## index, 160..165 -- rejected) and this byte took six distinct values there. The
## corpus then names every value on its own, because Daemonia's armour family is
## spelled out part by part:
##
##     3  hero/creature BODY   477  SERAPHIM.GRN, GLADIATOR.GRN, MAGICIAN.GRN
##     5  one-hand weapon      240  daem_schwert01.grn
##     6  chest armour         308  Daemonia_Armor01_Body.grn
##     8  ring                  91  Ring1_Edel.grn
##    13  shield                42  SHIELD_KITE.GRN
##    16  scroll               143  17 helm 129, 18 boots 97, 19 belt 127
##    20  amulet               156  21 shoulder 68, 22 arms 107, 23 legs 81
##    24  gloves                42  27 arrow 10, 29 barding 26, 33 dwarf cannon 4
##    25  WINGS                  7  SeraWings01/02/05 -- the whole category
##
## The weighted/rigid split corroborates it without being used to derive it:
## every armour category is 100% skinned (6, 17, 18, 19, 21, 22, 23, 24 -- 908
## records, 0 rigid) and every prop category is 100% rigid (8, 9, 10, 13, 16, 27).
## A field invented to explain one set would not also sort the corpus that way.
##
## NOT A SLOT INDEX. Armalion's `cCreature` carries `PC_EQUIPMENT_MAX == 13`
## slots and dispatches on `equipment_getSlotType(eslot)`, which returns 1 for
## slots 0,1,2,3,7 (worn, via `grnWearEquipment`), 2 for 4,5,6,9,10,11,12
## (attached to a bone, via `attachEquipment` -- `getSlotAttachBoneName` maps
## 9/10 to `Bip01 L/R Hand` and 5/6 to `Bip01 L/R Finger31`), and 0 for slot 8
## alone, which is neither. This byte has ~27 values, so it feeds that mapping
## rather than being it. Recovering the category-to-slot table is open work.
func category_of(record: int) -> int:
	return _category.get(record, -1)

## --- Equipment slots --------------------------------------------------------
##
## Retail's cCreature carries an 18-slot equipment array at +0x1A4
## (granny-grn.md, "The base body already wears boots"): 0x00..0x06 run
## helmet/body/belt/arms/legs/shoes/gauntlets, main hand is 0x0D, off hand
## 0x0C, mount 0x12. The category byte above FEEDS that mapping rather than
## being it -- which is the "open work" the doc comment on category_of names.
## Closed 2026-08-30 by a full-corpus census (tmp/census_slots.gd): every
## equipment category's sample names name the body part outright --
## Daemonia_Armor01_Shoes = 18, ..._Legs = 23, ..._Gloves = 24, ..._Shoulder
## = 21 -- and the Armalion prior (worn for slots 0,1,2,3,7) puts shoulder at
## 7, the one worn slot outside 0x00..0x06.
enum Slot {
	HELMET = 0x00, BODY = 0x01, BELT = 0x02, ARMS = 0x03,
	LEGS = 0x04, SHOES = 0x05, GAUNTLETS = 0x06, SHOULDER = 0x07,
	OFF_HAND = 0x0C, MAIN_HAND = 0x0D, MOUNT = 0x12,
}

## category byte -> slot. Absent categories are not equipment: 0 empty
## records, 1/15 gibs, 3 base bodies, 4 chests, 7 heads/statues, 8 rings,
## 9 bottles, 10 doors, 12 FX, 16 scrolls, 20 brooches/amulets, 25 wings
## (picker-screen display only, main.gd skips them), 26/28 upgrade wares,
## 27 arrows, 33 dwarf cannon.
const _CATEGORY_TO_SLOT := {
	17: Slot.HELMET, 6: Slot.BODY, 19: Slot.BELT, 22: Slot.ARMS,
	23: Slot.LEGS, 18: Slot.SHOES, 24: Slot.GAUNTLETS, 21: Slot.SHOULDER,
	5: Slot.MAIN_HAND, 13: Slot.OFF_HAND, 29: Slot.MOUNT,
}

## The slot the record's category equips, or -1 when the category is not
## equipment. This is the resolver's first hop: record -> slot, then
## name_of / texture_of -> model and texture -> scene graph.
func slot_of(record: int) -> int:
	return _CATEGORY_TO_SLOT.get(category_of(record), -1)

## WORN garments displace the base body's own same-part surfaces -- the
## hiding rule granny-grn.md records as implemented nowhere ("the viewer
## does not implement hiding at all, it stacks"). BONE-ATTACHED pieces
## (blades 5, shields 13, mount gear 29) hang off bones and hide nothing.
func is_worn(record: int) -> bool:
	var s := slot_of(record)
	return s >= Slot.HELMET and s <= Slot.SHOULDER

func is_bone_attached(record: int) -> bool:
	var s := slot_of(record)
	return s == Slot.MAIN_HAND or s == Slot.OFF_HAND or s == Slot.MOUNT

## The base-body material-name tokens each worn slot displaces. Names are
## per-class (SERAPHIM's groups are Angel_body/Angel_arms/Angel_head/
## Angel_hair; legs and shoes are unprefixed), so matching is by case-less
## token, never exact string. SHOULDER and BELT displace nothing: the base
## body has no shoulder or belt group to hide.
const SLOT_HIDE_TOKENS := {
	Slot.BODY: ["body"], Slot.LEGS: ["leg"], Slot.SHOES: ["shoe"],
	Slot.ARMS: ["arm"], Slot.HELMET: ["head"], Slot.GAUNTLETS: ["hand"],
}

## Every items.pak record naming `mesh`, in record order. One mesh is named by
## many items precisely because each carries a different skin, so a caller that
## wants "a" kite shield has to pick one and say which.
func records_naming(mesh: String) -> PackedInt32Array:
	var out := PackedInt32Array()
	var want := mesh.to_upper()
	for k in _name:
		if String(_name[k]).to_upper() == want:
			out.append(k)
	out.sort()
	return out

## Prefix census over the `_name` table: for each prefix
## string, count how many stored names begin with it (`named`) and how many
## of those additionally match the caller-supplied regex (`parseable`).
## Returns one Dictionary per prefix {prefix, named, parseable}, in the
## caller's prefix order. This is a READER of the same table the swap uses,
## so its counts are pipeline truth, not a second parse. It carries the
## Counts one entry per items.pak RECORD, so two records sharing a sprite
## id are counted twice -- they are two placements' worth of naming.
func census(prefixes: Array, rx: RegEx) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for p in prefixes:
		var named := 0
		var parseable := 0
		for sid in _name:
			var nm: String = _name[sid]
			if not nm.begins_with(p):
				continue
			named += 1
			if rx.search(nm) != null:
				parseable += 1
		out.append({"prefix": p, "named": named, "parseable": parseable})
	return out

## {named, parseable} over ALL of `_name` under `rx`, so the corpus totals
## can be checked against the row-320 token-frequency census.
func census_totals(rx: RegEx) -> Dictionary:
	var named := 0
	var parseable := 0
	for sid in _name:
		named += 1
		if rx.search(_name[sid]) != null:
			parseable += 1
	return {"named": named, "parseable": parseable}
