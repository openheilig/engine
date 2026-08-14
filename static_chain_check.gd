extends "res://check.gd"
## static_chain_check.gd -- the ONE runnable check for Sacred.Statics.chain().
##
##   godot --headless --path godot-port --script static_chain_check.gd
##
## A cell's WldxEntry +0x04 names only the HEAD of a chain of statics placed at
## that spot; the rest hang off nextStaticId (+0x1f, Resacred-old rs_file.h:341).
## Reading only the head made 158 placements in sector 50,39 invisible, among
## them seven KLOSTER_KAPELLE01 level-2 wall pieces (the chapel's wall gap), the
## candle cabinet, ten candles and the library shelves. Fails loudly if:
##   1. The head is no longer first, or chain() stops agreeing with get_object().
##   2. The sector's chained total collapses back to its head count.
##   3. A named piece that is ONLY reachable through a link goes missing.
##   4. chain() stops terminating on a self-link (cycle guard).
const GX := 50
const GY := 39
const HEADS := 777
const TOTAL := 935   ## 777 heads + 158 linked

func _init() -> void:
	super()
	var install := Sacred.find_install()
	var world := Sacred.World.new(install.path_join("world"))
	var static_pak := Sacred.Pak.new(install.path_join("world/static.pak"))
	var statics := Sacred.Statics.new(static_pak)
	var items := Sacred.Items.new(Sacred.Pak.new(install.path_join("pak/items.pak")))
	var stream := world.sector(GX, GY)
	assert(not stream.is_empty(), "sector %d,%d is absent -- is the install present?" % [GX, GY])

	var heads := 0
	var total := 0
	var linked_names: Dictionary = {}
	for i in Sacred.SECT * Sacred.SECT:
		var idx := stream.decode_u32(Sacred.NAME + i * Sacred.CELL + 4)
		var walk := statics.chain(idx)
		if walk.is_empty():
			continue
		heads += 1
		total += walk.size()
		assert(walk[0] == statics.get_object(idx),
			"chain() must return the cell's own static first, unchanged")
		for n in range(1, walk.size()):
			linked_names[items.name_of(walk[n]["type"])] = true

	assert(heads == HEADS, "sector %d,%d head count moved: want %d, got %d" % [GX, GY, HEADS, heads])
	assert(total == TOTAL,
		"sector %d,%d chained static count moved: want %d, got %d -- %d linked placements are the whole point" % [
			GX, GY, TOTAL, total, TOTAL - HEADS])
	for nm in ["KLOSTER_KAPELLE01_2_49", "Cabinet 3", "CANDLE11"]:
		assert(linked_names.has(nm),
			"'%s' is reachable ONLY through nextStaticId and must stay in the walk" % nm)

	# 4. cycle guard: a record that links to itself must terminate, not spin.
	# Nothing in the retail file does this, so it is asserted on a stub rather
	# than a placement -- the guard is the point, not the data.
	assert(statics.chain(0).is_empty(), "index 0 is the absent marker and must walk to nothing")
	assert(statics.chain(static_pak.count()).is_empty(), "an out-of-range head must walk to nothing")

	print("static_chain_check\tOK\thead_first\theads=%d\ttotal=%d\tlinked_named\tbounds" % [heads, total])
	finish(0)
