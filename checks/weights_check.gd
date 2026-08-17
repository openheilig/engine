extends "res://checks/check.gd"
## weights_check.gd -- the ONE runnable check for the FormMeshBone PAIRING
## RULE: which bone list belongs to which mesh (autoresearch row 943).
##
##   godot --headless --path godot-port --script checks/weights_check.gd
##
## THE PROBLEM. A mesh's weight stream stores LOCAL bone indices and a
## FormMeshBoneSection turns them into global bone ids. Nothing states which
## section belongs to which mesh, and the two obvious answers are both wrong:
## the sections are not children of the Mesh nodes, and their order is not mesh
## order. The rule that stood until row 943 searched for a list whose length
## EQUALS highest+1 and refused unless exactly one matched; it failed 24.72% of
## the corpus.
##
## WHAT REPLACED IT. `len(list) >= highest + 1` -- a mesh's local indices must
## FIT INSIDE its list, not exhaust it -- solved as a perfect matching and
## accepted only when every valid matching hands each mesh the same list.
##
## Every assertion below reads only Models' public output, so this checks the
## rule's PROMISES rather than re-implementing its search and agreeing with
## itself. Three of them would each, alone, fail if the equality rule were
## reinstated or if positional pairing were adopted.
const WANT_DECLARE := 971

## 802 until the geometric tiebreaker landed in Models._pair_by_geometry, 920
## until the FILE'S OWN pairing was found (row 1009): each FormMesh's payload
## int is a 1-based all-mesh reference, so the pairing stopped being a search.
## Measured, as the assert message below demands: the reference decides all
## 1567 entries with pair inputs, agrees with the strict rule on every one of
## the 1349 it decides alone (bonepair_check enforces both), and turns the 79
## entries BOTH fallbacks refused -- DUNKELELVE.GRN among them -- into decodes.
## 971 declare, 955 decode; the 16 remaining refusals are weight-stream
## defects, not pairing ones.
const WANT_DECODE := 955

## The entry that refutes POSITIONAL pairing. Three meshes needing 27, 3 and 12
## bones, whose sections appear in the directory as 12, 27, 3 -- so a reader
## that pairs the i-th mesh with the i-th section produces [12, 27, 3] here and
## fails on the first mesh, whose local indices run to 26.
const POSITIONAL_TRAP := "DWARF_BLACK_BODY.GRN"
const POSITIONAL_TRAP_SIZES: Array[int] = [27, 3, 12]

## A second, smaller one: two meshes needing 9 and 5, sections ordered 5 then 9.
const POSITIONAL_TRAP_2 := "AMAZONE_CLOTH.GRN"
const POSITIONAL_TRAP_2_SIZES: Array[int] = [9, 5]

## Left/right symmetric pieces whose two lists are the SAME SIZE and DIFFERENT
## BONES, so counts alone cannot say which boot goes on which leg. This held
## SERABOOTS01.GRN and SERASHOULDER01.GRN, pinned as REFUSED so that a future
## geometric tiebreak had to move the constant deliberately rather than silently.
##
## MOVED, deliberately. Models._pair_by_geometry now decides them by mean
## vertex-to-bone distance, which is the signal counts were missing -- a boot's
## vertices sit near its own leg's bones and far from the other's, so this is
## principled rather than the coin flip the paragraph above warns about. Both
## are spot-checked by entry id in checks/bonepair_check.gd (654, 664), which is
## where the ongoing coverage lives; empty here means nothing is currently
## refused for size-tie reasons, and a new entry appearing must be justified.
const AMBIGUOUS: Array[String] = []


