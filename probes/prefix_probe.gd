extends SceneTree
## Would a LEARNED name prefix unite a character's clips without admitting
## another character's?
##
##   godot --headless --path . --script res://probes/prefix_probe.gd
##
## Row 1054: the Seraphim ships as two rig revisions and Rigs, which compares
## bone rest POSITIONS, reads them as two characters -- while playback drops
## translation tracks entirely and does not care. The proposal is that geometry
## already proves ONE clip per mesh above MIN_SCORE, so the prefix of THAT
## clip's name is learned rather than assumed, and the rest of the prefix is
## admitted. Row 963's counterexample (`UPI1_WALK_BH.GRN` belongs to
## `UPIRATE_01.GRN`) forbids assuming the prefix a priori; it does not forbid
## learning it.
##
## THIS COSTS NOTHING TO MEASURE. Rigs has already resolved and cached every
## mesh a run has wanted, so the map is read off user://rigmap.tsv rather than
## recomputed. Nothing here scores anything.
##
## Two questions, and the second is the one that can kill the idea:
##
##   GAIN      how many actions each mesh would gain.
##   COLLISION whether one prefix is claimed by more than one mesh, and
##             whether those meshes are the same character. A prefix shared
##             by two genuinely different bodies would hand each the other's
##             clips, which is exactly the failure Rigs exists to prevent.
const CACHE := "user://rigmap.tsv"

func _init() -> void:
	var install := Sacred.find_install()
	var pak := Sacred.Pak.new(install.path_join("pak/models.pak"))
	var models := Sacred.Models.new(pak)

	var f := FileAccess.open(CACHE, FileAccess.READ)
	if f == null:
		print("no cache at %s -- run the app once first" % CACHE)
		return
	f.get_line()   # header
	var best: Dictionary = {}        # mesh entry -> clip entry
	var score: Dictionary = {}
	var acts: Dictionary = {}        # mesh entry -> {ACTION: clip}
	while not f.eof_reached():
		var parts := f.get_line().split("\t")
		if parts.size() == 3:
			best[int(parts[0])] = int(parts[1])
			score[int(parts[0])] = float(parts[2])
		elif parts.size() == 4 and parts[0] == "a":
			var e := int(parts[1])
			if not acts.has(e):
				acts[e] = {}
			(acts[e] as Dictionary)[parts[2]] = int(parts[3])

	# Every clip in the pak, grouped by the token before its first underscore.
	var by_prefix: Dictionary = {}
	for ci in models.count():
		if models.kind_of(ci) != Sacred.Models.KIND_MOTION or not models.is_animation(ci):
			continue
		var nm := models.entry_name(ci)
		var p := nm.split("_")[0]
		if p == nm:
			continue            # no underscore: names no prefix
		# Array, NOT PackedInt32Array: a Packed array read back out of a
		# Variant-typed Dictionary is a COPY, so appending to it mutates
		# nothing and every bucket stays empty. The first run of this probe
		# reported prefix_clips=0 for every mesh and collisions=0 for every
		# prefix, both of which read like findings.
		if not by_prefix.has(p):
			by_prefix[p] = []
		(by_prefix[p] as Array).append(ci)

	var claim: Dictionary = {}       # prefix -> [mesh names]
	var rows: Array = []
	for e: int in best:
		var bc: int = best[e]
		if bc < 0:
			continue
		var cn := models.entry_name(bc)
		var p := cn.split("_")[0]
		if p == cn:
			continue
		if not claim.has(p):
			claim[p] = []
		(claim[p] as Array).append(models.entry_name(e))
		var have: Dictionary = acts.get(e, {})
		# What the prefix would add, as ACTIONS -- an action the mesh already
		# resolves is not a gain.
		var gained: Dictionary = {}
		for ci in (by_prefix.get(p, []) as Array):
			var a := Sacred.Rigs.action_of(models.entry_name(ci))
			if a != "" and not have.has(a) and not gained.has(a):
				gained[a] = ci
		var g := gained.keys()
		g.sort()
		rows.append([g.size(), models.entry_name(e), p, have.size(), g,
			float(score.get(e, 0.0)), (by_prefix.get(p, []) as Array).size()])
	rows.sort_custom(func(a, b): return a[0] > b[0])
	print("meshes_resolved=%d\tprefixes_in_pak=%d" % [rows.size(), by_prefix.size()])
	print("-- biggest gains --")
	for i in mini(20, rows.size()):
		print("gain\t%-26s\tprefix=%-10s\thas=%d\t+%d\t%s\tbest=%.3f\tprefix_clips=%d" % [
			rows[i][1], rows[i][2], rows[i][3], rows[i][0], rows[i][4], rows[i][5], rows[i][6]])
	var zero := 0
	for r in rows:
		if r[0] == 0:
			zero += 1
	print("meshes_gaining_nothing=%d of %d" % [zero, rows.size()])
	print("-- prefixes claimed by more than one mesh --")
	var ncol := 0
	for p: String in claim:
		var ms: Array = claim[p]
		if ms.size() > 1:
			ncol += 1
			print("collide\t%-10s\t%d\t%s" % [p, ms.size(), ms])
	print("collisions=%d of %d claimed prefixes" % [ncol, claim.size()])
	quit()
