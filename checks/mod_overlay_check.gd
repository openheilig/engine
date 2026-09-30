extends "res://checks/check.gd"
## mod_overlay_check.gd -- D1: a data mod is a directory of replaced pak
## files overlaid by relative path. resolve() serves the mod copy for
## install-suffixed paths that exist there, and Pak.from_mod reports it.

func _init() -> void:
	super()
	var fails := 0
	var install := Sacred.find_install()
	assert(not install.is_empty(), "retail install is required")

	# Build a mod dir with ONE replaced file: a copy of items.pak under a
	# temp mod root (user:// -- nothing derived ships).
	var mod_root := "user://_mod_overlay_test/mod"
	DirAccess.make_dir_recursive_absolute(mod_root.path_join("pak"))
	var src := install.path_join("pak/items.pak")
	var dst := mod_root.path_join("pak/items.pak")
	if FileAccess.file_exists(dst):
		DirAccess.remove_absolute(dst)
	var co := FileAccess.open(dst, FileAccess.WRITE)
	var ci := FileAccess.open(src, FileAccess.READ)
	assert(co != null and ci != null)
	co.store_buffer(ci.get_buffer(ci.get_length()))
	co.close()
	ci.close()

	# The overlay serves the mod copy for install-suffixed paths.
	Sacred.Pak.install_root = install
	Sacred.Pak.mod_root = mod_root
	var resolved: String = Sacred.Pak.resolve(install.path_join("pak/items.pak"))
	expect(resolved == dst, "resolve must serve the mod copy")
	expect(resolved != install.path_join("pak/items.pak"), "resolve must not serve the original")

	# A file the mod does not carry falls through to the install.
	var untouched: String = Sacred.Pak.resolve(install.path_join("pak/tiles.pak"))
	expect(untouched == install.path_join("pak/tiles.pak"), "untouched file falls through")

	# A path outside the install root never overlays.
	expect(Sacred.Pak.resolve("/etc/hostname") == "/etc/hostname", "foreign paths untouched")

	# The reader reports provenance: open via the INSTALL path with the
	# overlay active and the mod serves it.
	var pk := Sacred.Pak.new(install.path_join("pak/items.pak"))
	expect(pk.is_open() and pk.from_mod, "the overlaid pak reports from_mod")
	expect(pk.path == dst, "the overlaid pak opens the mod copy")
	var base := Sacred.Pak.new(install.path_join("pak/sound.pak"))
	expect(base.is_open() and not base.from_mod, "the base pak reports not-from-mod")

	# Same bytes through the overlay: the mod copy is a copy.
	var a := pk.blob(1)
	var orig := Sacred.Pak.new(src)
	var b := orig.blob(1)
	expect(a == b, "overlay bytes must equal the copied source bytes")

	Sacred.Pak.mod_root = ""
	Sacred.Pak.install_root = ""

	print("mod_overlay_check\tOK")
	finish(1 if fails > 0 else 0)
