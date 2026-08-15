extends "res://checks/check.gd"
## rigs_check.gd -- the ONE runnable check for Sacred.Rigs, which decides which
## animation clip belongs to which mesh by BONE GEOMETRY because the shipped
## names do not line up.
##
##   godot --headless --path godot-port --script rigs_check.gd
##
## Runs over the real work load: every distinct creature mesh the spawn tables
## name, resolved through the same chain the world will use --
## Funk -> creature id -> Items.name_of -> Models.index_of -> Rigs.clip_for.
##
## WHAT WOULD BREAK THIS. Rigs picks the best-agreeing clip out of all 3397,
## with no name filtering at any step, so a reader that degrades into matching
## everything shows up immediately as a collapse in the score spread. The two
## spot-checks at the end are the human-readable half: a bear must not end up
## animated as a wolf.
const MIN_MODELS := 100
## Measured 0.976 (121 of 124). 0.90 leaves room for corpus drift while still
## catching a real regression -- at 0.5 the bar sat 47 points below the value
## and could only detect catastrophe. The rate is the coarse arm regardless:
## the control below is what decides whether the match means anything.
const MIN_RESOLVED_FRAC := 0.90
## The control arm samples this many resolved meshes. Each one is re-scored
## twice, so keep it small enough that the check stays a few seconds.
const CONTROL_SAMPLE := 20
## The real and control score distributions must not touch. 0.20 is slack, not
## a target: measured separation is far wider, and a margin that has to be
## tuned to pass is not a control.
const CONTROL_MARGIN := 0.20


func _init() -> void:
	super()
	var install := Sacred.find_install()
	assert(install != "", "no retail install found; pass --install=/path/to/install")
	var models := Sacred.Models.new(Sacred.Pak.new(install.path_join("pak/models.pak")))
	var items := Sacred.Items.new(Sacred.Pak.new(install.path_join("pak/items.pak")))
	var funk := Sacred.Funk.new(install.path_join("bin/type_npc_seraphim"))

	# The chain, exactly as the world uses it. Every spawn id must name a mesh:
	# if this drops below 100% one of four readers has drifted, and the check
	# says which by failing here rather than by drawing nothing later.
	var wanted := PackedInt32Array()
	var by_name: Dictionary[String, int] = {}
	var ids := 0
	for roll in funk.rolls:
		for e: Vector3i in roll["entries"]:
			ids += 1
			var nm := items.name_of(e.x)
			assert(nm != "", "spawn id %d has no items.pak name" % e.x)
			if by_name.has(nm):
				continue
			var mi := models.index_of(nm)
			assert(mi >= 0, "items name %s (spawn id %d) is not in models.pak" % [nm, e.x])
			by_name[nm] = mi
			wanted.append(mi)
	assert(wanted.size() >= MIN_MODELS,
		"only %d distinct creature meshes found, want >= %d" % [wanted.size(), MIN_MODELS])

	var t0 := Time.get_ticks_msec()
	var rigs := Sacred.Rigs.new(models, wanted)
	var ms := Time.get_ticks_msec() - t0

	var frac := float(rigs.resolved) / float(wanted.size())
	assert(frac >= MIN_RESOLVED_FRAC,
		"clip resolution collapsed to %.3f of %d meshes" % [frac, wanted.size()])

	# The score spread is the anti-degradation assertion. Real pairs measure
	# 0.79..0.97; a wrong-character pair measures 0.04. If everything suddenly
	# resolves at a uniform score, the comparison has stopped discriminating.
	var lo := 1.0
	var hi := 0.0
	for e in wanted:
		if rigs.clip_for(e) < 0:
			continue
		var s := rigs.score_for(e)
		assert(s >= Sacred.Rigs.MIN_SCORE, "resolved mesh %d kept a sub-threshold score %f" % [e, s])
		lo = minf(lo, s)
		hi = maxf(hi, s)
	assert(hi > 0.8, "best agreement fell to %f -- the comparison is no longer finding real pairs" % hi)

	# THE CONTROL ARM. A resolution rate proves nothing on its own: 97.6% of
	# meshes resolving could equally mean the comparison discriminates, or that
	# the clip corpus is dense enough that anything matches something. The
	# question a rate cannot answer is what this would score IF THE HYPOTHESIS
	# WERE FALSE, so the check now measures that instead of assuming it.
	#
	# The control permutes each mesh's bone ORIGINS among its own bone NAMES,
	# rotating by one over the sorted names. Everything the comparison consumes
	# is preserved -- the same bones, the same names, the same positions, the
	# same counts, so `matched` is identical and cannot shrink the denominator.
	# Only the name-to-position correspondence is destroyed, which is precisely
	# the thing being tested. A cross-pairing control was rejected: creatures
	# genuinely share rigs, so pairing mesh A with mesh B's clip can be RIGHT,
	# and a control that can accidentally be correct is not a control.
	var real_lo := 1.0
	var ctrl_hi := 0.0
	var pairs := 0
	for e in wanted:
		if pairs >= CONTROL_SAMPLE:
			break
		var ci := rigs.clip_for(e)
		if ci < 0:
			continue
		var origin := _origins(models, e)
		if origin.size() < Sacred.Rigs.MIN_MATCHED:
			continue
		var real := _score(models, ci, origin)
		# Recomputing the real score here is a second decoder for it: if this
		# disagrees with what Rigs stored, one of the two is wrong.
		assert(absf(real - rigs.score_for(e)) < 0.001,
			"re-scoring mesh %d against its own clip gives %f, Rigs stored %f" % [e, real, rigs.score_for(e)])
		var ctrl := _score(models, ci, _rotate(origin))
		real_lo = minf(real_lo, real)
		ctrl_hi = maxf(ctrl_hi, ctrl)
		pairs += 1
	assert(pairs >= 5, "only %d control pairs -- too few for the arm to mean anything" % pairs)
	assert(real_lo - ctrl_hi >= CONTROL_MARGIN,
		"the control is not separated: worst real pair %f, best permuted pair %f over %d pairs -- bone position is not what is deciding the match"
			% [real_lo, ctrl_hi, pairs])

	# Spot checks. Named because they are recognisable: if BEAR animates as a
	# wolf a human reading this line knows something is wrong, which no
	# aggregate fraction conveys.
	_spot(models, items, rigs, by_name, "BEAR.GRN", "BEAR")
	_spot(models, items, rigs, by_name, "WOLF.GRN", "WOLF")

	print("rigs_check: %d spawn entries -> %d distinct meshes, %d clips resolved (%.1f%%), scores %.3f..%.3f, control %d pairs real >= %.3f vs permuted <= %.3f, %d ms"
		% [ids, wanted.size(), rigs.resolved, frac * 100.0, lo, hi, pairs, real_lo, ctrl_hi, ms])
	finish(0)


