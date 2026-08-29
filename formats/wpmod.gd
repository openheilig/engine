extends RefCounted
## bin/wpmod.bin -- the item MODIFIER table: what an item grants beyond its
## base stats. Compiled by retail from scripts/waffenmod.txt, which retail does
## not ship. Despite `waffenmod` it is not weapons-only: across the 1508 items
## it names, the mesh families are rings, armour, helms, bows, swords and
## shields (autoresearch rows 923, 927-932).
##
## LAYOUT. u32 count = 572 at +0, then records from int index 1. A record is a
## FIXED part of 54 int32 followed by `fixed[53]` BLOCKS of 6 int32 each, so
##
##     length = 54 + 6 * fixed[53]
##
## and that consumes the file exactly -- 36949 of 36949 int32, 572 records
## ending on the last byte. Nothing else divides it: the block count sits at
## the END of the fixed part, immediately before the blocks it governs, which
## is why a fixed-stride reading over-segments to 591.
##
## The tag -> column map below is NOT fitted. It is read off the compiler that
## writes this file: every tag strstr's the source line and strtol's the result
## into a fixed stack slot, and the record buffer's base appears in the code as
## a lea of the same slot the writer emits, so the origin is pinned
## independently of the map that rests on it.
##
## THE BLOCK IS A TAGGED UNION and this is the one thing to get right: which
## slot carries the magnitude depends on which source section produced it.
##
##   Bonus:  773 blocks  magnitude in RANGE (blk[2]), a min-max pair
##   Spell:  100 blocks  magnitude in blk[4], default 20
##   Skill:  129 blocks  magnitude in blk[5], default 10
##
## Each section leaves the other two at their defaults, and the file agrees to
## within three records: blk[4] differs from 20 in exactly 68 blocks and all 68
## are Spell, blk[5] differs from 10 in exactly 114 and all 114 are Skill, and
## blk[2] is zero in 100/100 Spell and 129/129 Skill blocks. Reading blk[2] as
## the magnitude of a Spell block therefore yields 0 every time, silently.
##
## WHAT IS NOT KNOWN, so callers do not assume it: what any magnitude is
## DENOMINATED in. No tag names a unit and scripts/waffenmod.txt is not
## shipped, so `magnitude` is the number retail stores and nothing more. The
## engine may compare and order them; it may not claim they are percentages.

const Items := preload("res://formats/items.gd")
const Pak := preload("res://formats/pak.gd")

const FIXED := 54          ## int32 in the fixed part
const BLOCK := 6           ## int32 per modifier block
const N_COUNT := 53        ## fixed[53] is the block count

const F_SLOT := 0          ## fixed[0..4] -- five items.pak record ids
const F_LIVE := 5          ## how many of those five are live, 1..5
const F_MOD := 6           ## `mod:`
const F_VAR := 7           ## `var:`
const F_CHAN := 8          ## fixed[8..37] -- ten channels, three values each
const F_TYPE := 38         ## the EWT_ equipment-type enum, -1 = none
const F_MINLEV := 39       ## `MinLev:`
const F_MINRARE := 40      ## `MinRare:`

const B_CHANCE := 0        ## low 16 = percent; bit 31 = RESISTANCE
const B_ID := 1            ## low 16 = id; bits 16..18 = conditioning attribute
const B_RANGE := 2         ## u16 min, u16 max -- the Bonus: magnitude
const B_GROUP := 3         ## 1..11 skill groups, 14..34 class-spell groups
const B_SPELL := 4         ## the Spell: magnitude
const B_SKILL := 5         ## the Skill: magnitude

const RESIST := 1 << 31
const SKILL_BASE := 599    ## a skill id is stored as 599 + skill
const SPELL_MAG_DEFAULT := 20
const SKILL_MAG_DEFAULT := 10

## The ten damage/resistance channels of fixed[8..37], in source order. Each
## takes three comma-separated values, so channel c is fixed[8 + 3*c .. +2].
const CHANNELS: Array[String] = [
	"ph", "fe", "ma", "gi", "rp", "rf", "rm", "rg", "aw", "vw",
]

## fixed[38]'s enum, from the executable's own EWT_ table. Index is the value;
## -1 means the record carries no type. Kept as data rather than a comment
## because a caller printing "shield" is more useful than one printing 7.
const EWT: Array[String] = [
	"Schwert", "Dolch", "Degen", "Saebel", "2HSchwert", "Axt", "2HAxt",
	"Schild", "Bogen", "Armbrust", "Klingenwaffe", "Kettenwaffe", "Peitsche",
	"Ruestung", "Ring", "Amulett", "Helm", "Armschiene", "Beinschiene",
	"Guertel", "Schulter", "Speer", "Keule", "Stab", "Magierstab",
	"Zaumzeug", "Schuhe", "Handschuhe", "Fluegel", "Item", "Pistole",
	"Muskete", "Rucksack",
]

