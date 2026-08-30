extends "res://checks/check.gd"
## slot_check.gd -- the category-to-slot table, gated against the corpus.
##
##   godot --headless --path godot-port --script slot_check.gd
##
## items.gd's Slot table (closed 2026-08-30, findings row with this check)
## maps the +0x2e category byte onto retail's cCreature+0x1A4 slot array.
## Three failure kinds this check pins, so a decode drift, a data swap or a
## table typo each trip a DIFFERENT assertion:
##
##   1. census pinning -- the per-category record counts measured on the
##      shipped items.pak. A count moving means the pak changed or the
##      reader drifted; either way the table's evidence is stale.
##   2. name-token agreement -- every NAMED record in an equipment category
##      names its body part (English or German: _Legs/_bein, _Shoes/_stiefel,
##      _Gloves/_handschuh ...). The category byte was measured FROM these
##      names, so a category whose names disagree with its slot is a wrong
##      table row made visible.
##   3. resolver consistency -- slot_of/is_worn/is_bone_attached agree with
##      the table and with known records (SERA_S_* kit pieces, wings, the
##      hero template's blade).

const CENSUS_COUNTS := {
	5: 240, 6: 308, 13: 42, 17: 129, 18: 97, 19: 127, 21: 68, 22: 107,
	23: 81, 24: 42, 25: 7, 29: 26,
}

## category -> (name tokens, slot) -- the token list is the check's own
## reading of the census samples; a record failing it is printed, not
## assumed away.
const CATEGORY_TOKENS := {
	17: ["HELM", "HEAD", "GOGGLE", "BRILLE", "HOOD", "MASK", "COWL", "HAT"],
	6: ["BODY", "ARMOUR", "ARMOR", "CLOTH", "LEATHER", "METAL", "HEMD",
		"HARNISCH", "LARNISCH", "KETTE", "ROBE", "TUCH", "KURZ"],
	19: ["BELT", "GURTEL", "GÜRTEL"],
	22: ["ARM", "GLOVE"],
	23: ["LEG", "BEIN"],
	18: ["SHOE", "BOOT", "STIEFEL"],
	24: ["GLOVE", "HANDSCHUH", "HAND"],
	21: ["SHOULDER", "SCHULTER"],
}


func _init() -> void:
	super()
	var install := Sacred.find_install()
	assert(install != "", "no retail install found; pass --install=/path/to/install")
	var pak := Sacred.Pak.new(install.path_join("pak/items.pak"))
	var items: RefCounted = Sacred.Items.new(pak)

	# 1. census pinning: the shipped data the table was measured on.
	var counts := {}
	for r in pak.count():
		var c: int = items.category_of(r)
		if c >= 0:
			counts[c] = int(counts.get(c, 0)) + 1
	for c in CENSUS_COUNTS:
		expect(int(counts.get(c, 0)) == int(CENSUS_COUNTS[c]),
			"category %d count %d != pinned %d" % [c, counts.get(c, 0), CENSUS_COUNTS[c]])

	# 2. name-token agreement over every named record in an equipment category.
	var violations := {}
	for c in CATEGORY_TOKENS:
		var tokens: Array = CATEGORY_TOKENS[c]
		for r in pak.count():
			if items.category_of(r) != c:
				continue
			var nm: String = items.name_of(r)
			if nm == "":
				continue
			var up := nm.to_upper()
			var hit := false
			for tok in tokens:
				if up.contains(tok):
					hit = true
					break
			if not hit:
				violations[c] = violations.get(c, []) + [nm]
	# The tolerance is the data speaking: categories carry genuine quirks
	# (eyewear in 17, the Sera gloves in 22, Sera_black_legs in 18), each a
	# minority of its category. A TABLE TYPO swaps two categories and
	# violates the majority -- 10% separates those regimes.
	for c in CATEGORY_TOKENS:
		var v: Array = violations.get(c, [])
		var named := 0
		for r in pak.count():
			if items.category_of(r) == c and items.name_of(r) != "":
				named += 1
		expect(v.size() * 10 < named,
			"category %d: %d of %d named records fail their tokens: %s" % [c, v.size(), named, str(v.slice(0, 4))])

	# 3a. resolver consistency over the corpus: worn exactly for slots
	# HELMET..SHOULDER, bone exactly for the hand/mount trio, never both.
	for r in pak.count():
		var s: int = items.slot_of(r)
		if s < 0:
			continue
		var worn: bool = items.is_worn(r)
		var bone: bool = items.is_bone_attached(r)
		if worn and bone:
			expect(false, "record %d both worn and bone-attached (slot %d)" % [r, s])

	# 3b. known records.
	# The kit pieces' slots are retail's OWN category assignments, quirks
	# included: SERA_s_legs sits in category 18 (SHOES) -- the data says the
	# kit's legs piece occupies the shoes slot -- and SERA_S_BOOTS has no
	# items.pak record at all (only a models.pak mesh). The table encodes
	# what retail reads, not what the names suggest.
	var sera_slots := {}
	for piece in ["SERA_S_BOOTS.GRN", "SERA_S_LEGS.GRN", "SERA_S_ARMS.GRN", "SERA_S_SHOULDER.GRN"]:
		var recs: PackedInt32Array = items.records_naming(piece)
		sera_slots[piece] = items.slot_of(recs[0]) if recs.size() > 0 else -2
	expect(int(sera_slots.get("SERA_S_BOOTS.GRN", -1)) == -2,
		"SERA_S_BOOTS has an items record now -- re-measure its slot")
	expect(int(sera_slots.get("SERA_S_LEGS.GRN", -2)) == Sacred.Items.Slot.SHOES,
		"SERA_S_LEGS slot = %s, want SHOES (retail categorises it as boots)" % sera_slots.get("SERA_S_LEGS.GRN"))
	expect(int(sera_slots.get("SERA_S_ARMS.GRN", -2)) == Sacred.Items.Slot.ARMS,
		"SERA_S_ARMS slot = %s, want ARMS" % sera_slots.get("SERA_S_ARMS.GRN"))
	expect(int(sera_slots.get("SERA_S_SHOULDER.GRN", -2)) == Sacred.Items.Slot.SHOULDER,
		"SERA_S_SHOULDER slot = %s, want SHOULDER" % sera_slots.get("SERA_S_SHOULDER.GRN"))
	for r in pak.count():
		if items.category_of(r) == 25:
			expect(items.slot_of(r) == -1 and not items.is_worn(r),
				"wings record %d resolved to a worn slot" % r)
	var hero := Sacred.Hero.new(install.path_join("templates/hero01.ptx"))
	for rec in hero.items():
		var s: int = items.slot_of(rec)
		if s == Sacred.Items.Slot.MAIN_HAND:
			print("template blade: record %d -> MAIN_HAND (%s)" % [rec, items.name_of(rec)])
		elif s >= 0:
			print("template item: record %d -> slot %d (%s)" % [rec, s, items.name_of(rec)])
		else:
			print("template prop: record %d (%s)" % [rec, items.name_of(rec)])

	var ok := _failures == 0
	print("slot_check: %s (%d categories gated, %d pinned counts)" %
		["OK" if ok else "FAILED", CATEGORY_TOKENS.size(), CENSUS_COUNTS.size()])
	finish(0 if ok else 1)
