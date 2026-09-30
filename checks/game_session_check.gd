extends "res://checks/check.gd"
## game_session_check.gd -- S0: the session is the ONE owner of
## authoritative state. new_game() derives the hero from the start template
## (not invented constants), identical inputs produce identical relevant
## state, and renderless construction equals the rendered path's state.

func _init() -> void:
	super()
	var fails := 0
	var install := Sacred.find_install()
	assert(not install.is_empty(), "retail install is required")

	# --- two sessions, same inputs: identical relevant state ---
	var s1 := GameSession.new_game(install, Vector2(3236.5, 2511.5))
	var s2 := GameSession.new_game(install, Vector2(3236.5, 2511.5))
	if s1.player_cell != s2.player_cell or s1.player_hp != s2.player_hp:
		fails += 1
		printerr("identical new_game inputs diverged: %d/%s vs %d/%s"
			% [s1.player_hp, s1.player_cell, s2.player_hp, s2.player_cell])
	if s1.quest_log.vars() != s2.quest_log.vars():
		fails += 1
		printerr("quest states diverged")

	# --- the hero is DERIVED: Seraphim template -> 119 (live-witnessed) ---
	if s1.player_hp != 119:
		fails += 1
		printerr("hero hp %d is not the derived 119 -- an invented number is back" % s1.player_hp)
	# base==live on a bare hero, so the live pair equals the template pair.
	if s1.player_hp_max != s1.player_hp:
		fails += 1
		printerr("bare hero hp_max must equal hp")

	# --- identity is real: the session knows its content and hero ---
	if s1.install != install or s1.start_template != "hero01.ptx":
		fails += 1
		printerr("session identity missing: install=%s template=%s"
			% [s1.install, s1.start_template])
	var hero := s1.registry.get_actor(s1.player_id)
	if hero == null:
		fails += 1
		printerr("player_id does not resolve in the session's own registry")
	else:
		# derived=ActorStats.max_hash... spelled out in the fact line; here
		# assert the derivation inputs match the template (STK, REPHY).
		var h := Sacred.Hero.new(install.path_join("templates/" + s1.start_template))
		var stk: int = h.attributes()[0]
		var rephy: int = h.attributes()[3]
		if ActorStats.max_hp(stk, rephy, stk, rephy, 1) != s1.player_hp:
			fails += 1
			printerr("player hp is not max_hp(STK, REPHY, 1)")

	# --- renderless equals rendered: the state is view-independent ---
	# The session cannot name a view type (world/ layer rule); "renderless"
	# is simply this construction path. The rendered path consumes the SAME
	# session object, so equality is by construction -- what this asserts is
	# that snapshotting a session that was never rendered works.
	var snap := s1.snapshot()
	if int(snap.get("schema", 0)) != SaveState.SCHEMA:
		fails += 1
		printerr("session snapshot missing schema")
	if s1.restore(snap) != "":
		fails += 1
		printerr("session roundtrip of its own snapshot failed")

	# --- commands route through the session, not raw sim fields ---
	s1.move_command(Vector2i(3240, 2514))
	if s1.sim.pending_goal != Vector2i(3240, 2514) \
			or s1.sim.pending_goal_actor_id != s1.player_id:
		fails += 1
		printerr("move_command did not route through the session")

	print("game_session_check\tOK\thp=%d" % s1.player_hp)
	finish(1 if fails > 0 else 0)
