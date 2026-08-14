extends "res://checks/check.gd"
## 04-REVIEW CR-01 regression check: a goal request aimed at a numbered tick
## must fire on THAT tick, even when Sim.advance() runs several ticks in one
## call (a catch-up burst after a slow frame).
##
## Why this file exists rather than a comment claiming the bug is fixed.
## main.gd used to decide, BEFORE calling advance(), whether the tick about to
## run was the goal tick (`pre_tick + 1 == GOAL_REQUEST_TICK`). advance() runs
## up to MAX_CATCHUP_TICKS ticks per call, so when the goal tick landed second
## or later in a burst that test failed and the goal was applied ZERO times --
## while the recorder, which range-tests every tick it actually ran, still
## wrote the goal line. Replay then applied a goal the live run never did, and
## the project's only determinism gate reported a divergence that was not a
## simulation error at all.
##
## The check below is a PAIR, not a single assertion, because a single one
## could pass for the wrong reason:
##
##   ARM 1 (the fix)      pending_goal_tick = N, with N landing SECOND in a
##                        3-tick burst. The goal must fire on tick N exactly.
##   ARM 2 (the control)  the same request with pending_goal_tick left at -1,
##                        the "next tick, whichever it is" contract Replay
##                        relies on. The goal must fire on the FIRST tick of
##                        the burst -- which is what the old code did on every
##                        path, and is exactly the wrong tick when the caller
##                        meant N. ARM 2 failing to differ from ARM 1 would
##                        mean this check cannot tell the two apart, so it
##                        would be proving nothing.
##
## Run: godot --headless --path godot-port --script res://checks/goaltick_check.gd
## Exits 0 on pass, 1 on failure, and prints one tab-separated fact line per
## arm in the house format.

const BURST_TICKS := 3
const GOAL_AT_OFFSET := 2   ## goal tick is the 2nd of the burst, never the 1st

var _fired_on := -1


func _init() -> void:
	super()
	var install := Sacred.find_install()
	if install == "":
		printerr("goaltick_check: no install found; pass --install=/path/to/install")
		finish(1)
		return
	var world := Sacred.World.new(install.path_join("world"))
	if not world.is_open():
		printerr("goaltick_check: cannot open world")
		finish(1)
		return

	var walk := Walkable.new(world)
	# A spawn cell that is genuinely walkable, found the same way the real run
	# finds it -- a hardcoded cell would rot the moment the allowlist changes.
	var spawn := _any_walkable(walk)
	if spawn == Vector2i(-1, -1):
		printerr("goaltick_check: no walkable cell found in the sampled sectors")
		finish(1)
		return

	var ok := true
	ok = _arm("numbered", walk, spawn, true) and ok
	ok = _arm("next-tick", walk, spawn, false) and ok

	if ok:
		print("goaltick_check\toverall verdict=PASS")
		finish(0)
	else:
		print("goaltick_check\toverall verdict=FAIL")
		finish(1)


## Runs one burst and reports which tick the goal actually fired on.
## `numbered` true  -> pending_goal_tick is set (the fix): expect burst tick 2.
## `numbered` false -> pending_goal_tick stays -1 (old contract): expect tick 1.
func _arm(name: String, walk: Walkable, spawn: Vector2i, numbered: bool) -> bool:
	# A fresh registry and Sim per arm, so arm 2 cannot inherit arm 1's state.
	var r := ActorRegistry.new()
	var sim := Sim.new()
	sim.walk = walk
	var pw := PathWindow.new(walk)
	sim.path_window = pw
	var pid := r.spawn(0, Vector2(spawn.x + 0.5, spawn.y + 0.5), 100, 100)
	sim.focus_actor_id = pid

	var goal := Vector2i(spawn.x + 1, spawn.y)
	var base := sim.tick
	var want := base + (GOAL_AT_OFFSET if numbered else 1)

	sim.pending_goal_actor_id = pid
	sim.pending_goal = goal
	if numbered:
		sim.pending_goal_tick = base + GOAL_AT_OFFSET

	# One advance() call carrying enough time for BURST_TICKS ticks -- the
	# catch-up burst the old gate could not survive. Not a hand-rolled loop of
	# tick_once(): the whole point is that the caller does NOT control how many
	# ticks run inside one advance().
	_fired_on = -1
	var seen := PackedInt32Array()
	for i in BURST_TICKS:
		var before := sim.tick
		sim.tick_once(r, Vector2(spawn))
		# has_goal() flips the moment track() is handed a real goal, which only
		# happens on the tick the request is actually consumed. That is the
		# observable this check keys off -- not a path length, which could also
		# change for unrelated reasons such as the window recentring.
		if _fired_on < 0 and pw.has_goal():
			_fired_on = before + 1
		seen.append(before + 1)

	var pass_ := _fired_on == want
	print("goaltick_check\tarm=%s\tburst=%d\twant_tick=%d\tfired_on=%d\tverdict=%s\t" % [
		name, BURST_TICKS, want, _fired_on, "PASS" if pass_ else "FAIL"])
	return pass_


## First walkable cell found by scanning a handful of region-bearing sectors.
## Deliberately not a constant: under the D-08 allowlist only FLOOR/DOOR/STEP
## are open, and which cells those are depends on the install.
func _any_walkable(walk: Walkable) -> Vector2i:
	for s: Vector2i in [Vector2i(64, 39), Vector2i(4, 37), Vector2i(52, 51)]:
		var ox: int = s.x * Sacred.SECT
		var oy: int = s.y * Sacred.SECT
		for dy in Sacred.SECT:
			for dx in Sacred.SECT:
				var c := Vector2i(ox + dx, oy + dy)
				if walk.is_open(c.x, c.y) and walk.is_open(c.x + 1, c.y):
					return c
	return Vector2i(-1, -1)
