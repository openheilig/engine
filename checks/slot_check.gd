extends "res://checks/check.gd"
## slot_check.gd -- the category-to-slot table, gated against the corpus.
##
##   godot --headless --path godot-port --script slot_check.gd
##
## items.gd's Slot table (closed 2026-08-30, findings row with this check)
## maps the +0x2e category byte onto retail's cCreature+0x1A4 slot array.
## Checks attachment contracts, including generated weapon definitions.
## Raw-file census counts and name-token percentages are not runtime
## contracts: inheritance adds valid types sharing their parent's art.



func _init() -> void:
	super()
	var install := Sacred.find_install()
	assert(install != "", "no retail install found; pass --install=/path/to/install")
	var pak := Sacred.Pak.new(install.path_join("pak/items.pak"))
	var items: RefCounted = Sacred.Items.new(pak)


	# Resolver consistency over the corpus: worn exactly for slots
	# HELMET..SHOULDER, bone exactly for the hand/mount trio, never both.
	for r in pak.count():
		var s: int = items.slot_of(r)
		if s < 0:
			continue
		var worn: bool = items.is_worn(r)
		var bone: bool = items.is_bone_attached(r)
		if worn and bone:
			expect(false, "record %d both worn and bone-attached (slot %d)" % [r, s])

	# Known retail records.
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
	expect(items.name_of(7901) == "SWORD_BASTARD.GRN" and
		items.slot_of(7901) == Sacred.Items.Slot.MAIN_HAND,
		"native starting weapon must inherit its model and main-hand attachment")
	for rec in hero.items():
		var s: int = items.slot_of(rec)
		if s == Sacred.Items.Slot.MAIN_HAND:
			print("template blade: record %d -> MAIN_HAND (%s)" % [rec, items.name_of(rec)])
		elif s >= 0:
			print("template item: record %d -> slot %d (%s)" % [rec, s, items.name_of(rec)])
		else:
			print("template prop: record %d (%s)" % [rec, items.name_of(rec)])

	var ok := _failures == 0
	print("slot_check: %s" % ("OK" if ok else "FAILED"))
	finish(0 if ok else 1)
