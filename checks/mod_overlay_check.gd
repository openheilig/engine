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
	var base_items := Sacred.Items.new(Sacred.Pak.new(src))

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
	# An install-like prefix is not a directory boundary.
	var sibling_path := install + "-backup/pak/items.pak"
	var misleading_mod := mod_root + "-backup/pak/items.pak"
	DirAccess.make_dir_recursive_absolute(misleading_mod.get_base_dir())
	var marker := FileAccess.open(misleading_mod, FileAccess.WRITE)
	marker.store_string("synthetic sibling marker")
	marker.close()
	expect(Sacred.Pak.resolve(sibling_path) == sibling_path,
		"an install-prefix sibling must not be redirected into the mod")

	Sacred.Pak.install_root = install + "/"
	expect(Sacred.Pak.resolve(src) == dst,
		"a trailing slash on the install root must not disable the overlay")
	Sacred.Pak.install_root = install

	# The reader reports provenance: open via the INSTALL path with the
	# overlay active and the mod serves it.
	var pk := Sacred.Pak.new(install.path_join("pak/items.pak"))
	expect(pk.is_open() and pk.from_mod, "the overlaid pak reports from_mod")
	expect(pk.path == dst, "the overlaid pak opens the mod copy")
	var base := Sacred.Pak.new(install.path_join("pak/sound.pak"))
	expect(base.is_open() and not base.from_mod, "the base pak reports not-from-mod")
	# Replacing items.pak alone must retain weapon-generated definitions:
	# weapon.pak is a logical sibling and may still live in the base install.
	var mod_items := Sacred.Items.new(pk)
	var changed_definitions := 0
	for type in base_items.record_count():
		if base_items.category_of(type) != mod_items.category_of(type) \
				or base_items.name_of(type) != mod_items.name_of(type) \
				or base_items.texture_of(type) != mod_items.texture_of(type):
			changed_definitions += 1
	expect(changed_definitions == 0,
		"items-only overlay must preserve base weapon inheritance (%d definitions changed)"
			% changed_definitions)


	Sacred.Pak.mod_root = ""
	Sacred.Pak.install_root = ""

	print("mod_overlay_check\tOK")
	finish(1 if fails > 0 else 0)