func _init() -> void:
	super()
	var install := Sacred.find_install()
	assert(install != "", "no retail install found; pass --install=/path/to/install")
	var models := Sacred.Models.new(Sacred.Pak.new(install.path_join("pak/models.pak")))
	assert(models.count() > 0, "models.pak did not open")

	var census := _census(models)
	assert(census["declare"] == WANT_DECLARE,
		"weight-declaring entries moved: want %d, got %d" % [WANT_DECLARE, census["declare"]])
	assert(census["decode"] == WANT_DECODE,
		"decoding entries moved: want %d, got %d -- a pairing change must be measured, not noticed"
			% [WANT_DECODE, census["decode"]])

	_fits(models, census)
	_prefix(models, census)
	_positional(models)
	_ambiguous(models)

	print("weights_check OK declare=%d decode=%d refused=%d prefix_users=%d" % [
		census["declare"], census["decode"], census["declare"] - census["decode"],
		census["prefix"]])
	finish(0)


## One pass over every rigged entry that declares weights.
func _census(models) -> Dictionary:
	var declare := 0
	var decode := 0
	var prefix := 0
	var loose: Array[String] = []
	for e in models.count():
		if models.kind_of(e) != Sacred.Models.KIND_MESH:
			continue
		if models.bones(e).is_empty() or not models.has_mesh_weights(e):
			continue
		declare += 1
		var w: Array[Dictionary] = models.mesh_weights(e)
		if w.is_empty():
			continue
		decode += 1
		for blk: Dictionary in w:
			var bm: PackedInt32Array = blk["bone_map"]
			var hi: int = blk["highest"]
			# THE RULE'S OWN PROMISE. Every local index a mesh uses must land
			# inside the list it was given. This is what a wrong pairing breaks,
			# and it is checkable without knowing how the pairing was chosen.
			if hi >= bm.size():
				if loose.size() < 8:
					loose.append("%s (highest %d, list %d)" % [models.entry_name(e), hi, bm.size()])
			elif hi + 1 < bm.size():
				prefix += 1
	return {"declare": declare, "decode": decode, "prefix": prefix, "loose": loose}


## No decoded mesh may index past its own bone list.
func _fits(_models, census: Dictionary) -> void:
	var loose: Array = census["loose"]
	assert(loose.is_empty(),
		"%d decoded meshes index past their bone list: %s" % [loose.size(), loose])


## A MESH MAY USE A PREFIX, and this is the assertion that fails the moment
## anyone reinstates `len == highest + 1`. Under equality this count is zero by
## construction, so a non-zero value is proof the looser constraint is doing
## real work rather than being an untested widening.
func _prefix(_models, census: Dictionary) -> void:
	assert(census["prefix"] > 0,
		"no decoded mesh uses fewer bones than its list holds -- the pairing has collapsed back to an equality search")


## The two entries where section order is NOT mesh order. Pinning the bone-map
## SIZES in mesh order is what encodes the refutation: positional pairing would
## hand these meshes their sections in file order and produce different sizes.
func _positional(models) -> void:
	for pair in [[POSITIONAL_TRAP, POSITIONAL_TRAP_SIZES],
			[POSITIONAL_TRAP_2, POSITIONAL_TRAP_2_SIZES]]:
		var nm: String = pair[0]
		var want: Array = pair[1]
		var e: int = models.index_of(nm)
		if not expect(e >= 0, "%s is not in models.pak" % nm):
			continue
		var w: Array[Dictionary] = models.mesh_weights(e)
		if not expect(not w.is_empty(), "%s no longer decodes" % nm):
			continue
		var got: Array[int] = []
		for blk: Dictionary in w:
			got.append((blk["bone_map"] as PackedInt32Array).size())
		expect(got == want,
			"%s bone-map sizes are %s, expected %s -- the sections have been paired in file order"
				% [nm, got, want])


## The genuinely ambiguous pieces stay refused. If a geometric tiebreak lands
## later this fails, which is the intended way to notice.
func _ambiguous(models) -> void:
	for nm in AMBIGUOUS:
		var e: int = models.index_of(nm)
		if not expect(e >= 0, "%s is not in models.pak" % nm):
			continue
		expect(models.has_mesh_weights(e), "%s no longer declares weights" % nm)
		expect(models.mesh_weights(e).is_empty(),
			"%s now decodes -- if a tiebreak resolved it, move it out of AMBIGUOUS deliberately" % nm)
