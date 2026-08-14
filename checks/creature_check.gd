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

	print("creature_check\tOK\tcount=%d\theroes=9/9\tnamed=%d\tgrn=%d" % [n, named, grn])
	finish(0)
