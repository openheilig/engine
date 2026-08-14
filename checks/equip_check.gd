extends "res://checks/check.gd"
## equip_check.gd -- R1.4 re-measured. Do a character's equipment-slot meshes
## share that character's skeleton?
##
##   godot --headless --path godot-port --script equip_check.gd
##
## HISTORY, because this question has a verdict already. Rows 605 and 606
## measured it twice by composing WORLD bind transforms and both came back
## REFUTED; row 613 is the human decision that WITHDREW R1.4 on that evidence.
## Row 739 then showed that the world-space comparison is the wrong quantity
## for a different question of the same shape (clip vs mesh): the files do not
## share the bone chain above Bip01, so composing it accumulates a difference
## that has nothing to do with whether the rigs match. This check asks R1.4's
## question with the LOCAL instrument instead -- each bone's own rest
## transform, chain never composed, matched by exact bone NAME.
##
## THE RULE, fixed before the first run and not adjustable afterwards:
##   CONFIRMED iff median own-base agreement > 0.8
##          AND median own-base agreement > 5x median cross-character agreement.
##   Anything else is REFUTED.
##
## The cross-character control is the load-bearing half. "The pieces agree with
## the base" is not a finding on its own -- a comparison that has degenerated
## into matching anything would say exactly that. The control measures the SAME
## pieces against a DIFFERENT character's base and must disagree.
##
## The prefix grouping is deliberately conservative: it is a naming heuristic,
## and row 739 showed naming is unreliable in this corpus. Any piece it wrongly
## sweeps into a family LOWERS that family's agreement, so the instrument can
## only understate the result, never inflate it.
const WITHIN := 0.01
const MIN_MATCHED := 20
const PASS_OWN := 0.8
const SEPARATION := 5.0
## base mesh, and the prefix its equipment pieces share. Cross-controls rotate
## through this same list, so every family is tested against a real character
## rather than against a synthetic skeleton.
const FAMILIES := [
	{"base": "GLADIATOR.GRN", "prefix": "GLAD"},
	{"base": "SERAPHIM.GRN", "prefix": "SERA"},
	{"base": "AMAZONE.GRN", "prefix": "AMAZ"},
	{"base": "DARKELVE.GRN", "prefix": "DARK"},
	{"base": "DWARF.GRN", "prefix": "DWAR"},
	{"base": "MAGICIAN.GRN", "prefix": "MAGE"},
]


