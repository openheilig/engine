class_name Replay
extends RefCounted
## Record writer, state-dump writer, and the replay drive loop.
##
## The drive loop lives here, inside godot-port/world/, precisely so the
## project's existing "one tick loop" invariant stays true: main.gd's
## _advance_sim() stays the only Sim advance-call site outside
## godot-port/world/, and this file's replay() is the only OTHER caller of
## Sim.tick_once() anywhere in the tree.
##
## Every line this file writes follows the house fact-line convention
## ActorState.dump_line() set: a tag first, then tab-separated key=value
## fields, floats always "%.6f", and a trailing tab so every field
## boundary, including the last, is a tab.

const FORMAT_VERSION := 1


## The RECORD side. Opens `path` for writing in _init(); callers must check
## is_open() before use, following Sacred.Pak's own open-check-degrade shape
## (sacred.gd:118-129) rather than proceeding with a null handle.
class Recorder extends RefCounted:
	var _f: FileAccess

	## `spawn_cell` and `player_id` are written into the header so replay can
	## verify it is driving the same starting conditions -- never so replay
	## can read a position back out of the file (D-01, D-03): nothing else
	## this class writes carries a "cell=" key, and the acceptance gate for
	## this file greps for exactly that absence.
	func _init(path: String, tick_hz: int, spawn_cell: Vector2, player_id: int) -> void:
		_f = FileAccess.open(path, FileAccess.WRITE)
		if _f == null:
			push_error("Replay.Recorder: cannot open %s for writing (%s)" % [
				path, error_string(FileAccess.get_open_error())])
			return
		_f.store_line("header\tfmt=%d\ttickhz=%d\tspawn=%.6f,%.6f\tplayerid=%d\t" % [
			FORMAT_VERSION, tick_hz, spawn_cell.x, spawn_cell.y, player_id])

	func is_open() -> bool:
		return _f != null

	## One line per tick that ran this frame, carrying that frame's movement
	## intent (D-01, D-06) -- never a resolved position, a path, or anything
	## else the simulation produced. `goal` is the tick's requested path
	## goal, or PathWindow.NO_GOAL (the sentinel; written as-is, plain
	## integers, so replay can tell "no request" from a real cell without a
	## second flag) when nothing was requested this tick. Still input, not
	## output: the goal is what the composition root asked for, not anything
	## the simulation computed from it.
	func write_input(tick: int, intent: Vector2, goal: Vector2i = PathWindow.NO_GOAL,
			route_cell: Vector2i = PathWindow.NO_GOAL) -> void:
		if _f == null:
			return
		var route_field := ""
		if route_cell != PathWindow.NO_GOAL:
			route_field = "route=%d,%d\t" % [route_cell.x, route_cell.y]
		_f.store_line("input\ttick=%d\tdx=%.6f\tdy=%.6f\tgoal=%d,%d\t%s" % [
			tick, intent.x, intent.y, goal.x, goal.y, route_field])

	## Written AFTER that frame's input lines (D-07): the dropped count only
	## reaches the header of the FOLLOWING tick, and both the record run and
	## the replay run must agree on that ordering, or a dropped tick would
	## land in different relative positions on the two sides.
	func write_gap(tick: int, dropped_delta: int) -> void:
		if _f == null:
			return
		_f.store_line("gap\ttick=%d\tdropped=%d\t" % [tick, dropped_delta])

	func close() -> void:
		if _f != null:
			_f.close()
			_f = null


