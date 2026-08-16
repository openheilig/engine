extends "res://checks/check.gd"
## wpmod_check.gd -- the ONE runnable check for Sacred.Wpmod, the bin/wpmod.bin
## item-modifier table (autoresearch rows 923, 927-932).
##
##   godot --headless --path godot-port --script checks/wpmod_check.gd
##
## WHAT THIS PROTECTS. wpmod.bin has no magic number, no version field and no
## fixed stride: the only thing that says the layout is right is that
## `54 + 6*fixed[53]` per record consumes the file EXACTLY. Sacred.Wpmod
## refuses to report found unless it does, so the first assertion is the whole
## decode -- and a wrong block count would eat the next record's fixed part and
## still produce a plausible-looking table.
##
## THE UNION IS THE PART THAT ROTS SILENTLY. Which slot holds a block's
## magnitude depends on the source section that wrote it, and reading the wrong
## slot does not crash -- it returns 0, or a default, forever. So the three
## invariants below are asserted per block rather than in aggregate:
##
##   a Spell block has blk[2] == 0 and blk[5] at its default
##   a Skill block has blk[2] == 0 and blk[4] at its default
##   a Bonus block has blk[4] and blk[5] both at their defaults
##
## If a future edit swaps two slots, every count here still matches and only
## these fail.
##
## The named spot checks are deliberately recognisable, because an aggregate
## cannot tell a human the skill table was transposed: SKILL_Fernkampf (ranged
## combat) must land on the pistols and the musket, and SKILL_Parade (parry) on
## the shields. Those come out of the +599 offset, so they also pin it.
const WANT_RECORDS := 572
const WANT_BLOCKS := 1010
const WANT_ITEMS := 1508           ## distinct items.pak records named
const WANT_RESIST := 151           ## blocks flagged as the resistance side
const WANT_SPELL_MAG := 68         ## blocks overriding the Spell: default 20
const WANT_SKILL_MAG := 114        ## blocks overriding the Skill: default 10
const WANT_ZERO_BLOCK := 3         ## records granting nothing at all

const SKILL_FERNKAMPF := 7
const SKILL_PARADE := 9


func _init() -> void:
	super()
	var install := Sacred.find_install()
	assert(install != "", "no retail install found; pass --install=/path/to/install")
	var w := Sacred.Wpmod.new(install)
	assert(w.found, "bin/wpmod.bin did not decode -- the length rule was rejected")
	assert(w.records == WANT_RECORDS,
		"record count moved: want %d, got %d" % [WANT_RECORDS, w.records])
	assert(w.blocks == WANT_BLOCKS,
		"block count moved: want %d, got %d" % [WANT_BLOCKS, w.blocks])

	var items := Sacred.Items.new(Sacred.Pak.new(install.path_join("pak/items.pak")))
	var named := w.item_records()
	assert(named.size() == WANT_ITEMS,
		"distinct modified items moved: want %d, got %d" % [WANT_ITEMS, named.size()])

	# Every item this table names must BE an item that names a mesh. This is
	# the range check that says fixed[0..4] really are items.pak record ids and
	# not something that merely fits in 32 bits.
	var not_grn := 0
	for rec in named:
		if not items.name_of(rec).to_upper().ends_with(".GRN"):
			not_grn += 1
	assert(not_grn == 0,
		"%d of %d modified items do not name a .GRN -- fixed[0..4] is not an items.pak id"
			% [not_grn, named.size()])

	_union(w)
	_spot(w, items)
	_ranges(w)

	print("wpmod_check OK records=%d blocks=%d items=%d resist=%d spell_mag=%d skill_mag=%d"
		% [w.records, w.blocks, named.size(), WANT_RESIST, WANT_SPELL_MAG, WANT_SKILL_MAG])
	finish(0)


