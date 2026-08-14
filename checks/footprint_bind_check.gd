extends "res://checks/check.gd"
## footprint_bind_check.gd -- the ONE runnable check for what may bind to a
## building footprint, i.e. what the roof-cutaway swap is allowed to hide.
##
##   godot --headless --path godot-port --script footprint_bind_check.gd
##
## Reads the retail install at sector 50,39 (KLOSTER_KAPELLE01, one region:
## anchor 3213,2502 size 34x30) because the rule only matters against real
## placements. It fails loudly if:
##   1. An UNLEVELLED piece outside every rect binds to a region. That is
##      _footprint_membership pass 2 with no family to bound it, and it used to
##      put a tree stand 22 cells west of the chapel into the chapel's INTERIOR
##      bucket -- so the whole grove vanished whenever the building was
##      exterior, which is nearly always.
##   2. A LEVELLED piece outside the rect STOPS binding. Pass 2 exists for
##      exactly this (overhang, inter-footprint gaps) and must keep working.
##   3. A piece inside the rect stops binding. That is pass 1.
const GX := 50
const GY := 39
const REGION_KEY := 50039000

func _init() -> void:
	super()
	var install := Sacred.find_install()
	var world := Sacred.World.new(install.path_join("world"))
	var statics := Sacred.Statics.new(Sacred.Pak.new(install.path_join("world/static.pak")))
	var items := Sacred.Items.new(Sacred.Pak.new(install.path_join("pak/items.pak")))
	var footprints := Sacred.Footprints.new(statics, items)
	var stream := world.sector(GX, GY)
	assert(not stream.is_empty(), "sector %d,%d is absent -- is the install present?" % [GX, GY])
	var regions := Sacred.Regions.new(stream, GX, GY)
	var view := SectorView.new()
	view._items = items
	view._world = world
	view._statics = statics
	view._footprints = footprints

	# Every object of the sector, by type, so the cases below use real placements.
	var by_type: Dictionary = {}
	for i in Sacred.SECT * Sacred.SECT:
		var o := statics.get_object(stream.decode_u32(Sacred.NAME + i * Sacred.CELL + 4))
		if not o.is_empty():
			by_type[o["type"]] = o

	# 1. unlevelled, outside every rect: "CW_Tree 34(B)" at cell (3191,2505)
	_expect(view, by_type, regions, footprints, 8901, -1,
		"an unlevelled piece outside every footprint must bind to NO region")
	# 2. levelled, outside the rect (cell 3222,2493 is 9 cells north of it)
	_expect(view, by_type, regions, footprints, 24182, REGION_KEY,
		"pass 2 must still bind a levelled piece overhanging its own footprint")
	# 3. levelled, inside the rect (cell 3239,2517)
	_expect(view, by_type, regions, footprints, 24233, REGION_KEY,
		"pass 1 must still bind a piece inside the rect")

	print("footprint_bind_check\tOK\tunlevelled_unbound\toverhang_bound\tinside_bound")
	view.free()
	finish(0)


func _expect(view: SectorView, by_type: Dictionary, regions: Sacred.Regions,
		footprints: Sacred.Footprints, sid: int, want_key: int, why: String) -> void:
	assert(by_type.has(sid), "sector %d,%d no longer places type %d -- pick a new sample" % [GX, GY, sid])
	var o: Dictionary = by_type[sid]
	var res := view._classify_object(o, o["pos"], GX, GY, regions, footprints)
	var got: int = int(res["region_key"])
	assert(got == want_key, "%s (type %d '%s' at cell %s: want region_key %d, got %d, class %s)" % [
		why, sid, view._items.name_of(sid), Sacred.Footprints._object_cell(o["pos"]),
		want_key, got, res["class"]])