## The state-dump writer, shared by the record run and the replay run.
## Driven from Sim.output_hook so both runs dump at exactly the same point
## in the tick (D-12, D-13) -- never called directly from a frame callback,
## which would let the two runs drift relative to each other by a tick.
class Dumper extends RefCounted:
	var _f: FileAccess

	func _init(path: String) -> void:
		_f = FileAccess.open(path, FileAccess.WRITE)
		if _f == null:
			push_error("Replay.Dumper: cannot open %s for writing (%s)" % [
				path, error_string(FileAccess.get_open_error())])

	func is_open() -> bool:
		return _f != null

	## Per-tick header (tick number, dropped count so a diff hunk localises
	## a divergence to a tick, D-13) then ActorRegistry.dump() verbatim --
	## never reimplemented or reformatted (D-12). Nothing camera-derived,
	## streaming-derived, or time-derived reaches this file (D-14).
	func write_tick(tick: int, dropped: int, reg: ActorRegistry) -> void:
		if _f == null:
			return
		_f.store_line("tick\ttick=%d\tdropped=%d\t" % [tick, dropped])
		var lines: Array[String] = []
		reg.dump(lines)
		for line: String in lines:
			_f.store_line(line)

	## Plan 04-02, D-16: one line whenever path_window recentres or (re)computes
	## a path this tick -- `event` is exactly the Dictionary
	## PathWindow.track() returned (never re-derived here). Called from the
	## same output_hook as write_tick(), so both land at the same point in
	## the tick on both the record run and the replay run (D-12, D-13).
	## Skipped entirely on a tick where `event` is empty (nothing to report).
	func write_astar(tick: int, event: Dictionary) -> void:
		if _f == null or event.is_empty():
			return
		var origin: Vector2i = event["origin"]
		var goal: Vector2i = event["goal"]
		var path_len: int = event["path_len"]
		_f.store_line("astar\ttick=%d\torigin=%d,%d\tgoal=%d,%d\tlen=%d\t" % [
			tick, origin.x, origin.y, goal.x, goal.y, path_len])

	## One line per swap transition, from Interior.last_changes() as passed
	## through the same output_hook on record and replay. Nothing camera-,
	## streaming-, or time-derived reaches this file; data is never re-derived.
	func write_swap(tick: int, changes: Array) -> void:
		if _f == null or changes.is_empty():
			return
		for change: Dictionary in changes:
			var parts := Interior.unpack_region_key(change["key"])
			_f.store_line("swap\ttick=%d\tregion=%d,%d,%d\tstate=%s\tfamily=%s\t" % [
				tick, parts.x, parts.y, parts.z,
				Interior.state_name(change["to"]), change["family"]])

	func close() -> void:
		if _f != null:
			_f.close()
			_f = null


