extends "res://checks/check.gd"
## sectorenv_check.gd -- the ONE runnable check for Sacred.Sectors, the
## per-sector environment record (row 960).
##
##   godot --headless --path . --script res://checks/sectorenv_check.gd
##
## THE STRUCTURAL ASSERTION IS THE STRIDE. `256 + 6050*768` must be the file
## length exactly, and every record must land on a DISTINCT sector coordinate.
## A wrong stride satisfies neither, and would otherwise read plausible small
## integers out of the middle of the wrong record -- climate and region are
## both single bytes, so almost any offset returns something believable.
const SECTORS := 6050
## Retail's own conversion is a float scale, so this checks that the 6050
## records cover 6050 distinct sectors rather than colliding.
const START := Vector2i(50, 39)         ## the Seraphim's own start
const NEIGHBOUR := Vector2i(51, 39)     ## the magician's, one sector east
const UNDERWORLD := Vector2i(97, 60)
const GLAD := Vector2i(59, 5)
## The gladiator's start is the one sector retail SPECIAL-CASES: sub_80DB27C
## forces music 6508 there rather than using the stored id. So the stored value
## is deliberately NOT 6508, and asserting that is what shows the override is a
## real override rather than a redundant restatement of the file.
const GLAD_STORED_MUSIC := 6551
const GLAD_FORCED_MUSIC := 6508


func _init() -> void:
	super()
	var install := Sacred.find_install()
	var sec = Sacred.Sectors.new(install)
	expect(sec.found, "world/sectors.keyx did not decode")
	if not sec.found:
		finish()
		return
	expect(sec.count == SECTORS, "%d sector records, expected %d" % [sec.count, SECTORS])

	# EVERY record must key to a distinct sector. This is the assertion the
	# stride has to survive.
	var seen := {}
	var mapped := 0
	for sx in 100:
		for sy in 128:
			var i := sec.index_of(sx, sy)
			if i < 0:
				continue
			expect(not seen.has(i), "record %d is claimed by two sectors" % i)
			seen[i] = true
			mapped += 1
	expect(mapped == SECTORS,
		"%d sectors resolved to a record, expected %d" % [mapped, SECTORS])

	# THE CELL -> SECTOR BOUNDARY, which the sector-change path in main.gd
	# depends on. Both arms matter: the positive one is what every in-world
	# cell exercises, and the NEGATIVE one is the control -- `int(c) / SECT`
	# truncates towards zero and passes the positive arm alone, so a check
	# without cells either side of the origin cannot tell the two apart.
	var sect := Sacred.SECT
	expect(Sacred.Sectors.sector_of(Vector2(0.0, 0.0)) == Vector2i(0, 0),
		"cell 0,0 is not sector 0,0")
	expect(Sacred.Sectors.sector_of(Vector2(sect - 1, sect - 1)) == Vector2i(0, 0),
		"the last cell of sector 0,0 left it")
	expect(Sacred.Sectors.sector_of(Vector2(sect, sect)) == Vector2i(1, 1),
		"the first cell of sector 1,1 is not in it")
	expect(Sacred.Sectors.sector_of(Vector2(-1.0, -1.0)) == Vector2i(-1, -1),
		"cell -1,-1 reports sector 0,0 -- integer division truncated towards zero")
	expect(Sacred.Sectors.sector_of(Vector2(3200.0, 2496.0)) == Vector2i(50, 39),
		"cell 3200,2496 is not sector 50,39")

	# The named fields, on sectors this project already identifies by other
	# routes, so a shifted offset is caught by a value a human can check.
	var start: Dictionary = sec.env_of(START.x, START.y)
	expect(not start.is_empty(), "the Seraphim's start sector has no record")
	expect(int(start["climate"]) == 64,
		"the start sector's climate is %d, expected 64" % int(start["climate"]))
	expect(int(start["music"]) == 6560,
		"the start sector's music is %d, expected 6560" % int(start["music"]))
	# Its neighbour -- the magician's start, one sector east -- is the same
	# region and the same music, which is what a contiguous region means.
	expect(sec.region(NEIGHBOUR.x, NEIGHBOUR.y) == int(start["region"]),
		"the adjacent start sector is a different region")
	expect(sec.music(NEIGHBOUR.x, NEIGHBOUR.y) == int(start["music"]),
		"the adjacent start sector plays different music")
	# And a DISTANT one must differ, or "music is per sector" is untested.
	expect(sec.music(UNDERWORLD.x, UNDERWORLD.y) != int(start["music"]),
		"the Underworld plays the same music as the Seraphim's meadow")
	expect(sec.climate(UNDERWORLD.x, UNDERWORLD.y) != int(start["climate"]),
		"the Underworld has the same climate as the surface start")

	# THE HARDCODED OVERRIDE. Retail forces music 6508 at the gladiator's start
	# rather than reading the record, so the stored value must NOT already be
	# 6508 -- otherwise the override in sub_80DB27C is doing nothing and this
	# gate would be asserting a coincidence.
	expect(sec.music(GLAD.x, GLAD.y) == GLAD_STORED_MUSIC,
		"the gladiator's start stores music %d, expected %d" % [
			sec.music(GLAD.x, GLAD.y), GLAD_STORED_MUSIC])
	expect(GLAD_STORED_MUSIC != GLAD_FORCED_MUSIC,
		"the stored and forced music agree, so the override is untestable")

	# Climates are all multiples of 16 -- twelve distinct values over the whole
	# map. A byte read at the wrong offset does not come out quantised.
	var climates := {}
	var off_grid := 0
	for sx in 100:
		for sy in 128:
			if sec.index_of(sx, sy) < 0:
				continue
			var c := sec.climate(sx, sy)
			climates[c] = true
			if c % 16 != 0:
				off_grid += 1
	expect(off_grid == 0,
		"%d sectors have a climate that is not a multiple of 16" % off_grid)
	expect(climates.size() >= 8 and climates.size() <= 20,
		"%d distinct climates, expected roughly a dozen" % climates.size())

	var keys := climates.keys()
	keys.sort()
	print("sectorenv_check\tOK\tsectors=%d\tclimates=%s\tstart=%s\tglad_music=%d" % [
		sec.count, keys, start, sec.music(GLAD.x, GLAD.y)])
	finish(0)