## The six `Bedingung:` attributes, indexed by the selector in bits 16..18 of
## a block's id. 0 means the bonus is unconditioned.
const ATTR: Array[String] = ["", "ST", "GS", "WI", "RP", "RM", "CH"]

var records := 0
var blocks := 0
var found := false

var _fixed: Array[PackedInt32Array] = []      ## one per record
var _blocks: Array[Array] = []                ## record -> Array[PackedInt32Array]
## items.pak record -> indices into _fixed. An item may be named by more than
## one modifier record, so this is a list rather than a single index.
var _by_item: Dictionary[int, PackedInt32Array] = {}


func _init(install: String) -> void:
	var raw := FileAccess.get_file_as_bytes(install.path_join("bin/wpmod.bin"))
	if raw.size() < 4 or raw.size() % 4 != 0:
		push_warning("Wpmod: bin/wpmod.bin missing or not u32-aligned under %s" % install)
		return
	var want := raw.decode_u32(0)
	var p := 4
	for r in want:
		if p + FIXED * 4 > raw.size():
			push_warning("Wpmod: record %d runs past the file" % r)
			return
		var f := PackedInt32Array()
		f.resize(FIXED)
		for i in FIXED:
			f[i] = raw.decode_s32(p + i * 4)
		p += FIXED * 4
		var nb := f[N_COUNT]
		# The block count is the only thing standing between this reader and
		# reading the rest of the file as one record, so it is bounded here
		# rather than trusted: measured 0..5 across all 572.
		if nb < 0 or p + nb * BLOCK * 4 > raw.size():
			push_warning("Wpmod: record %d declares %d blocks it cannot hold" % [r, nb])
			return
		var bs: Array = []
		for b in nb:
			var blk := PackedInt32Array()
			blk.resize(BLOCK)
			for i in BLOCK:
				blk[i] = raw.decode_s32(p + i * 4)
			bs.append(blk)
			p += BLOCK * 4
		var idx := _fixed.size()
		_fixed.append(f)
		_blocks.append(bs)
		blocks += bs.size()
		for k in mini(maxi(f[F_LIVE], 0), 5):
			var rec := f[F_SLOT + k]
			var l: PackedInt32Array = _by_item.get(rec, PackedInt32Array())
			if not l.has(idx):
				l.append(idx)
				_by_item[rec] = l
	# Consuming the file EXACTLY is the whole proof of the length rule. A
	# reader that stops early has simply mis-parsed a block count, and would
	# otherwise report a plausible-looking subset.
	if p != raw.size():
		push_warning("Wpmod: parse left %d trailing bytes -- layout rejected" % (raw.size() - p))
		return
	records = _fixed.size()
	found = records == want and records > 0


## Every modifier record naming this items.pak record, in file order.
func records_for_item(item_record: int) -> PackedInt32Array:
	return _by_item.get(item_record, PackedInt32Array())


## The `EWT_` equipment type of a modifier record as a name, or "" when the
## record carries none (-1) or the index is out of range.
func type_name(record: int) -> String:
	var t := field(record, F_TYPE)
	return EWT[t] if t >= 0 and t < EWT.size() else ""


## One field of the fixed part; 0 for an out-of-range record so a caller that
## loops does not have to bounds-check every read.
func field(record: int, index: int) -> int:
	if record < 0 or record >= _fixed.size() or index < 0 or index >= FIXED:
		return 0
	return _fixed[record][index]


