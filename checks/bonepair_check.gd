extends "res://checks/check.gd"
## bonepair_check.gd -- the control for the geometric FormMeshBone tiebreaker.
##
##   godot --headless --path godot-port --script checks/bonepair_check.gd
##
## WHAT THIS PROTECTS. A mesh's weight stream stores LOCAL bone indices and a
## FormMeshBoneSection turns them into global ones; which section belongs to
## which mesh is stated nowhere. The size constraint decides most entries, and
## refuses the left/right symmetric ones -- two boots, two same-size lists
## holding one leg each. Models._pair_by_geometry breaks those ties by asking
## which bones the mesh's vertices actually sit near.
##
## That rule is only worth anything if it is right where something else can
## check it. So: on every entry the SIZE rule decides on its own, the GEOMETRIC
## rule must reach the same answer or decline -- never a different one. A
## disagreement means the distance measure is not reading the file's own
## intent, and one disagreement is enough to fail, because the entries nobody
## can check independently are the entries it exists to answer.
##
## The counts are pinned as well as the agreement, so a future edit that
## "improves" the tiebreaker into deciding hundreds more entries has to come
## here and say so. Silent extra coverage is how a coin flip gets promoted to
## a fact.
const WANT_MIN_STRICT := 800        ## entries the size rule alone decides
const WANT_MIN_BROKEN := 100        ## ties the geometry then breaks
const SPOT := {654: "SERABOOTS01.GRN", 664: "SERASHOULDER01.GRN"}


func _init() -> void:
	super()
	var install := Sacred.find_install()
	assert(install != "", "no retail install found; pass --install=/path/to/install")
	var pak := Sacred.Pak.new(install.path_join("pak/models.pak"))
	assert(pak.is_open(), "models.pak did not open")
	var m := Sacred.Models.new(pak)

	var strict := 0
	var broken := 0
	var refused := 0
	var disagree: Array[String] = []
	for e in pak.count():
		var v := m.pairing_verdicts(e)
		if v.is_empty():
			continue
		var needs: PackedInt32Array = v["needs"]
		if needs.is_empty():
			continue
		var s: PackedInt32Array = v["strict"]
		var g: PackedInt32Array = v["geometric"]
		if not s.is_empty():
			strict += 1
			# The geometric rule may decline (it has a margin); it may not
			# contradict. Compared by the LIST CONTENTS the two answers hand
			# each mesh, not by list index -- two interchangeable lists with
			# identical bones are the same answer under different names.
			if not g.is_empty():
				var lists: Array[PackedInt32Array] = v["lists"]
				for i in needs.size():
					if lists[s[i]] != lists[g[i]]:
						disagree.append("entry %d mesh %d: size rule %s, geometry %s" % [
							e, i, str(lists[s[i]]), str(lists[g[i]])])
						break
		elif not g.is_empty():
			broken += 1
		else:
			refused += 1

	print("bonepair\tstrict=%d\tgeometry_broke=%d\tstill_refused=%d\tdisagreements=%d" % [
		strict, broken, refused, disagree.size()])
	for d in disagree.slice(0, 10):
		print("  DISAGREE ", d)
	expect(disagree.is_empty(),
		"geometry contradicts the size rule on %d entries -- it is not reading the file" % disagree.size())
	expect(strict >= WANT_MIN_STRICT,
		"the size rule now decides only %d entries, want >= %d" % [strict, WANT_MIN_STRICT])
	expect(broken >= WANT_MIN_BROKEN,
		"geometry breaks only %d ties, want >= %d" % [broken, WANT_MIN_BROKEN])

	# The two pieces that made the Seraphim render as a distorted rig. Named
	# rather than counted so a human recognises the result: if these two stop
	# decoding, the parity character is broken again whatever the totals say.
	for e: int in SPOT:
		var w := m.mesh_weights(e)
		expect(w.size() == 2, "%s (entry %d) decoded %d meshes, want 2" % [SPOT[e], e, w.size()])
		if w.size() == 2:
			var a: PackedInt32Array = w[0]["bone_map"]
			var b: PackedInt32Array = w[1]["bone_map"]
			expect(a != b, "%s bound both meshes to the same bone list %s" % [SPOT[e], str(a)])
	finish(0)
