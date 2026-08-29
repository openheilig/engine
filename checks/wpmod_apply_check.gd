extends "res://checks/check.gd"
## wpmod_apply_check.gd -- Wire F: Sacred.Wpmod.apply_to_item().
##
##   godot --headless --path godot-port --script res://checks/wpmod_apply_check.gd
##
## TDD gate for the modifier consumer: returns a Dictionary keyed on modifier
## fields, additive ints (NOT percentages -- row 1166 names no unit), and is
## safe to call with an empty stats dict.

const SHIELD_KITE := 1200          ## known modifier record 168, three Bonus blocks
const NO_RECORD := 9999999         ## items.pak record that no wpmod row names


func _init() -> void:
	super()
	var install := Sacred.find_install()
	assert(install != "", "no retail install found; pass --install=/path/to/install")
	var w := Sacred.Wpmod.new(install)
	assert(w.found, "bin/wpmod.bin did not decode")

	# (1) An item with no modifier records returns an empty dict on an empty
	# input, and an UNCHANGED copy of the input dict on a populated one.
	var recs := w.records_for_item(NO_RECORD)
	assert(recs.is_empty(),
		"test rig invalid: items.pak %d unexpectedly names %d modifier records"
			% [NO_RECORD, recs.size()])
	var empty_out := w.apply_to_item(NO_RECORD, {})
	assert(empty_out.is_empty(),
		"empty item + empty stats: want {} got %s" % [empty_out])
	var seed := {"hit_points": 100}
	var seed_out := w.apply_to_item(NO_RECORD, seed)
	assert(seed_out.has("hit_points") and seed_out["hit_points"] == 100,
		"empty item overwrote caller stats: %s" % [seed_out])

	# (2) The known item SHIELD_KITE.GRN is named by modifier record 168 with
	# THREE Bonus: blocks (verified by checks/wpmod_check.gd). The result
	# must carry a "bonus_<id>" key per block and the magnitude being the
	# upper bound of the [lo,hi] spread.
	var out := w.apply_to_item(SHIELD_KITE, {})
	# 168 has Bonus: ids 805, 806, 810 (from the wpmod_check baseline).
	for bid in [805, 806, 810]:
		var k := "bonus_%d" % bid
		assert(out.has(k),
			"SHIELD_KITE missing key %s; have %s" % [k, out.keys()])
		assert(int(out[k]) > 0,
			"%s should be a positive int, got %s" % [k, out[k]])
	# The exact magnitudes were 15, 15, 50 in the live probe -- assert >= 1
	# (lo could be 0, hi is magnitude) AND that none of the values exceeds
	# 1000 (a sanity ceiling; magnitudes are int16 halves of a u16).
	assert(int(out["bonus_805"]) <= 1000, "bonus_805 ceiling broken: %d" % int(out["bonus_805"]))
	assert(int(out["bonus_806"]) <= 1000, "bonus_806 ceiling broken: %d" % int(out["bonus_806"]))
	assert(int(out["bonus_810"]) <= 1000, "bonus_810 ceiling broken: %d" % int(out["bonus_810"]))

	# (3) ADDITIVE: passing a seed value gets accumulated. Set "bonus_805"
	# to 7 in stats, verify the result carries 7 + (record's magnitude).
	var add_in := {"bonus_805": 7}
	var add_out := w.apply_to_item(SHIELD_KITE, add_in)
	var rec_mag_805 := 0
	for r in recs_168(w):
		for m in w.modifiers(r):
			if m["kind"] == "bonus" and int(m["id"]) == 805:
				rec_mag_805 = int(m["magnitude"])
	assert(rec_mag_805 > 0, "test rig: 168 should carry bonus_805")
	assert(int(add_out["bonus_805"]) == 7 + rec_mag_805,
		"additive bonus_805: want 7+%d=%d, got %d"
			% [rec_mag_805, 7 + rec_mag_805, int(add_out["bonus_805"])])

	# (4) The CHANNEL TRIPLES are exposed per-channel per-slot. SHIELD_KITE
	# record 168 carries 10 channels * 3 ints each -- exactly 30 chan_*
	# keys. They are additive ints; not interpreted as percentages.
	var chan_keys := 0
	for k in out.keys():
		if String(k).begins_with("chan_"):
			chan_keys += 1
	assert(chan_keys >= 30,
		"SHIELD_KITE modifiers should expose >= 30 chan_* keys, got %d" % chan_keys)
	for cn in Sacred.Wpmod.CHANNELS:
		for s in 3:
			var ck := "chan_%s_%d" % [cn, s]
			assert(out.has(ck),
				"missing %s; have %s" % [ck, out.keys()])
			assert(typeof(out[ck]) == TYPE_INT or typeof(out[ck]) == TYPE_FLOAT,
				"%s should be numeric, got %s" % [ck, typeof(out[ck])])

	# (5) The caller dict is NOT MUTATED.
	var fresh_seed := {"hit_points": 50, "armour": 3}
	var fresh_out := w.apply_to_item(SHIELD_KITE, fresh_seed)
	assert(fresh_seed.has("hit_points") and fresh_seed["hit_points"] == 50,
		"apply_to_item mutated caller stats: %s" % [fresh_seed])
	assert(fresh_seed.has("armour") and fresh_seed["armour"] == 3,
		"apply_to_item mutated caller stats: %s" % [fresh_seed])
	assert(fresh_out.has("hit_points") and fresh_out["hit_points"] == 50,
		"apply_to_item dropped hit_points from result: %s" % fresh_out)

	print("wpmod_apply_check OK keys=%d chan_keys=%d bonus=%d/%d/%d"
		% [out.size(), chan_keys, int(out["bonus_805"]),
			int(out["bonus_806"]), int(out["bonus_810"])])
	finish(0)


## Records naming SHIELD_KITE. Cheap wrapper so the additive test reads.
func recs_168(w) -> PackedInt32Array:
	return w.records_for_item(SHIELD_KITE)
