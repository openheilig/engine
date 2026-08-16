extends "res://checks/check.gd"
## creature_check.gd -- the ONE runnable check for pak/creature.pak.
##
##   godot --headless --path godot-port --script creature_check.gd
##
## creature.pak is a FLAT CIF table, NOT a generic Pak container: its magic is
## in Sacred.Pak.ALLOWED_MAGIC but the bytes at 0x100 are header, not an index,
## so reading it through Sacred.Pak silently misreads it. 474 records of 86
## bytes from offset 256; 256 + 474*86 == 41020 == the file length, which is
## what fixes the stride.
##
## THE FINDING THIS CHECK EXISTS TO PROTECT: a creature's id IS an items.pak
## RECORD INDEX, and that record names the creature's Granny model. So a
## creature's appearance needs no field at all -- it is the id. Established by
## two independent agreements: the period German table's hardcoded ids 1..9 are
## the nine playable heroes in a fixed order, items.pak records 1..9 name the
## nine hero .grn models in that same order, and all nine carry class 1 (Held).
##
## Field table (from Creature.pak.txt, SacredModdingStuff1.zip, ~70% decoded --
## its 60 described bytes of 86 match that claim exactly):
##   +0x00 u32 id   +0x04 u16 class   +0x06 u8 flags   +0x07 u8 ?
##   +0x08 u16 xpA  +0x0a u16 xpB     (exp = A + level*B)
##   +0x0c..0x11 six base attributes  +0x12 u16 always 0
##   +0x14..0x25 eighteen skill bytes +0x26 u16 walk   +0x28 u16 run
##   +0x2a..0x35 six (bonus level, bonus type)   +0x36..0x3b six bonus values
##   +0x3c..0x55 undescribed -- measured near-constant (1..11 distinct values
##   per byte over all 474 records), so no model or equipment index lives there.
## Class enum: 1 Held, 2 Monster, 3 NPC, 4 Pferd, 5 Untoter, 6 Tier, 7 Soeldner,
## 8 Goblinoide, 9 Daemon, 10 Drache, 11 Energiewesen, 12 Elf, 13 Feind (unused
## in retail), 14 Mensch, 15 Dryade.
const DATA := 256
const REC := 86
const COUNT := 474
## SPEED a <= SPEED b in all but two records. Measured, not assumed round.
const SPEED_ORDERED := 472
## Creature records naming GHUL.GRN. More than one, deliberately pinned.
const GHOUL_VARIANTS := 2
const HERO_NAMES := ["", "SERAPHIM.GRN", "GLADIATOR.GRN", "MAGICIAN.GRN", "DARKELVE.GRN",
	"ELVE_SORCERESS.GRN", "VLADY_D.GRN", "VLADY_N.GRN", "dwarf.grn", "Daemonia.grn"]

func _init() -> void:
	super()
	var install := Sacred.find_install()
	var b := FileAccess.get_file_as_bytes(install.path_join("pak/creature.pak"))
	assert(b.size() > DATA, "pak/creature.pak is missing or short")
	assert(b.slice(0, 3).get_string_from_ascii() == "CIF", "creature.pak magic is not CIF")
	var n := b.decode_u32(4)
	assert(n == COUNT, "creature count moved: want %d, got %d" % [COUNT, n])
	assert(DATA + n * REC == b.size(),
		"stride broken: 256 + %d*%d = %d but the file is %d bytes" % [n, REC, DATA + n * REC, b.size()])

	var items := Sacred.Items.new(Sacred.Pak.new(install.path_join("pak/items.pak")))
	var by_id: Dictionary = {}
	for i in n:
		by_id[b.decode_u32(DATA + i * REC)] = i
	assert(by_id.size() == n, "creature ids are no longer distinct (%d ids for %d records)" % [by_id.size(), n])

	# The nine heroes: id N must be items record N, must name that hero's .grn,
	# and must carry class 1. Nine independent agreements fix the id space.
	for id in range(1, 10):
		assert(by_id.has(id), "creature id %d is missing" % id)
		assert(items.name_of(id) == HERO_NAMES[id],
			"items record %d should name %s, got '%s'" % [id, HERO_NAMES[id], items.name_of(id)])
		var cls := b.decode_u16(DATA + int(by_id[id]) * REC + 4)
		assert(cls == 1, "hero creature %d should be class 1 (Held), got %d" % [id, cls])

	# The id-as-items-record rule generalises: every creature but one names an
	# items record, and every one of those names a Granny model.
	var named := 0
	var grn := 0
	for i in n:
		var o := DATA + i * REC
		var nm := items.name_of(b.decode_u32(o))
		if nm != "":
			named += 1
			if nm.to_lower().ends_with(".grn"):
				grn += 1
		var cls := b.decode_u16(o + 4)
		assert(cls <= 15, "class %d is outside the documented 0..15 enum" % cls)
	assert(named == n - 1, "creature ids naming an items record moved: want %d, got %d" % [n - 1, named])
	assert(grn == named, "every named creature must name a .grn, got %d of %d" % [grn, named])

	var facts := _fields(install)

	print("creature_check\tOK\tcount=%d\theroes=9/9\tnamed=%d\tgrn=%d\t%s" % [
		n, named, grn, facts])
	finish(0)