## Asserts that `mesh_name`'s chosen clip name starts with `want_prefix`. Only
## usable where the naming HAPPENS to agree -- most creatures are exactly the
## case where it does not, which is why Rigs exists at all.
func _spot(models: Sacred.Models, _items: Sacred.Items, rigs: Sacred.Rigs,
		by_name: Dictionary[String, int], mesh_name: String, want_prefix: String) -> void:
	if not by_name.has(mesh_name):
		return          # not spawned by this class's tables; nothing to check
	var ci := rigs.clip_for(by_name[mesh_name])
	expect(ci >= 0, "%s resolved to no clip at all" % mesh_name)
	var cn := models.entry_name(ci).to_upper()
	expect(cn.begins_with(want_prefix),
		"%s picked clip %s, which is not a %s* clip" % [mesh_name, cn, want_prefix])


## Bone name -> local rest origin, the only field the comparison reads.
func _origins(models: Sacred.Models, entry: int) -> Dictionary:
	var d: Dictionary = {}
	for b in models.bones(entry):
		var nm: String = (b["name"] as PackedByteArray).get_string_from_utf8()
		if nm != "" and not d.has(nm):
			d[nm] = (b["rest"] as Transform3D).origin
	return d


## Same names, same set of origins, each origin moved to the next name in
## sorted order. Deterministic on purpose -- a control seeded from RNG would
## make the check's own verdict irreproducible.
func _rotate(origin: Dictionary) -> Dictionary:
	var names := origin.keys()
	names.sort()
	var out: Dictionary = {}
	for i in names.size():
		out[names[i]] = origin[names[(i + 1) % names.size()]]
	return out


## Sacred.Rigs' scoring, reimplemented against a supplied origin table so the
## same code path can be run on real and permuted input.
func _score(models: Sacred.Models, clip: int, origin: Dictionary) -> float:
	var cn := models.clip_bone_names(clip)
	var cb := models.clip_bones(clip)
	if cb.size() != cn.size():
		return -1.0
	var matched := 0
	var within := 0
	for j in cn.size():
		var o: Variant = origin.get(cn[j])
		if o == null:
			continue
		matched += 1
		if (cb[j]["rest"] as Transform3D).origin.distance_to(o) <= Sacred.Rigs.WITHIN:
			within += 1
	if matched < Sacred.Rigs.MIN_MATCHED:
		return -1.0
	return float(within) / float(matched)
