extends "res://checks/check.gd"
## campaign_check.gd -- G2: the Underworld campaign's class data lives under
## bin/addon/<class>, and its startcode start is cell 6265,3864 for every
## class (the retail fingerprint). The sector there must exist on the map.

func _init() -> void:
	super()
	var fails := 0
	var install := Sacred.find_install()
	assert(not install.is_empty(), "retail install is required")

	for cls in ["type_npc_zwerg", "type_npc_seraphim", "type_npc_daemonin"]:
		var sc := Sacred.Startcode.new(install.path_join("bin/addon").path_join(cls))
		expect(sc.start_cell == Vector2i(6265, 3864),
			"%s Underworld start %s != 6265,3864" % [cls, sc.start_cell])

	# The start sector exists in the world map (the Underworld is part of
	# the same 100x100 grid).
	var world := Sacred.World.new(install.path_join("world"))
	var sectors := Sacred.Sectors.new(install)
	var env: Dictionary = sectors.env_of(6265 / 64, 3864 / 64)
	expect(not env.is_empty(), "the Underworld start sector must be on the map")
	if not env.is_empty():
		print("underworld start sector env: music=%d climate=%d region=%d"
			% [int(env["music"]), int(env["climate"]), int(env["region"])])

	print("campaign_check\tOK")
	finish(1 if fails > 0 else 0)
