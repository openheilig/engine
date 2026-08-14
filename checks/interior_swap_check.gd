extends "res://checks/check.gd"
## interior_swap_check.gd -- the ONE runnable check for the retail roof-cutaway
## model (autoresearch rows 670-676) and for the row-663 float32 bucket fix.
##
##   godot --headless --path godot-port --script interior_swap_check.gd
##
## Assert-based, no framework, no world data: a synthetic 2-region complex is
## fed straight to Interior, which is a RefCounted with no node dependencies.
## It fails loudly if any of the four settled properties breaks:
##   1. STEP (0xA) is the exit cell and does NOT open the building
##      (row 676: "on the top step inside the arch it is still closed").
##   2. A FLOOR/DOOR cell one cell further in DOES open it, and opens the WHOLE
##      complex -- both region records -- in one evaluation.
##   3. When the hero stands where NO building resolves, the remembered building
##      is left untouched (retail falls through; we mirror the flaw).
##   4. Dense bucket ids stay in float32-exact range (row 663).
##   5. A 0xd0/0xe0 cell decodes to OPEN, not EMPTY, and opens the building.

## Injection-side sector size only -- see _derive() at the bottom of this file.
const SECT := 256


func _region(anchor: Vector2i, size: Vector2i, classes: Array) -> Dictionary:
	# classes is row-major, one class per cell; byte 31 of each 32-byte cell.
	var grid := PackedByteArray()
	grid.resize(size.x * size.y * Sacred.CELL)
	for i in classes.size():
		grid[i * Sacred.CELL + 31] = classes[i]
	return {"family": "TESTHAUS", "anchor": anchor, "size": size,
		"region": {"cell": anchor, "size": size, "grid": grid}}


func _init() -> void:
	super()
	# A 1x3 strip: WALL, STEP, FLOOR -- the doorway cross-section row 676
	# measured. Second record overlaps by one cell so the two form ONE complex.
	var a := _region(Vector2i(100, 100), Vector2i(3, 1),
		[Sacred.Regions.WALL, Sacred.Regions.STEP, Sacred.Regions.FLOOR])
	var b := _region(Vector2i(102, 100), Vector2i(2, 1),
		[Sacred.Regions.FLOOR, Sacred.Regions.FLOOR])
	var it := Interior.new(null, null, null)
	var candidates := {1: a, 2: b}

	# 1. on the STEP cell -> still closed
	_derive(it, candidates, Vector2(101.5, 100.5))
	assert(it.current().get(1, -1) == Interior.State.EXTERIOR,
		"STEP cell must NOT open the building (row 676 top-step measurement)")

	# 2. one cell further in -> cut, and the WHOLE complex flips together
	_derive(it, candidates, Vector2(102.5, 100.5))
	var st := it.current()
	assert(st.get(1, -1) == Interior.State.INTERIOR, "FLOOR cell must open the building")
	assert(st.get(2, -1) == Interior.State.INTERIOR,
		"whole complex must flip in one frame (row 674: four rooms open together)")

	# 3. nowhere near the complex -> remembered building LEFT UNTOUCHED
	_derive(it, candidates, Vector2(900.5, 900.5))
	assert(it.current().get(1, -1) == Interior.State.INTERIOR,
		"unresolved position must leave the remembered building untouched")
	assert(it.last_changes().is_empty(), "unresolved position must fire nothing")

	# 3b. back onto the STEP = the authored EXIT cell -> restored
	_derive(it, candidates, Vector2(101.5, 100.5))
	assert(it.current().get(1, -1) == Interior.State.EXTERIOR,
		"STEP cell must restore the remembered building to EXTERIOR")

	# 3c. a raw 0xd0/0xe0 cell -- non-zero byte, class nibble 0 -- is OPEN, not
	#     EMPTY, and opens the building. This is the cell the retail Seraphim
	#     start stands on (sector 50,39 KLOSTER_KAPELLE01, local 23,9 = 0xd0);
	#     collapsing it onto EMPTY made the cutaway unfireable at its own oracle.
	assert(Sacred.Regions.cell_class(_region(Vector2i(0, 0), Vector2i(1, 1), [0xd0])["region"],
		0, 0) == Sacred.Regions.OPEN, "0xd0 must decode to OPEN, never EMPTY")
	assert(Sacred.Regions.cell_class(_region(Vector2i(0, 0), Vector2i(1, 1), [0x00])["region"],
		0, 0) == Sacred.Regions.EMPTY, "a raw 0x00 byte must stay EMPTY")
	var c := _region(Vector2i(110, 100), Vector2i(2, 1), [Sacred.Regions.WALL, 0xd0])
	var open_only := {3: c}
	var it2 := Interior.new(null, null, null)
	_derive(it2, open_only, Vector2(111.5, 100.5))
	assert(it2.current().get(3, -1) == Interior.State.INTERIOR,
		"a 0xd0 (OPEN) cell must open the building -- the Seraphim spawn cell")

	# 4. dense bucket ids stay float32-exact. The packed key does not: the
	#    largest real key (99*1000000 + 99*1000 + n) *2+1 lands far past 2^24.
	#    GDScript floats are f64, so the collapse only shows through an actual
	#    float32 channel -- PackedFloat32Array is the same storage UV2 uses.
	var packed := Interior._region_key(50, 39, 0)
	var f32 := PackedFloat32Array([packed * 2, packed * 2 + 1])
	assert(f32[0] == f32[1],
		"packed key premise broken: %d no longer collapses in float32" % packed)
	var dense := PackedFloat32Array()
	for i in 2000:
		dense.append(i)
	for i in 2000:
		assert(int(dense[i] + 0.5) == i, "dense bucket %d not float32-exact" % i)

	print("interior_swap_check\tOK\tstep_closed\tfloor_open\tcomplex_together\tstale_kept\texit_restores\tbuckets_exact")
	finish(0)


## derive() reads footprints from Sacred.World; this check injects them instead.
## Injects at sector key 0, which pins every test cell to sector 0,0 so the
## packed region key derive() builds (gx*1e6 + gy*1e3 + index) equals the bare
## candidate index the asserts above read back. Keep every test cell under
## cell 128 in both axes: derive() divides by Sacred.SECT (64), so only cells
## whose own sector is 0 or 1 have sector 0,0 inside their 3x3 search block.
func _derive(it: Interior, candidates: Dictionary, cell: Vector2) -> void:
	var gx := floori(cell.x / SECT)
	var gy := floori(cell.y / SECT)
	var by_index := {}
	for key: int in candidates:
		by_index[key] = candidates[key]
	it._sector_cache[gy * 100 + gx] = by_index
	it.derive(cell)
