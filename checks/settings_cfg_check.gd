extends "res://checks/check.gd"
## settings_cfg_check.gd -- U1: the retail per-user settings file parses
## (LF, "KEY : VALUE"), FULLSCREEN/SOUND semantics hold, and a missing file
## falls back cleanly.

func _init() -> void:
	super()
	var fails := 0

	# Write a synthetic retail-format config (the real one is the user's).
	var dir := "user://_settings_cfg_test"
	DirAccess.make_dir_recursive_absolute(dir)
	var p := dir.path_join("settings.cfg")
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_line("SOUND : 0")
	f.store_line("FULLSCREEN : 1")
	f.store_line("SOUNDQUALITY : 1")
	f.store_line("AUTOSAVE : 0")
	f.store_line("LOG : 1")
	f.close()

	var cfg: Sacred.SettingsCfg = Sacred.SettingsCfg.new(p)
	expect(cfg.found, "the config must parse")
	expect(cfg.values.size() == 5, "parsed %d keys, expected 5" % cfg.values.size())
	expect(cfg.wants_fullscreen(), "FULLSCREEN : 1 -> fullscreen")
	expect(not cfg.wants_sound(), "SOUND : 0 -> muted")
	expect(cfg.int_value("SOUNDQUALITY", 0) == 1, "SOUNDQUALITY reads")

	# The real one, if the user has it, must parse too (its VALUES are the
	# user's business and are not asserted).
	var real: Sacred.SettingsCfg = Sacred.SettingsCfg.new(
		OS.get_environment("HOME").path_join(".lgp/sacred/settings.cfg"))
	if real.found:
		expect(real.values.has("SOUND") or real.values.is_empty(),
			"the real config parses")

	# Missing file: clean fallback.
	var ghost: Sacred.SettingsCfg = Sacred.SettingsCfg.new(dir.path_join("nope.cfg"))
	expect(not ghost.found, "missing file not found")
	expect(ghost.wants_sound(), "missing file defaults sound ON")
	expect(not ghost.wants_fullscreen(), "missing file defaults windowed")

	print("settings_cfg_check\tOK")
	finish(1 if fails > 0 else 0)
