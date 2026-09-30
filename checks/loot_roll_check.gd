extends "res://checks/check.gd"
## loot_roll_check.gd -- E2: the transcribed kill→loot roll produces valid
## items.pak definition ids, respects the balance.bin chances, and the
## first-kill unique table reads from the user's binary (123 entries).

func _init() -> void:
	super()
	var fails := 0
	var install := Sacred.find_install()
	assert(not install.is_empty(), "retail install is required")
	var items := Sacred.Items.new(Sacred.Pak.new(install.path_join("pak/items.pak")))
	var balance := Sacred.Balance.new(install)

	# The shipped chances the executable binds (balance-keymap.tsv).
	expect(balance.i32(Sacred.LootRoll.OFF_DROP_GOLD, -1) == 300, "DropGold must read 300")
	expect(balance.i32(Sacred.LootRoll.OFF_DROP_WAFFE, -1) == 330, "DropWaffe must read 330")
	expect(balance.i32(Sacred.LootRoll.OFF_DROP_RUESTUNG, -1) == 880, "DropRuestung must read 880")
	expect(balance.i32(Sacred.LootRoll.OFF_DROP_SAFT, -1) == 180, "DropSaft must read 180")

	# Gold tiers are exact ids, not rolls.
	expect(Sacred.LootRoll.gold_item(2) == 5132, "level 2 drops the 5132 pile")
	expect(Sacred.LootRoll.gold_item(7) == 5133, "level 7 drops the 5133 pile")
	expect(Sacred.LootRoll.gold_item(15) == 5134, "level 15 drops the 5134 pile")
	expect(Sacred.LootRoll.gold_item(25) == 5135, "level 25 drops the 5135 pile")

	# First-kill unique table: 123 entries from the binary, all valid ids.
	var uniques := Sacred.LootRoll.unique_table()
	expect(uniques.size() == 123,
		"unique table has %d entries, expected 123" % uniques.size())
	var bad := 0
	for id in uniques:
		if id <= 0 or id >= items.record_count():
			bad += 1
	expect(bad == 0, "%d unique-table ids are not valid items.pak records" % bad)

	# Distribution: the GHUL is class 5, level 2. Over many rolls, no
	# returned id may be invalid, and the gold tier must appear.
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260930
	var gold := 0
	var invalid := 0
	var weapon := 0
	var rolls := 2000
	for i in rolls:
		var id := Sacred.LootRoll.roll(items, balance, 5, 2, rng, false)
		if id == 0:
			continue
		if id == 5132:
			gold += 1
		if id == 5 or items.category_of(id) == 5:
			weapon += 1
		if items.category_of(id) < 0:
			invalid += 1
	expect(invalid == 0, "%d of %d rolls produced invalid definition ids" % [invalid, rolls])
	# ~82% reach the loot arm; ~30% of those are gold. A tight bound would
	# re-derive retail's RNG; the sanity bound just proves the arm is live.
	expect(gold > 50, "gold tier appeared %d/%d times -- gold arm dead" % [gold, rolls])
	expect(weapon > 50, "weapon category appeared %d/%d times -- weapon arm dead" % [weapon, rolls])

	# The level window (E2-followup): weapon.pak-backed categories filter by
	# the row's +148/+153 levels. At creature level 2 the window top is tiny,
	# so a tier-8 weapon (Kampfstab row: 8/12) must never be picked.
	var weapons := Sacred.Weapons.new(install.path_join("pak/weapon.pak"))
	var kstab: int = weapons.row_for_type(2015)
	expect(kstab >= 0 and weapons.req_level(kstab) == 8 and weapons.item_level(kstab) == 12,
		"Kampfstab row levels %d/%d, expected 8/12"
			% [weapons.req_level(kstab), weapons.item_level(kstab)])
	var high := 0
	for i in 400:
		var wid: int = Sacred.LootRoll.pick_category(items, 5, rng, weapons, 2, 1)
		var wrow: int = weapons.row_for_type(wid) if wid > 0 else -1
		if wrow >= 0 and (weapons.item_level(wrow) >= 12 or weapons.req_level(wrow) >= 8):
			high += 1
	expect(high == 0, "%d/400 level-2 weapon picks exceed the window" % high)

	# First-of-type roll always returns a unique-table member.
	var uid := Sacred.LootRoll.roll(items, balance, 5, 2, rng, true)
	expect(uniques.has(uid), "first-of-type roll returned %d, not in the unique table" % uid)

	print("loot_roll_check\tOK\trolls=%d\tgold=%d\tweapon=%d\tuniques=%d"
		% [rolls, gold, weapon, uniques.size()])
	finish(1 if fails > 0 else 0)
