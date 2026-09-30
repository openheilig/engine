extends "res://checks/check.gd"
## sector_scheduler_check.gd -- S1: the sector-entry scheduler resolves the
## named Sector/Region procedures from the Seraphim's vectoren.bin and runs
## them through the real VM into a QuestCast. Retail's own log names
## Sector50039Init (sector 50,39 = the start cell 3236,2511) and its body is
## known: 6 CreateNPC (4x NOVIZIN, CHICKEN, RABBIT) + 4 CreateObj FX_FIRE_L
## + 1 SpawnValues (script-bytecode.md).

func _init() -> void:
	super()
	var fails := 0
	var install := Sacred.find_install()
	assert(not install.is_empty(), "retail install is required")

	var dir := install.path_join("bin/%s" % "type_npc_seraphim")
	var vec := Sacred.Vectoren.new(dir)
	assert(vec.found, "vectoren.bin not found")

	# Name-based procedure resolution.
	var init_proc: Dictionary = vec.procedure("Sector50039Init")
	expect(not init_proc.is_empty(), "Sector50039Init must resolve")
	expect(not vec.procedure("Sector50039Enter").is_empty(), "Sector50039Enter must resolve")
	# The 515-byte cast body (6 CreateNPC + 4 CreateObj + SpawnValues) is the
	# ENTER procedure (script-bytecode.md); Init is a 19-byte SpawnValues stub.
	expect(int(vec.procedure("Sector50039Enter").get("length", 0)) == 515,
		"Sector50039Enter length %d, expected 515"
			% int(vec.procedure("Sector50039Enter").get("length", 0)))
	expect(not vec.procedure("Region1Init").is_empty(), "Region1Init must resolve")
	expect(vec.procedure("Sector99999Init").is_empty(), "unknown procedure must not resolve")

	# Run the ENTER procedure (the 515-byte cast body) through the scheduler.
	var code := FileAccess.get_file_as_bytes(dir.path_join("funkcode.bin"))
	var vm := ScriptVM.new()
	var cast := QuestCast.new()
	var r: Dictionary = Sacred.SectorScheduler.run_proc(vec, code,
		"Sector50039Enter", cast, vm)
	expect(bool(r.get("ran", false)),
		"Sector50039Enter refused opcode %d" % vm.refused_op)
	var placed := cast.placed()
	expect(placed.size() == 6, "cast placed %d NPCs, expected 6" % placed.size())
	var noviz := 0
	var chicken := 0
	var rabbit := 0
	for p in placed:
		match int(p["creature"]):
			677: noviz += 1
			560: chicken += 1
			516: rabbit += 1
	expect(noviz == 4, "%d NOVIZIN placements, expected 4" % noviz)
	expect(chicken == 1 and rabbit == 1, "expected one CHICKEN and one RABBIT")
	# Every placement inside sector 50,39 (retail: all six are).
	for p in placed:
		var c: Vector2i = p["cell"]
		expect(c.x / 64 == 50 and c.y / 64 == 39,
			"placement %s outside sector 50,39" % c)

	# The scheduler helper itself: phase names for a sector/region.
	expect(Sacred.SectorScheduler.proc_name(50, 39, "Init") == "Sector50039Init",
		"proc name for 50,39 Init")
	expect(Sacred.SectorScheduler.proc_name(1, -1, "Enter", true) == "Region1Enter",
		"region proc name")

	print("sector_scheduler_check\tOK\tplaced=%d\tnoviz=%d" % [placed.size(), noviz])
	finish(1 if fails > 0 else 0)
