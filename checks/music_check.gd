extends "res://checks/check.gd"
## music_check.gd -- A0: the recovered sound-id table resolves to real
## files in the retail install, and the resolver matches the binary's
## behaviour (unknown id -> empty path, ATMO branch on the name prefix).

func _init() -> void:
	super()
	var fails := 0
	var install := Sacred.find_install()
	assert(not install.is_empty(), "retail install is required")

	# The port's start sector: 6560 = MUSIC_WOOD01, retail-observed.
	var p: String = Sacred.SoundNames.ogg_relpath(6560)
	expect(p == "mp3/music_wood01.ogg", "6560 resolved to %s" % p)
	expect(FileAccess.file_exists(install.path_join(p)),
		"%s must exist in the install" % p)

	# Spot-check the families the sector records actually carry.
	for id in [6500, 6511, 6530, 6550, 6700, 6717]:
		var q: String = Sacred.SoundNames.ogg_relpath(id)
		expect(q != "" and FileAccess.file_exists(install.path_join(q)),
			"id %d must resolve to an existing file (got %s)" % [id, q])

	# getSndName's miss path: an id outside the table yields no file.
	expect(Sacred.SoundNames.ogg_relpath(0) == "", "id 0 must not resolve")
	expect(Sacred.SoundNames.ogg_relpath(13282) == "", "untranscribed id must not resolve")

	# The ATMO branch: memcmp(name+9,"ATMO",4) -- ambience vs music volume.
	expect(Sacred.SoundNames.is_atmo(6500), "ATMO_DESERT is ambience")
	expect(Sacred.SoundNames.is_atmo(6504), "ATMOSPOT_CEMETERY matches retail's memcmp branch")
	expect(not Sacred.SoundNames.is_atmo(6560), "MUSIC_WOOD01 is music")

	print("music_check\tOK\tentries=%d" % Sacred.SoundNames.TABLE.size())
	finish(1 if fails > 0 else 0)
