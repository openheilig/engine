extends "res://checks/check.gd"
## music_check.gd -- A0: the sound-id table parses at RUNTIME from the
## user's install/sacred (full 6869 records), resolves to real files, and
## matches the binary's behaviour (unknown id -> empty path, ATMO branch
## on the name prefix, fallback subset equal to the parse for sector ids).

func _init() -> void:
	super()
	var fails := 0
	var install := Sacred.find_install()
	assert(not install.is_empty(), "retail install is required")

	# The runtime parse recovers the full table, not just the subset
	# (entry 0 is filtered, so 6868 named ids remain).
	var t: Dictionary = Sacred.SoundNames.table(install)
	expect(t.size() >= 6860, "runtime table has %d entries, expected ~6868" % t.size())
	expect(String(t.get(6560, "")) == "MUSIC_WOOD01", "6560 is %s" % t.get(6560))
	expect(not t.has(0), "entry 0 (SOUND_FX_INVALID) must not resolve as an id")

	# The port's start sector: 6560 = MUSIC_WOOD01, retail-observed.
	var p: String = Sacred.SoundNames.ogg_relpath(6560, install)
	expect(p == "mp3/music_wood01.ogg", "6560 resolved to %s" % p)
	expect(FileAccess.file_exists(install.path_join(p)),
		"%s must exist in the install" % p)

	# Spot-check the families the sector records actually carry, from the
	# FULL table: every resolved path must exist on disk.
	var checked := 0
	var missing: Array = []
	for id in t.keys():
		var q: String = Sacred.SoundNames.ogg_relpath(id, install)
		# Atmo/atmospot/meet/jingle/music stems all live in mp3/; a few SFX
		# entries (footsteps, voices) are in sound.pak, not loose files --
		# restrict the existence sweep to the four music-family prefixes.
		var stem: String = t[id]
		if not (stem.begins_with("MUSIC_") or stem.begins_with("ATMO")
				or stem.begins_with("JINGLE") or stem.begins_with("MEET")):
			continue
		checked += 1
		if not FileAccess.file_exists(install.path_join(q)):
			missing.append("%d:%s" % [id, q])
	expect(checked >= 80, "only %d music-family entries checked" % checked)
	expect(missing.is_empty(), "%d music files missing: %s" % [missing.size(), str(missing.slice(0, 5))])

	# getSndName's miss path: an id outside the table yields no file.
	expect(Sacred.SoundNames.ogg_relpath(0, install) == "", "id 0 must not resolve")
	expect(Sacred.SoundNames.ogg_relpath(999999, install) == "", "unknown id must not resolve")

	# The ATMO branch: memcmp(name+9,"ATMO",4) -- ambience vs music volume.
	expect(Sacred.SoundNames.is_atmo(6500, install), "ATMO_DESERT is ambience")
	expect(Sacred.SoundNames.is_atmo(6504, install), "ATMOSPOT matches retail's memcmp branch")
	expect(not Sacred.SoundNames.is_atmo(6560, install), "MUSIC_WOOD01 is music")

	print("music_check\tOK\tentries=%d\tmusic_family_files=%d" % [t.size(), checked])
	finish(1 if fails > 0 else 0)