## Replays a recording written by Recorder: parses the header, checks the
## recorded tick rate and spawn cell against the live ones character for
## character on the formatted fields, then drives Sim.tick_once() exactly
## once per recorded input line, in recorded order. Never reads a wall
## clock, never reads a frame delta, and never calls Sim's per-frame advance
## entry point (D-04). Returns OK, or a non-OK Error the caller turns into a
## non-zero exit.
##
## `perturb_tick` / `perturb_mode` (Task 2's falsifiability control):
## "" perturbs nothing. "nudge" adds a fixed offset -- well above the dump's
## own "%.6f" resolution, so it survives formatting -- to the resolved
## cell's x component immediately after the named tick's tick_once() call.
## "skip" drops the named tick's input line entirely, so the actor receives
## no intent that tick. "origin" (Task 3) adds `origin_perturb` to
## sim.pending_origin_offset immediately before the named tick's
## tick_once() call, forcing that one tick's window origin away from the
## value origin_for() would otherwise produce -- a value that legitimately
## differs between a recording run and a replay run only when the two runs
## are given different composition-root inputs, exactly what `origin_perturb`
## simulates. All three are selected by flag only, through these
## parameters, never by editing this file or its caller -- the revert is
## exact, not a hand-undone source edit.
static func replay(path: String, sim: Sim, reg: ActorRegistry, player_id: int,
		perturb_tick: int = -1, perturb_mode: String = "", origin_perturb: Vector2i = Vector2i.ZERO) -> Error:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("Replay.replay: cannot open %s for reading (%s)" % [
			path, error_string(FileAccess.get_open_error())])
		return ERR_CANT_OPEN

	var header := _parse_fields(f.get_line())
	if header.get("_tag", "") != "header":
		push_error("Replay.replay: %s does not open with a header line" % path)
		f.close()
		return ERR_FILE_CORRUPT

	var rec_tickhz := int(header.get("tickhz", "-1"))
	if rec_tickhz != sim.tick_hz:
		push_error("Replay.replay: recorded tickhz=%d does not match the live tickhz=%d" % [
			rec_tickhz, sim.tick_hz])
		f.close()
		return ERR_INVALID_DATA

	var player := reg.get_actor(player_id)
	if player == null:
		push_error("Replay.replay: player_id=%d does not resolve to a live actor" % player_id)
		f.close()
		return ERR_INVALID_DATA

	var live_spawn := "%.6f,%.6f" % [player.cell.x, player.cell.y]
	var rec_spawn: String = header.get("spawn", "")
	if rec_spawn != live_spawn:
		push_error("Replay.replay: recorded spawn=%s does not match the live spawn=%s" % [
			rec_spawn, live_spawn])
		f.close()
		return ERR_INVALID_DATA

	while not f.eof_reached():
		var line := f.get_line()
		if line == "":
			continue
		var fields := _parse_fields(line)
		var tag: String = fields.get("_tag", "")
		var line_tick := int(fields.get("tick", "-1"))
		if tag == "gap":
			sim.dropped += int(fields.get("dropped", "0"))
		elif tag == "input":
			var dx := float(fields.get("dx", "0"))
			var dy := float(fields.get("dy", "0"))
			var route_field: String = fields.get("route", "")
			if route_field != "":
				var route_parts := route_field.split(",")
				if route_parts.size() != 2:
					f.close()
					return ERR_FILE_CORRUPT
				player.cell = Vector2(int(route_parts[0]), int(route_parts[1])) + Vector2(0.5, 0.5)
			# All three perturbations act BEFORE this line's tick_once()
			# call, not after, so the tick they name is the one whose OWN
			# dumped state diverges -- not the following tick. tick_once()
			# still runs every recorded line either way, so the tick
			# numbering in both dumps' headers stays aligned line-for-line;
			# only the state under the perturbed tick (and everything after
			# it, D-03) differs, which is what lets replay_diff.sh's
			# --control mode locate the divergence by tick number at all.
			if perturb_mode == "skip" and line_tick == perturb_tick:
				dx = 0.0
				dy = 0.0   # the actor receives no intent this tick -- on purpose (Task 2)
			elif perturb_mode == "nudge" and line_tick == perturb_tick:
				player.cell.x += 0.5   # well above the dump's "%.6f" resolution (Task 2)
			elif perturb_mode == "origin" and line_tick == perturb_tick:
				sim.pending_origin_offset = origin_perturb   # forces one tick's window origin off course (Task 3)
			player.heading = Vector2(dx, dy)
			var goal_field: String = fields.get("goal", "")
			if goal_field != "":
				var gp := goal_field.split(",")
				if gp.size() == 2:
					var gv := Vector2i(int(gp[0]), int(gp[1]))
					if gv != PathWindow.NO_GOAL:
						sim.pending_goal_actor_id = player_id
						sim.pending_goal = gv
			sim.tick_once(reg, player.cell)
		else:
			push_error("Replay.replay: %s line for tick %d has an unrecognised tag %s" % [
				path, line_tick, tag])
			f.close()
			return ERR_FILE_CORRUPT
	f.close()
	return OK


## Tab-separated "key=value" line parser shared by the header and every body
## line. The leading tag, before the first tab, is stored under "_tag".
static func _parse_fields(line: String) -> Dictionary:
	var parts := line.split("\t")
	var out := {}
	if parts.is_empty():
		return out
	out["_tag"] = parts[0]
	for i in range(1, parts.size()):
		var kv: String = parts[i]
		if kv == "":
			continue
		var eq := kv.find("=")
		if eq < 0:
			continue
		out[kv.substr(0, eq)] = kv.substr(eq + 1)
	return out