func _init() -> void:
	super()
	var install := Sacred.find_install()
	assert(install != "", "no retail install found; pass --install=/path/to/install")
	var models := Sacred.Models.new(Sacred.Pak.new(install.path_join("pak/models.pak")))

	var base_local: Array[Dictionary] = []
	var base_parent: Array[Dictionary] = []
	for fam in FAMILIES:
		var bi := models.index_of(fam["base"])
		assert(bi >= 0, "base mesh %s is not in models.pak" % fam["base"])
		var pair := _index(models, bi)
		assert((pair[0] as Dictionary).size() >= MIN_MATCHED,
			"base %s decoded only %d bones" % [fam["base"], (pair[0] as Dictionary).size()])
		base_local.append(pair[0])
		base_parent.append(pair[1])

	var all_own: Array[float] = []
	var all_cross: Array[float] = []
	var all_topo: Array[float] = []
	var total_pieces := 0
	var total_skipped := 0

	for f in FAMILIES.size():
		var fam: Dictionary = FAMILIES[f]
		var cross: int = (f + 1) % FAMILIES.size()
		var own: Array[float] = []
		var crs: Array[float] = []
		var topo: Array[float] = []
		var skipped := 0
		for i in models.count():
			if models.kind_of(i) == Sacred.Models.KIND_MOTION:
				continue
			var nm := models.entry_name(i).to_upper()
			if not nm.begins_with(fam["prefix"]) or nm == String(fam["base"]).to_upper():
				continue
			var pair := _index(models, i)
			var pl: Dictionary = pair[0]
			var pp: Dictionary = pair[1]
			if pl.size() < MIN_MATCHED:
				# A piece carrying no real rig of its own (a prop, a single-bone
				# attachment). Counted and reported, never silently dropped:
				# hiding them would overstate how much of the family shares a
				# skeleton at all.
				skipped += 1
				continue
			var a := _agree(pl, pp, base_local[f], base_parent[f])
			if a["matched"] < MIN_MATCHED:
				skipped += 1
				continue
			own.append(a["within"])
			topo.append(a["topo"])
			var b := _agree(pl, pp, base_local[cross], base_parent[cross])
			# A piece that shares too few names with the CONTROL base scores 0
			# rather than being dropped -- dropping it would quietly remove the
			# strongest disagreements from the control's median.
			crs.append(b["within"] if b["matched"] >= MIN_MATCHED else 0.0)
		total_pieces += own.size()
		total_skipped += skipped
		assert(own.size() >= 3, "family %s yielded only %d rigged pieces" % [fam["prefix"], own.size()])
		print("equip\t%s\tpieces=%d\tno_rig=%d\town=%.4f\tcross=%.4f (vs %s)\ttopo=%.4f" % [
			fam["prefix"], own.size(), skipped, _median(own), _median(crs),
			FAMILIES[cross]["prefix"], _median(topo)])
		all_own.append_array(own)
		all_cross.append_array(crs)
		all_topo.append_array(topo)

	var m_own := _median(all_own)
	var m_cross := _median(all_cross)
	var m_topo := _median(all_topo)
	var confirmed := m_own > PASS_OWN and m_own > SEPARATION * m_cross
	print("equip\tTOTAL\tpieces=%d\tno_rig=%d\tmedian_own=%.4f\tmedian_cross=%.4f\tmedian_topo=%.4f"
		% [total_pieces, total_skipped, m_own, m_cross, m_topo])
	print("equip\tverdict=%s\t(rule: own > %.2f and own > %.0fx cross)"
		% ["CONFIRMED" if confirmed else "REFUTED", PASS_OWN, SEPARATION])
	# The verdict is the finding; the assertion is what stops a later edit from
	# quietly undoing it. If R1.4 is ever re-refuted this line is where a human
	# has to look, not a silently changed number.
	assert(confirmed, "R1.4 re-measurement did not confirm: own=%.4f cross=%.4f" % [m_own, m_cross])
	finish(0)


## [name -> local rest ORIGIN, name -> parent's NAME] for one mesh entry.
func _index(models: Sacred.Models, entry: int) -> Array:
	var bl := models.bones(entry)
	var local := {}
	var parent := {}
	for i in bl.size():
		var nm: String = (bl[i]["name"] as PackedByteArray).get_string_from_utf8()
		if nm == "" or local.has(nm):
			continue
		local[nm] = (bl[i]["rest"] as Transform3D).origin
		var pe: int = bl[i]["parent_effective"]
		parent[nm] = ((bl[pe]["name"] as PackedByteArray).get_string_from_utf8()
			if pe >= 0 and pe < bl.size() else "")
	return [local, parent]


## Local-rest and topology agreement of one piece against one base.
func _agree(pl: Dictionary, pp: Dictionary, bl: Dictionary, bp: Dictionary) -> Dictionary:
	var matched := 0
	var within := 0
	var topo := 0
	for nm: String in pl:
		if not bl.has(nm):
			continue
		matched += 1
		if (pl[nm] as Vector3).distance_to(bl[nm]) <= WITHIN:
			within += 1
		if pp.get(nm, "") == bp.get(nm, ""):
			topo += 1
	return {"matched": matched,
		"within": (float(within) / float(matched)) if matched > 0 else 0.0,
		"topo": (float(topo) / float(matched)) if matched > 0 else 0.0}


func _median(v: Array[float]) -> float:
	if v.is_empty():
		return 0.0
	var s := v.duplicate()
	s.sort()
	var n := s.size()
	return s[n / 2] if n % 2 == 1 else (s[n / 2 - 1] + s[n / 2]) * 0.5
