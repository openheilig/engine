extends RefCounted
## pak/items.pak -- the object DEFINITION table, and the only place retail keeps
## the German authoring names ("DCTower innenunten 1A_1", "TH01 Wand innen 1_02").
##
##   "ITM" v5, 32768 uniform 128-byte records.
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
## The set is identified by NAME, which is why the whole items.pak chain matters:
##   static.pak type --indexes--> mixed.pak sprite   (209956/209956 verified)
##   items.pak +0x10 ------------> mixed.pak sprite
##   items.pak +0x37 ------------> authoring name
## so inverting +0x10 -> +0x37 gives sprite id -> name.
##
## Do NOT use the items.pak index as a mixed.pak index. That reading gives 70.2%
## art for the innen entries against a 77.6% baseline (worse than chance) and
## resolves every DCTower innen* entry to a zero-tile sprite. Reading the id from
## +0x10 instead hits 100.0% for innen against 82.0% overall.

const Pak := preload("res://formats/pak.gd")

const SPRITE_OFF := 0x10
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

func _init(pak: Pak) -> void:
	# Level-AND form (_0U1_) or single-level form (_1_), then a part number
	# that may carry a letter suffix (_00A) or a part-range (_11U21). The
	# part token is `\d+[A-Za-z]?(?:U\d+)?` -- the optional trailing letter
	# and optional U-range belong to the PART, never to the level.
	var lv := RegEx.create_from_string("_(\\d)(?:U(\\d))?_(\\d+[A-Za-z]?(?:U\\d+)?)$")
	for i in pak.count():
		var r := pak.blob(i)
		if r.size() < REC_MIN:
			continue
		_sprite[i] = r.decode_u32(SPRITE_OFF)
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

## The mixed.pak sprite id a static's type field resolves to, or 0 (no art)
## when the record is absent or carries no sprite. 0 is the honest answer,
## not a fallback to the record index: Mixed.sprite(0) is empty, which is
## exactly what an invisible marker placement should draw.
func sprite_of(record: int) -> int:
	return _sprite.get(record, 0)

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
