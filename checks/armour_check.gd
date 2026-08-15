extends "res://checks/check.gd"
## armour_check.gd -- the ONE runnable check for Sacred.Armour, the bin/rust.bin
## armour switch (autoresearch rows 743/744).
##
##   godot --headless --path godot-port --script armour_check.gd
##
## WHAT THIS PROTECTS. rust.bin has no magic number and no version field: the
## ONLY thing that says the layout is right is that it consumes the file
## exactly AND that both sides of all 506 pairs name a mesh. Sacred.Armour
## refuses to report found unless both hold, so the first assertion below is
## the whole decode. The rest pins the three properties that make the mesh a
## usable KEY -- because if a future edit turns this into an index lookup, or
## starts matching by wearer alone, these are what stop agreeing.
##
## The named spot checks are deliberately recognisable: a Magician wearing
## Gladiator boots must get magician_boots, and a Vampiress wearing the
## Gladiator's moon amulet must get the Vampiress moon amulet. An aggregate
## count would not tell a human that the table had been silently transposed.
const WANT_GROUPS := 85
const WANT_PAIRS := 506
const WANT_AMB_RECORDS := 3        ## meshes in >1 group, keyed by items.pak RECORD
const WANT_AMB_NAMES := 109        ## ...and by FILENAME, which is not the same key
const WANT_NAMES := 284            ## distinct filenames behind 503 records
const WANT_DUP_WEARER := 8         ## groups listing one wearer twice


func _init() -> void:
	super()
	var install := Sacred.find_install()
	assert(install != "", "no retail install found; pass --install=/path/to/install")
	var a := Sacred.Armour.new(install)
	assert(a.found, "bin/rust.bin did not decode -- the layout was rejected")
	assert(a.groups == WANT_GROUPS, "group count moved: want %d, got %d" % [WANT_GROUPS, a.groups])
	assert(a.pairs == WANT_PAIRS, "pair count moved: want %d, got %d" % [WANT_PAIRS, a.pairs])
	# THE TWO KEYINGS, and why both are pinned. By items.pak RECORD the mesh is
	# an almost-perfect key (3 ambiguous). By FILENAME it is not: 503 records
	# spell only 284 distinct .GRN names, so ~219 records are the SAME file
	# registered again as a different armour, and 109 names span several groups.
	# A caller holding a models.pak entry has only the name, which is why
	# variants_for() is documented as best-effort and is_ambiguous() exists.
	assert(a.ambiguous_records == WANT_AMB_RECORDS,
		"record-ambiguous meshes moved: want %d, got %d" % [WANT_AMB_RECORDS, a.ambiguous_records])
	assert(a.ambiguous_names == WANT_AMB_NAMES,
		"name-ambiguous meshes moved: want %d, got %d" % [WANT_AMB_NAMES, a.ambiguous_names])
	assert(a.distinct_names == WANT_NAMES,
		"distinct armour filenames moved: want %d, got %d" % [WANT_NAMES, a.distinct_names])
	assert(a.ambiguous_names > a.ambiguous_records,
		"the filename key stopped being weaker than the record key -- one of them is being computed wrong")
	assert(a.duplicate_wearer_groups == WANT_DUP_WEARER,
		"duplicate-wearer groups moved: want %d, got %d" % [WANT_DUP_WEARER, a.duplicate_wearer_groups])

	# 1. The switch does what its name says, on cases a human can check.
	_one(a, "GLAD_s_boots.grn", "MAGICIAN.GRN", "magician_boots")
	_one(a, "gladiator_am_mond.grn", "VLADY_D.GRN", "vlady_AM_Mond")
	_one(a, "AMAZONE_LEATHER.GRN", "SERAPHIM.GRN", "Seraphim_leather_04")

	# 2. Identity: a wearer's own mesh switches to itself. This is what makes
	#    the switch safe to apply unconditionally at a call site -- a piece
	#    already correct for its wearer must not move.
	var self_v := a.variants_for("GLAD_s_boots.grn", "GLADIATOR.GRN")
	assert(self_v.size() == 1 and self_v[0].to_upper().begins_with("GLAD_S_BOOTS"),
		"a wearer's own mesh did not switch to itself: %s" % str(self_v))

	# 3. NAME IS NOT RECORD, pinned on the case that first taught it. There are
	#    TWO armour records spelling Gladiator_Metal_01.grn: one sits in group
	#    82, which lists no Seraphim, and one in group 9, which does. Looked up
	#    by NAME the two are unioned and the answer is Seraphim_metal_01.grn;
	#    looked up as the group-82 RECORD the answer is nothing. Neither is
	#    wrong -- they are different armours that share a mesh file. An earlier
	#    reading of this exact case as "Gladiator plate has no Seraphim version,
	#    a retail class restriction" was an artefact of first-group-wins, and
	#    this assertion exists so nobody re-derives it.
	assert(a.group_count("Gladiator_Metal_01.grn") == 2,
		"Gladiator_Metal_01 now spans %d groups, want 2" % a.group_count("Gladiator_Metal_01.grn"))
	assert(a.is_ambiguous("Gladiator_Metal_01.grn"), "the two-record case stopped reading as ambiguous")
	var sera := a.variants_for("Gladiator_Metal_01.grn", "SERAPHIM.GRN")
	assert(sera.size() == 1 and sera[0].to_upper().begins_with("SERAPHIM_METAL_01"),
		"union lookup lost the group-9 Seraphim variant: %s" % str(sera))

	# 4. A non-armour mesh is not in the table, and says so distinctly.
	assert(a.group_count("BEAR.GRN") == 0, "a creature mesh resolved to an armour group")
	assert(a.variants_for("BEAR.GRN", "GLADIATOR.GRN").is_empty(), "a creature mesh produced a variant")

	# 5. The duplicate-wearer case is REAL and must stay visible: this lookup
	#    returns two meshes and a caller has to choose. If it silently becomes
	#    one, someone has "cleaned up" retail data.
	var two := a.variants_for("Gladiator_Metal_01.grn", "DARKELVE.GRN")
	assert(two.size() >= 2, "the known duplicate-wearer case returned %d meshes, want >= 2" % two.size())

	print("armour_check: %d groups, %d pairs; ambiguous by record %d, by filename %d of %d names; %d duplicate-wearer groups; GLAD_s_boots on a Magician -> %s"
		% [a.groups, a.pairs, a.ambiguous_records, a.ambiguous_names, a.distinct_names, a.duplicate_wearer_groups,
			a.variants_for("GLAD_s_boots.grn", "MAGICIAN.GRN")[0]])
	finish(0)


func _one(a: Sacred.Armour, mesh: String, wearer: String, want_prefix: String) -> void:
	var v := a.variants_for(mesh, wearer)
	expect(not v.is_empty(), "%s worn by %s produced no variant" % [mesh, wearer])
	expect(v[0].to_upper().begins_with(want_prefix.to_upper()),
		"%s worn by %s gave %s, want %s*" % [mesh, wearer, v[0], want_prefix])
