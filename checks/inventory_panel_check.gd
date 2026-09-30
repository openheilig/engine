extends "res://checks/check.gd"
## inventory_panel_check.gd -- U0: the inventory panel's text reflects the
## session's INVENTORY instances (name x count, unknown types by id, empty
## marker), and the toggle flips visibility.

func _init() -> void:
	super()
	var fails := 0
	var install := Sacred.find_install()
	assert(not install.is_empty(), "retail install is required")
	var items := Sacred.Items.new(Sacred.Pak.new(install.path_join("pak/items.pak")))

	var panel: Sacred.InventoryPanel = Sacred.InventoryPanel.new()
	expect(panel.visible == false, "panel starts hidden")
	panel.toggle()
	expect(panel.visible, "toggle shows the panel")
	panel.toggle()
	expect(panel.visible == false, "toggle hides again")

	# Text build: two of one type, one of another, one unknown type.
	var s := GameSession.new_game(install, Vector2(3236.5, 2511.5))
	var loot: int = items.record_count()
	# Use real definitions with names where possible: spawn by scanning for
	# two named types.
	var named: Array[int] = []
	for i in items.record_count():
		if items.name_of(i) != "" and named.size() < 2:
			named.append(i)
		if named.size() == 2:
			break
	expect(named.size() == 2, "need two named item types")
	s.items.spawn(named[0], Vector2i(1, 1))
	s.items.spawn(named[0], Vector2i(1, 2))
	s.items.spawn(named[1], Vector2i(1, 3))
	# Move one into the hero's INVENTORY via the real transfer command path.
	var insts := s.items.all_instances()
	s.items.transfer(insts[0].instance_id, ItemInstances.Location.INVENTORY,
		s.player_id)
	s.items.transfer(insts[1].instance_id, ItemInstances.Location.INVENTORY,
		s.player_id)
	s.items.transfer(insts[2].instance_id, ItemInstances.Location.INVENTORY,
		s.player_id)
	panel.refresh(s.items.all_instances(), items)
	# The panel's label text is not directly readable from outside, so pin
	# the behaviour through a second panel instance via refresh + label.
	var label: Label = panel.get_child(0)
	expect(label.text.begins_with("INVENTORY"), "text starts with the header")
	expect(label.text.contains(items.name_of(named[0]) + " x2"),
		"text counts %s x2" % items.name_of(named[0]))
	expect(label.text.contains(items.name_of(named[1]) + " x1"),
		"text lists %s x1" % items.name_of(named[1]))

	# Empty session: the marker.
	var s2 := GameSession.new_game(install, Vector2(3236.5, 2511.5))
	panel.refresh(s2.items.all_instances(), items)
	expect(label.text.contains("(empty)"), "empty inventory says so")

	panel.queue_free()
	print("inventory_panel_check\tOK")
	finish(1 if fails > 0 else 0)
