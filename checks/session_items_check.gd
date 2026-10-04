extends "res://checks/check.gd"
## session_items_check.gd -- C2 wiring: the session OWNS the item instances,
## pickup/drop go through the command door, and the save snapshot carries
## them with exact resolved profile identity. Ground items spawn at real cells; pickup moves the
## instance into the hero's inventory; drop puts it back on the ground at
## the hero's cell; the whole state roundtrips through SaveState.
const ModManifest := preload("res://formats/mod_manifest.gd")

func _init() -> void:
	super()
	var fails := 0
	var install := Sacred.find_install()
	assert(not install.is_empty(), "retail install is required")
	var profile := ModManifest.new(install)
	if not expect(Sacred.Pak.configure_profile(profile) == "", profile.error_text()):
		finish(1)
		return

	var s := GameSession.new_game(install, Vector2(3236.5, 2511.5))

	# --- ground spawn + pickup through the session door ---
	var iid := s.spawn_item_ground(4748, Vector2i(3238, 2512))
	var err := ""
	if iid <= 0:
		fails += 1
		printerr("ground spawn failed")
	else:
		err = s.pickup_item(iid)
		if err != "":
			fails += 1
			printerr("pickup failed: %s" % err)
		var inst := s.items.instance(iid)
		if inst == null or inst.location != ItemInstances.Location.INVENTORY \
				or inst.owner_id != s.player_id:
			fails += 1
			printerr("instance not in hero inventory after pickup")

	# --- pickup of an unknown/foreign instance is refused ---
	if s.pickup_item(999999) == "":
		fails += 1
		printerr("pickup of a nonexistent instance must fail")

	# --- drop puts it back on the ground at the hero's cell ---
	var hero := s.registry.get_actor(s.player_id)
	var drop_cell := Vector2i(int(hero.cell.x) + 1, int(hero.cell.y))
	err = s.drop_item(iid, drop_cell)
	if err != "":
		fails += 1
		printerr("drop failed: %s" % err)
	var inst2 := s.items.instance(iid)
	if inst2 == null or inst2.location != ItemInstances.Location.GROUND \
			or inst2.cell != drop_cell or inst2.owner_id != 0:
		fails += 1
		printerr("instance not back on the ground after drop: %s" % str(inst2.to_dict() if inst2 else {}))

	# --- profile-bound snapshot carries items; roundtrip preserves location ---
	var snap := s.snapshot()
	var arr: Array = snap.get("items", [])
	if arr.size() != s.items.count():
		fails += 1
		printerr("snapshot items array size mismatch")
	var s2 := GameSession.new_game(install, Vector2(3236.5, 2511.5))
	if s2.restore(snap) != "":
		fails += 1
		printerr("restore refused the matching-profile snapshot")
	var inst3 := s2.items.instance(iid)
	if inst3 == null or inst3.location != ItemInstances.Location.GROUND \
			or inst3.cell != drop_cell:
		fails += 1
		printerr("restored instance lost its ground state")

	print("session_items_check\tOK\tinstances=%d" % s.items.count())
	finish(1 if fails > 0 else 0)
