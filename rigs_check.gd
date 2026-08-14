extends "res://check.gd"
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
const MIN_RESOLVED_FRAC := 0.5


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

	# Spot checks. Named because they are recognisable: if BEAR animates as a
	# wolf a human reading this line knows something is wrong, which no
	# aggregate fraction conveys.
	_spot(models, items, rigs, by_name, "BEAR.GRN", "BEAR")
	_spot(models, items, rigs, by_name, "WOLF.GRN", "WOLF")

	print("rigs_check: %d spawn entries -> %d distinct meshes, %d clips resolved (%.1f%%), scores %.3f..%.3f, %d ms"
		% [ids, wanted.size(), rigs.resolved, frac * 100.0, lo, hi, ms])
	finish(0)


## Asserts that `mesh_name`'s chosen clip name starts with `want_prefix`. Only
## usable where the naming HAPPENS to agree -- most creatures are exactly the
## case where it does not, which is why Rigs exists at all.
func _spot(models: Sacred.Models, _items: Sacred.Items, rigs: Sacred.Rigs,
		by_name: Dictionary[String, int], mesh_name: String, want_prefix: String) -> void:
	if not by_name.has(mesh_name):
		return          # not spawned by this class's tables; nothing to check
	var ci := rigs.clip_for(by_name[mesh_name])
	assert(ci >= 0, "%s resolved to no clip at all" % mesh_name)
	var cn := models.entry_name(ci).to_upper()
	assert(cn.begins_with(want_prefix),
		"%s picked clip %s, which is not a %s* clip" % [mesh_name, cn, want_prefix])
