extends SceneTree
## R0 acceptance, E1-wave gate: the profile reader must accept the real LGP
## tree, refuse a bogus root with a precise reason, classify a Windows-mixed
## layout by probing (created in a temp dir), and never silently pick a
## case-fold collision.

func _init() -> void:
	var fails := 0
	# 1. the real install
	var real := InstallProfile.probe("/home/rlinev/Projects/openheilig/donotpublish/install")
	if real.errors.is_empty() and real.family == InstallProfile.Family.LGP_LINUX \
			and real.layout == InstallProfile.Layout.LOWERCASE \
			and real.executable_format == "elf32":
		print("ok\treal LGP tree: family=lgp_linux layout=lowercase exe=elf32")
	else:
		fails += 1
		printerr("FAIL real tree: fam=%d layout=%d exe=%s errors=%s"
			% [real.family, real.layout, real.executable_format, real.error_text()])
	# 2. a nonexistent root
	var ghost := InstallProfile.probe("/nonexistent/openheilig-probe")
	if not ghost.errors.is_empty() and not ghost.ok():
		print("ok\tmissing root refused: %s" % ghost.error_text().split("\n")[0])
	else:
		fails += 1
		printerr("FAIL ghost root accepted")
	# 3. a mixed-case tree in a temp dir: PAK/, WORLD/ uppercase copies.
	# A PREVIOUS RUN of this check leaves its step-4 lowercase dirs behind,
	# which would turn this run's step 3 into a collision case -- so the
	# scratch tree is removed, not reused.
	var tmp := "/tmp/openheilig-r0-mixed"
	OS.move_to_trash(tmp)   # best effort; a non-empty stale tree must go
	DirAccess.remove_absolute(tmp)
	DirAccess.make_dir_recursive_absolute(tmp + "/PAK")
	DirAccess.make_dir_recursive_absolute(tmp + "/WORLD")
	FileAccess.open(tmp + "/PAK/TILES.PAK", FileAccess.WRITE).close()
	FileAccess.open(tmp + "/WORLD/SECTORS.WLDX", FileAccess.WRITE).close()
	var mixed := InstallProfile.probe(tmp)
	if mixed.layout == InstallProfile.Layout.MIXED \
			and mixed.family == InstallProfile.Family.WINDOWS_GOLD \
			and mixed.errors.is_empty() \
			and not mixed.capability_gaps.is_empty():
		print("ok\tmixed tree: family=windows_gold gaps=%d" % mixed.capability_gaps.size())
	else:
		fails += 1
		printerr("FAIL mixed tree: fam=%d layout=%d gaps=%s errors=%s"
			% [mixed.family, mixed.layout, mixed.capability_gaps, mixed.error_text()])
	# 4. a collision: both pak/ and PAK/ exist with both files
	DirAccess.make_dir_recursive_absolute(tmp + "/pak")
	DirAccess.make_dir_recursive_absolute(tmp + "/world")
	FileAccess.open(tmp + "/pak/tiles.pak", FileAccess.WRITE).close()
	FileAccess.open(tmp + "/world/sectors.wldx", FileAccess.WRITE).close()
	var coll := InstallProfile.probe(tmp)
	if not coll.ok() and coll.error_text().contains("collision"):
		print("ok\tcase-fold collision refused: %s" % coll.error_text().split("\n")[0])
	else:
		fails += 1
		printerr("FAIL collision accepted: layout=%d ok=%s errors=%s" % [coll.layout, coll.ok(), coll.error_text()])
	# 5. an explicit --install refusal is sacred.gd's job; here just confirm
	# the probe alone refuses an empty dir (no files at all)
	DirAccess.make_dir_recursive_absolute("/tmp/openheilig-r0-empty")
	var empty := InstallProfile.probe("/tmp/openheilig-r0-empty")
	if not empty.ok() and empty.error_text().contains("tiles.pak"):
		print("ok\tempty root refused with tiles.pak reason")
	else:
		fails += 1
		printerr("FAIL empty root: ok=%s errors=%s" % [empty.ok(), empty.error_text()])
	print("PASS=%d FAIL=%d" % [5 - fails, fails])
	quit(1 if fails > 0 else 0)