## The three values of one of the ten damage/resistance channels.
func channel(record: int, chan: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	if chan < 0 or chan >= CHANNELS.size():
		return out
	for i in 3:
		out.append(field(record, F_CHAN + chan * 3 + i))
	return out


## The decoded modifier blocks of one record.
##
## Each is a Dictionary the caller can read without knowing the union rule:
##   kind       "bonus" | "skill" | "spell" | "bare"
##   id         the raw low-16 id
##   skill      skill id when kind is "skill", else -1
##   chance     percent, 10..100
##   resist     true when this is the resistance side of a damage channel
##   attr       "" or one of ST/GS/WI/RP/RM/CH -- the attribute it is conditioned on
##   group      the group id, 0 when none
##   magnitude  the section's own magnitude slot, already resolved
##   spread     [min, max] for a Bonus block, [magnitude, magnitude] otherwise
func modifiers(record: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if record < 0 or record >= _blocks.size():
		return out
	for blk: PackedInt32Array in _blocks[record]:
		var raw_id := blk[B_ID]
		var id := raw_id & 0xffff
		var group := blk[B_GROUP]
		var lo := blk[B_RANGE] & 0xffff
		var hi := (blk[B_RANGE] >> 16) & 0xffff
		var kind := "bare"
		var skill := -1
		var magnitude := 0
		var spread := PackedInt32Array([0, 0])
		if group >= 14 and group <= 34:
			kind = "spell"
			magnitude = blk[B_SPELL]
			spread = PackedInt32Array([magnitude, magnitude])
		elif (group >= 1 and group <= 11) or (id >= SKILL_BASE and id <= SKILL_BASE + 33):
			kind = "skill"
			if id >= SKILL_BASE:
				skill = id - SKILL_BASE
			magnitude = blk[B_SKILL]
			spread = PackedInt32Array([magnitude, magnitude])
		elif id >= 801 and id <= 820:
			kind = "bonus"
			magnitude = hi
			spread = PackedInt32Array([lo, hi])
		var sel := (raw_id >> 16) & 0x7
		out.append({
			"kind": kind,
			"id": id,
			"skill": skill,
			"chance": blk[B_CHANCE] & 0xffff,
			"resist": (blk[B_CHANCE] & RESIST) != 0,
			"attr": ATTR[sel] if sel < ATTR.size() else "",
			"group": group,
			"magnitude": magnitude,
			"spread": spread,
		})
	return out


## The UNDECODED 6-int blocks of a record. modifiers() is what production
## callers want -- it resolves the union so they cannot read the wrong slot --
## but the gate has to see the raw slots to assert that the union rule holds,
## which it cannot do through a view that has already applied it.
func raw_blocks(record: int) -> Array:
	if record < 0 or record >= _blocks.size():
		return []
	return _blocks[record]


## items.pak record ids named by any modifier record, deduplicated. Handy for
## a caller that wants to know whether wpmod has anything to say at all.
func item_records() -> PackedInt32Array:
	var out := PackedInt32Array()
	for k in _by_item:
		out.append(k)
	out.sort()
	return out

## Apply every modifier record naming `item` to `stats`, ADDITIVELY, returning
## the updated dict. `stats` is the caller's starting aggregate -- an empty
## dictionary on a fresh item -- and is NOT mutated; a fresh dictionary is
## always returned, so the same caller can pass the same `stats` to several
## items in turn.
##
## KEYS, mapped from modifier fields -- additive ints, deliberately NOT named
## as percentages: row 1166 confirms no tag names a unit, so the values are
## the raw ints wpmod stores and nothing more. A consumer that knows its own
## unit multiplies by it; a consumer that doesn't keeps the ints and shows
## the relative sizes across items.
##
##   channels     one int per (channel, slot) pair:
##                "chan_<name>_0" / "_1" / "_2" for each of the 10 channels
##                in CHANNELS order. Three values per channel is fixed[8..37],
##                each (channel, slot) accumulated across every modifier
##                record that names the item. Slot 0 is the first int of the
##                triple, slot 2 the third -- the +0x08..+0x27 triple is
##                retail's three-value column per channel.
##   bonus        "bonus_<id>" for a Bonus: block (id 801..820), magnitude
##                being the hi half of blk[2] -- the upper bound of [lo,hi].
##   skill        "skill_<skill>" for a Skill: block (skill id 0..33 via the
##                +599 offset), magnitude being blk[5].
##   spell        "spell_<group>" for a Spell: block (group 14..34), magnitude
##                being blk[4].
##   bare         left out: a bare block carries no magnitude of its own.
##
## `creature_id` is unused -- every modifier applies to its item regardless of
## who is carrying it, and no field discriminates by wearer. It is kept in
## the signature for symmetry with dress_creature().
func apply_to_item(item: int, stats: Dictionary, creature_id: int = 0) -> Dictionary:
	var out: Dictionary = {}
	for k in stats:
		out[k] = stats[k]
	var recs := records_for_item(item)
	for rec in recs:
		for c in CHANNELS.size():
			var ch := channel(rec, c)
			for v in 3:
				var key := "chan_%s_%d" % [CHANNELS[c], v]
				out[key] = int(out.get(key, 0)) + ch[v]
		for m: Dictionary in modifiers(rec):
			var kind: String = m["kind"]
			if kind == "bonus":
				var k := "bonus_%d" % int(m["id"])
				out[k] = int(out.get(k, 0)) + int(m["magnitude"])
			elif kind == "skill" and int(m["skill"]) >= 0:
				var k := "skill_%d" % int(m["skill"])
				out[k] = int(out.get(k, 0)) + int(m["magnitude"])
			elif kind == "spell":
				var k := "spell_%d" % int(m["group"])
				out[k] = int(out.get(k, 0)) + int(m["magnitude"])
	return out
