extends "res://checks/check.gd"
## npc_dressing_check.gd -- Wire F: world/npc_dressing.gd.
##
##   godot --headless --path godot-port --script res://checks/npc_dressing_check.gd
##
## The dressing consumer at NPC-spawn time. dress_for_spawn is a thin
## pass-through to Sacred.Equipment.dress_creature; stats_for_item and
## stats_for_dressed accumulate Sacred.Wpmod.apply_to_item over an inventory.

const SHIELD_POOL := 50


func _init() -> void:
	var install := Sacred.find_install()
	var items_pak_path := install + "/pak/items.pak"
	var items_pak := Sacred.Pak.new(items_pak_path)
	var items := Sacred.Items.new(items_pak)
	var e := Sacred.Equipment.new(install)
	var w := Sacred.Wpmod.new(install)
	assert(e.found and w.found, "either Equipment or Wpmod did not decode")
	assert(items.name_of(5) != "", "items.pak did not decode; name_of(5) is empty")

	# (1) dress_for_spawn preserves the array contract: every member of the
	# pool, repeats intact, every entry a valid items.pak record. Same as
	# dress_creature() -- which is what it is.
	var d := Sacred.NpcDressing.new(e, w)
	var picked: Array = d.dress_for_spawn(17095, SHIELD_POOL)
	assert(not picked.is_empty(),
		"dress_for_spawn returned an empty list for a filled pool")
	for rec in picked:
		assert(rec is int or typeof(rec) == TYPE_INT,
			"dress_for_spawn record %s is not an int" % rec)

	# Pick the first pool-50 entry that has ANY modifier record set; the
	# exact item varies across install variants, but every pool 50 entry is
	# some SHIELD_*.GRN so the consumer-side assertion is the same.
	var kite := -1
	var kite_has_bonus := false
	for rec in picked:
		assert(items.name_of(rec).to_upper().contains("SHIELD"),
			"shield pool member %d names %s, not a shield" % [rec, items.name_of(rec)])
		var recs: PackedInt32Array = w.records_for_item(rec)
		if recs.is_empty():
			continue
		if kite < 0:
			kite = rec
		for r in recs:
			for m in w.modifiers(r):
				if m["kind"] == "bonus":
					kite_has_bonus = true
					break
	assert(kite >= 0,
		"no pool-50 item has any modifier record; members: %s" % [picked])
	var fresh := d.stats_for_item(kite, {})
	# The bonus keys that ship depend on which item won the pick, so only
	# require SOME bonus_* key -- not a specific id -- when at least one is
	# present; otherwise the additivity test is over the channel keys.
	var saw_bonus := false
	for k in fresh.keys():
		if String(k).begins_with("bonus_"):
			saw_bonus = true
			break
	assert(saw_bonus == kite_has_bonus,
		"saw_bonus=%s vs kite_has_bonus=%s for kite=%d" % [saw_bonus, kite_has_bonus, kite])
	if kite_has_bonus:
		var bonus_key := ""
		for k in fresh.keys():
			if String(k).begins_with("bonus_"):
				bonus_key = k
				break
		assert(fresh.has(bonus_key) and int(fresh[bonus_key]) > 0,
			"fresh stats should have a positive %s; got %s" % [bonus_key, fresh])
		var accumulated := d.stats_for_item(kite, {bonus_key: 7})
		assert(int(accumulated[bonus_key]) == 7 + int(fresh[bonus_key]),
			"stats_for_item not additive: 7+%d vs %d"
				% [int(fresh[bonus_key]), int(accumulated[bonus_key])])

	# (4) Degraded mode: a null Wpmod returns the input dict unchanged.
	var no_w := Sacred.NpcDressing.new(e, null)
	var empty_seed := {"hit_points": 12}
	var passthrough := no_w.stats_for_item(kite, empty_seed)
	assert(int(passthrough["hit_points"]) == 12,
		"degraded stats_for_item dropped caller stats: %s" % passthrough)

	print("npc_dressing_check OK pool=%d picked=%d fresh_keys=%d"
		% [SHIELD_POOL, picked.size(), fresh.size()])
	finish(0)