## THE FIELD MAP, now transcribed from retail's own creature.txt WRITER
## (sub_8150646) rather than taken from the third-party table above. Every
## assertion here is on Sacred.Creatures' public output.
##
## THE STRUCTURAL PROOF IS THE FLAGS BYTE. The writer names six bits --
## FLY, BIG, NOSHADOW, GHOST, BANANE, KURVE -- and across all 474 records ZERO
## bits are set outside those six. A wrong offset does not produce that; it
## produces garbage bits. Everything else below is a range check, which can
## only corroborate.
func _fields(install: String) -> String:
	var c = Sacred.Creatures.new(install.path_join("pak"))
	assert(c.count() == COUNT, "reader count moved: want %d, got %d" % [COUNT, c.count()])

	var stray := 0
	var flagged := 0
	for id in c.ids():
		var f: int = c.flags_of(id)
		if f != 0:
			flagged += 1
		if (f & ~Sacred.Creatures.FLAG_KNOWN) != 0:
			stray += 1
	assert(stray == 0,
		"%d records set a FLAGS bit the writer does not name -- the offset is wrong" % stray)
	assert(flagged > 0 and flagged < COUNT,
		"FLAGS is %d of %d records, which is not a flag byte" % [flagged, COUNT])

	# BASE attributes: every record carries STK, RES and GES, and none exceeds
	# a plausible attribute. A byte offset that had slipped would show zeros or
	# values in the hundreds.
	for k in [Sacred.Creatures.B_STK, Sacred.Creatures.B_RES, Sacred.Creatures.B_GES]:
		var zero := 0
		var hi := 0
		for id in c.ids():
			var v: int = c.base(id, k)
			if v == 0:
				zero += 1
			hi = maxi(hi, v)
		assert(zero == 0, "%d records have no %s" % [zero, Sacred.Creatures.BASE_NAMES[k]])
		assert(hi <= 100, "%s reaches %d, which is not an attribute" % [Sacred.Creatures.BASE_NAMES[k], hi])

	# SPEED is an ORDERED pair of round numbers in all but two records. Pinned
	# because it is the field an outside table calls walk and run, and a wrong
	# offset would not be ordered.
	var ordered := 0
	for id in c.ids():
		var sp: Vector2i = c.speed(id)
		if sp.x <= sp.y:
			ordered += 1
	assert(ordered == SPEED_ORDERED,
		"SPEED ordering moved: want %d of %d, got %d" % [SPEED_ORDERED, COUNT, ordered])

	# EXP is retail's own `A + level*B`, so it must GROW with level and equal A
	# at level 0. Checked on a creature that declares both terms.
	var probe := -1
	for id in c.ids():
		var e: Vector2i = c.exp_pair(id)
		if e.x > 0 and e.y > 0:
			probe = id
			break
	assert(probe >= 0, "no creature declares both experience terms")
	var pair: Vector2i = c.exp_pair(probe)
	assert(c.experience(probe, 0) == pair.x, "exp at level 0 is not A")
	assert(c.experience(probe, 10) == pair.x + 10 * pair.y, "exp does not follow A + level*B")

	# The Damping blocks are SPARSE, which is what says they are a real field
	# and not a misread of a dense one: 11 to 13 records carry each.
	var damped := 0
	for w in Sacred.Creatures.DAMP_NAMES.size():
		var used := 0
		for id in c.ids():
			var d: PackedInt32Array = c.damping(id, w)
			var sum := 0
			for v in d:
				sum += v
			if sum > 0:
				used += 1
		assert(used >= 8 and used <= 20,
			"%s damping is on %d records, expected the sparse 8..20" % [Sacred.Creatures.DAMP_NAMES[w], used])
		damped += used

	# A MESH NAME IS NOT A KEY, and this is where that gets pinned. Two
	# creature records name GHUL.GRN -- ids 36 and 50 -- with DIFFERENT stats
	# (base 35,35,25,40,0,50 against 33,34,24,43,0,50; speed 50,50 against
	# 80,80). A caller that looks a creature up by its mesh silently gets
	# whichever record it met first, which is why Sacred.Creatures is addressed
	# by id and why Encounter reads the id startcode actually placed.
	var items2 := Sacred.Items.new(Sacred.Pak.new(install.path_join("pak/items.pak")))
	var ghouls := PackedInt32Array()
	for id in c.ids():
		if items2.name_of(id).to_upper() == "GHUL.GRN":
			ghouls.append(id)
	assert(ghouls.size() == GHOUL_VARIANTS,
		"GHUL.GRN is named by %d creature records, expected %d" % [ghouls.size(), GHOUL_VARIANTS])
	var ghoul: int = ghouls[0]
	assert(c.base_all(ghouls[0]) != c.base_all(ghouls[1]),
		"the two Ghoul records now have identical attributes -- the variant distinction is gone")
	assert(c.class_of(ghoul) == 5, "the Ghoul is class %d, expected 5 (Untoter)" % c.class_of(ghoul))
	var gb: PackedInt32Array = c.base_all(ghoul)
	assert(gb[Sacred.Creatures.B_STK] > 0 and gb[Sacred.Creatures.B_GES] > 0,
		"the Ghoul has no attributes")
	return "flags_clean=%d/%d\tspeed_ordered=%d\tdamping_rows=%d\tghoul_base=%s" % [
		COUNT - stray, COUNT, ordered, damped, gb]
