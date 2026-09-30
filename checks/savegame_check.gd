extends "res://checks/check.gd"
## savegame_check.gd -- X1: the retail world-savegame container reads --
## "AMS" + u8 version(27), section index at 0x100, and the shipped
## game01.pak's section sizes match the recovered map exactly
## (tmp/x1-saves/notes.md). The per-section decoders are the named next
## step; this pins the container and the index.

func _init() -> void:
	super()
	var fails := 0
	var install := Sacred.find_install()
	assert(not install.is_empty(), "retail install is required")

	var sg: Sacred.Savegame = Sacred.Savegame.new(install.path_join("save/game01.pak"))
	expect(sg.found, "the retail savegame must open")
	expect(sg.version == 27, "save version %d, expected 27" % sg.version)
	expect(sg.sections.size() == 20, "%d sections, expected 20" % sg.sections.size())

	# The recovered map, byte for byte (id -> size).
	const WANT := {
		0x80: 64, 0x81: 991741, 0x8B: 34, 0x94: 0x8010C, 0x99: 0x1808,
		0x9A: 0x144, 0xA0: 0x102D02, 0x8D: 0x22C05, 0xA2: 0x1FD36,
		0x82: 16, 0xA1: 0x77B901, 0x9C: 0x40, 0xC3: 556,
	}
	for id: int in WANT:
		var where: Vector2i = sg.sections.get(id, Vector2i.ZERO)
		expect(where.y == int(WANT[id]),
			"section 0x%02x size %d, expected %d" % [id, where.y, WANT[id]])

	# Section access reads bytes: the hero blob starts with the sentinel-
	# adjacent structure; just verify non-zero content and length.
	var blob: PackedByteArray = sg.section(Sacred.Savegame.SEC_HERO_BLOB)
	expect(blob.size() == 556 and blob.count(0) < blob.size(),
		"the hero blob must carry content")

	# A nonexistent section reads empty.
	expect(sg.section(0x77).is_empty(), "unknown section reads empty")

	print("savegame_check\tOK\tsections=%d\tversion=%d" % [sg.sections.size(), sg.version])
	finish(1 if fails > 0 else 0)
