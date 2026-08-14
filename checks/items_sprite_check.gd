extends "res://checks/check.gd"
## items_sprite_check.gd -- the ONE runnable check for the static -> art
## indirection: static.pak +0x04 is an items.pak RECORD index, and the
## mixed.pak sprite id is that record's +0x10 field (Sacred.Items.sprite_of).
##
##   godot --headless --path godot-port --script items_sprite_check.gd
##
## Reads the retail install, because the whole point is that the two id spaces
## diverge in the real data. It fails loudly if:
##   1. sprite_of() stops resolving a record whose two ids DIVERGE (record 9223
##      "Chair 2" -> sprite 655) -- the chapel-furniture case. Drawing
##      Mixed.sprite(9223) directly yields nothing, which is the bug this
##      check exists to catch.
##   2. sprite_of() stops resolving a record whose two ids COINCIDE
##      (KLOSTER_KAPELLE01_2_61 at 24233) -- the case that masked the bug.
##   3. Items' name/level maps stop being keyed by RECORD index.

func _init() -> void:
	super()
	var install := Sacred.find_install()
	var items_pak := Sacred.Pak.new(install.path_join("pak/items.pak"))
	var mixed := Sacred.Mixed.new(Sacred.Pak.new(install.path_join("pak/mixed.pak")))
	var items := Sacred.Items.new(items_pak)
	assert(items_pak.is_open(), "items.pak did not open -- is the install present?")

	# 1. diverging ids: the furniture library
	assert(items.name_of(9223) == "Chair 2",
		"Items maps must be keyed by items.pak RECORD index (9223 = Chair 2), got '%s'" % items.name_of(9223))
	assert(items.sprite_of(9223) == 655,
		"record 9223 must resolve to sprite 655, got %d" % items.sprite_of(9223))
	assert(mixed.sprite(9223).is_empty(),
		"premise broken: mixed.pak 9223 now has art, so this record no longer proves the indirection")
	assert(not mixed.sprite(items.sprite_of(9223)).is_empty(),
		"the resolved sprite must have art -- otherwise the chapel furniture draws nothing")

	# 2. coinciding ids: the building parts that worked before the fix
	assert(items.sprite_of(24233) == 24233,
		"record 24233 must resolve to sprite 24233, got %d" % items.sprite_of(24233))
	assert(items.name_of(24233) == "KLOSTER_KAPELLE01_2_61",
		"record 24233 name lost: '%s'" % items.name_of(24233))
	assert(items.levels(24233) != 0 and items.is_top_level(24233),
		"levels/is_top_level must still answer by record index for building parts")

	# 3. a record with no sprite resolves to 0 (an invisible marker), never to
	#    the record index -- Mixed.sprite(0) is empty, which is what it must draw.
	assert(items.sprite_of(1035) == 0, "record 1035 (MiniObjTex2) must resolve to sprite 0")
	assert(items.sprite_of(-1) == 0, "an absent record must resolve to 0, not error")

	print("items_sprite_check\tOK\tdiverging\tcoinciding\tno_sprite\tabsent")
	finish(0)