## The tagged union, asserted per block. See the header: this is the invariant
## that a slot swap breaks and nothing else does.
func _union(w) -> void:
	var resist := 0
	var spell_mag := 0
	var skill_mag := 0
	var bad_range := 0
	for r in w.records:
		for m: Dictionary in w.modifiers(r):
			var spread: PackedInt32Array = m["spread"]
			if spread[0] > spread[1]:
				bad_range += 1
			if m["resist"]:
				resist += 1
				# Only the eight channels that come in damage/resistance pairs
				# ever carry the bit; anything else means bit 31 is being read
				# off the wrong field.
				expect(m["id"] >= 801 and m["id"] <= 808,
					"record %d: resistance flag on id %d, which is not a paired channel"
						% [r, m["id"]])
		for blk: PackedInt32Array in w.raw_blocks(r):
			var group := blk[Sacred.Wpmod.B_GROUP]
			var id := blk[Sacred.Wpmod.B_ID] & 0xffff
			var rng := blk[Sacred.Wpmod.B_RANGE]
			var sp := blk[Sacred.Wpmod.B_SPELL]
			var sk := blk[Sacred.Wpmod.B_SKILL]
			if group >= 14 and group <= 34:
				expect(rng == 0, "record %d: a Spell block carries a blk[2] range" % r)
				expect(sk == Sacred.Wpmod.SKILL_MAG_DEFAULT,
					"record %d: a Spell block overrides the Skill magnitude" % r)
				if sp != Sacred.Wpmod.SPELL_MAG_DEFAULT:
					spell_mag += 1
			elif (group >= 1 and group <= 11) or (id >= 599 and id <= 632):
				expect(rng == 0, "record %d: a Skill block carries a blk[2] range" % r)
				expect(sp == Sacred.Wpmod.SPELL_MAG_DEFAULT,
					"record %d: a Skill block overrides the Spell magnitude" % r)
				if sk != Sacred.Wpmod.SKILL_MAG_DEFAULT:
					skill_mag += 1
			elif id >= 801 and id <= 820:
				expect(sp == Sacred.Wpmod.SPELL_MAG_DEFAULT and sk == Sacred.Wpmod.SKILL_MAG_DEFAULT,
					"record %d: a Bonus block overrides a magnitude that is not its own" % r)
	expect(bad_range == 0,
		"%d blocks have min > max -- blk[2] is not being read as a range" % bad_range)
	expect(resist == WANT_RESIST,
		"resistance blocks moved: want %d, got %d" % [WANT_RESIST, resist])
	expect(spell_mag == WANT_SPELL_MAG,
		"Spell magnitude overrides moved: want %d, got %d" % [WANT_SPELL_MAG, spell_mag])
	expect(skill_mag == WANT_SKILL_MAG,
		"Skill magnitude overrides moved: want %d, got %d" % [WANT_SKILL_MAG, skill_mag])


## The +599 skill offset, checked where a human can see it is right.
func _spot(w, items) -> void:
	var by_skill: Dictionary[int, PackedStringArray] = {}
	var empty := PackedStringArray()
	for r in w.records:
		for m: Dictionary in w.modifiers(r):
			if int(m["skill"]) < 0:
				continue
			var s := int(m["skill"])
			var l: PackedStringArray = by_skill.get(s, empty.duplicate())
			l.append(items.name_of(w.field(r, Sacred.Wpmod.F_SLOT)).to_upper())
			by_skill[s] = l
	# Ranged combat belongs to the guns and bows; parry belongs to the shields.
	# If the offset were 598 or 600 these land on unrelated gear and say so
	# loudly. BOW is in the list because it belongs there, not to make the
	# assertion pass: the first run of this check omitted it and the three
	# BOW_LONG entries it flagged were the check being wrong about what counts
	# as a ranged weapon, which is exactly the failure mode a spot check is for.
	_family(by_skill, SKILL_FERNKAMPF, ["PISTOL", "MUSKET", "BOW"], "Fernkampf")
	_family(by_skill, SKILL_PARADE, ["SHIELD"], "Parade")


func _family(by_skill: Dictionary, skill: int, want: Array, label: String) -> void:
	var got: PackedStringArray = by_skill.get(skill, PackedStringArray())
	if not expect(got.size() > 0, "skill %d (%s) modifies nothing" % [skill, label]):
		return
	var hits := 0
	for name in got:
		for w in want:
			if name.contains(w):
				hits += 1
				break
	expect(hits == got.size(),
		"skill %d (%s) should modify only %s, but %d of %d do not: %s"
			% [skill, label, str(want), got.size() - hits, got.size(), got])


## The fixed part's own ranges, which pin the EWT enum and MinLev against a
## record buffer that has slipped by a field.
func _ranges(w) -> void:
	var zero_block := 0
	var lo_type := 99
	var hi_type := -99
	var hi_lev := -1
	for r in w.records:
		if w.modifiers(r).is_empty():
			zero_block += 1
		var t: int = w.field(r, Sacred.Wpmod.F_TYPE)
		var lev: int = w.field(r, Sacred.Wpmod.F_MINLEV)
		lo_type = mini(lo_type, t)
		hi_type = maxi(hi_type, t)
		hi_lev = maxi(hi_lev, lev)
	expect(lo_type == -1 and hi_type == 32,
		"EWT range moved: want -1..32, got %d..%d" % [lo_type, hi_type])
	expect(hi_lev == 90, "MinLev ceiling moved: want 90, got %d" % hi_lev)
	# Three cosmetics grant nothing, which is what a zero block count should
	# mean and is independent confirmation of the length rule.
	expect(zero_block == WANT_ZERO_BLOCK,
		"records granting nothing moved: want %d, got %d" % [WANT_ZERO_BLOCK, zero_block])
