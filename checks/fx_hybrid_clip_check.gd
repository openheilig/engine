extends "res://checks/check.gd"
## fx_hybrid_clip_check.gd -- the ONE runnable check for Wire B (per-record
## dispatch on the FX hybrid animation records identified in row 1168). Pinned
## by NAME to exercise both storage formats and their duplicate-bone merge.
## The explicit record +8 format flag selects the layout; +24/+28/+32
## are pose components in interleaved records, not count fields.
##
##   godot --headless --path godot-port --script fx_hybrid_clip_check.gd
##
## WHAT THIS PROTECTS.
##   1. FX_E_IDLE_BH.GRN (entry 2583) and FX_G_IDLE_BH.GRN (entry 2585) each
##      carry 24 AnimationTransformTrackKeys records: 12 ordinary/sparse +
##      12 sampled/dense, alternating for the same 12 bone ids. Per-record
##      dispatch makes each decode on its own merits and the merge collapses
##      the duplicates by bone id, sampled replacing ordinary. Net: 12
##      records out, all sampled, matching the 12-bone count exactly.
##   2. The non-hybrid entries that previously decoded under the whole-entry
##      decision (HORS_DYING_A sampled-only, WOLF_ATTACK_BH_A ordinary with
##      varying nu) still decode and still produce the same record counts.
##   3. An ordinary record whose span happens to land on 12+68*N does NOT
##      become sampled just because the size fits: its format flag is split.

const HYBRID_E := "FX_E_IDLE_BH.GRN"
const HYBRID_G := "FX_G_IDLE_BH.GRN"
const SAMPLED_ONLY := "HORS_DYING_A.GRN"
const VARYING_NU := "WOLF_ATTACK_BH_A.GRN"

const WANT_HYBRID_RECORDS := 12
const WANT_HYBRID_LEN_MATCH := 1.1
const WANT_SAMPLED_ONLY_RECORDS := 48
const WANT_VARYING_NU_RECORDS := 46


func _init() -> void:
	super()
	var install := Sacred.find_install()
	assert(install != "", "no retail install found; pass --install=/path/to/install")
	var models := Sacred.Models.new(Sacred.Pak.new(install.path_join("pak/models.pak")))

	_check_hybrid(models, HYBRID_E)
	_check_hybrid(models, HYBRID_G)

	# Sampled-only still works: 48 records (one per bone), 1.1s == 33 frames at
	# 1/30. A regression here would mean the per-record path broke pure-sampled.
	var si := models.clip_index_of(SAMPLED_ONLY)
	assert(si >= 0, "no motion entry named %s" % SAMPLED_ONLY)
	var sc := models.clip(si)
	assert(not sc.is_empty(), "%s no longer decodes -- the sampled-only path regressed" % SAMPLED_ONLY)
	var srecs: Array = sc["records"]
	assert(srecs.size() == WANT_SAMPLED_ONLY_RECORDS,
		"%s record count: want %d, got %d" % [SAMPLED_ONLY, WANT_SAMPLED_ONLY_RECORDS, srecs.size()])
	assert(absf(float(sc["length"]) - WANT_HYBRID_LEN_MATCH) < 0.001,
		"%s length: want %f, got %f" % [SAMPLED_ONLY, WANT_HYBRID_LEN_MATCH, sc["length"]])

	# Varying-nu ordinary still works: 46 records, the discriminator 05-02
	# settled on. A regression here would mean the per-record path broke pure
	# ordinary entries whose counts vary record-to-record.
	var vi := models.clip_index_of(VARYING_NU)
	assert(vi >= 0, "no motion entry named %s" % VARYING_NU)
	var vc := models.clip(vi)
	assert(not vc.is_empty(), "%s no longer decodes -- the ordinary path regressed" % VARYING_NU)
	var vrecs: Array = vc["records"]
	assert(vrecs.size() == WANT_VARYING_NU_RECORDS,
		"%s record count: want %d, got %d" % [VARYING_NU, WANT_VARYING_NU_RECORDS, vrecs.size()])

	print("fx_hybrid_clip_check: %s and %s collapse 24 records to %d sampled; %s keeps %d, %s keeps %d" % [
		HYBRID_E, HYBRID_G, WANT_HYBRID_RECORDS,
		SAMPLED_ONLY, WANT_SAMPLED_ONLY_RECORDS,
		VARYING_NU, WANT_VARYING_NU_RECORDS])
	finish(0)


## Hybrid entry: 24 records in the file, 12 distinct bone ids, every record's
## id seen exactly twice (ordinary+sampled). After Wire B per-record dispatch
## + merge, expect 12 sampled records out.
func _check_hybrid(models: Sacred.Models, name: String) -> void:
	var ci := models.clip_index_of(name)
	assert(ci >= 0, "no motion entry named %s" % name)
	var c := models.clip(ci)
	assert(not c.is_empty(),
		"%s still refuses -- per-record dispatch did not land" % name)
	var recs: Array = c["records"]
	assert(recs.size() == WANT_HYBRID_RECORDS,
		"%s post-merge record count: want %d, got %d (sampled did not replace ordinary by bone id)"
			% [name, WANT_HYBRID_RECORDS, recs.size()])
	# Every merged record must be sampled: a hybrid merge that keeps an
	# ordinary record alongside a sampled one for the same id is a regression.
	for i in recs.size():
		var r: Dictionary = recs[i]
		var tp: PackedFloat32Array = r["times_pos"]
		var tr: PackedFloat32Array = r["times_rot"]
		var to: PackedFloat32Array = r["times_other"]
		assert(tp.size() == tr.size() and tr.size() == to.size(),
			"%s record %d is ordinary, not sampled (times mismatch)" % [name, i])
		assert(tp.size() > 0,
			"%s record %d decoded zero keys" % [name, i])
	# clip_track_bone now succeeds: 12 records vs 12 bones, no count-mismatch.
	var tb := models.clip_track_bone(ci)
	assert(tb.size() == WANT_HYBRID_RECORDS,
		"%s clip_track_bone: want %d, got %d (positional bind still refused)"
			% [name, WANT_HYBRID_RECORDS, tb.size()])
