class_name ActorState
extends RefCounted
## Mutable per-actor simulation state -- one instance per living actor, owned
## exclusively by ActorRegistry.
##
## RefCounted, not Node: an actor's state must survive the sector node that
## happens to cover its cell being queue_free'd and rebuilt by the streamer
## (main.gd's _add_sector / _process) when the player backtracks. Parenting
## an actor to a sector node would make the actor's lifetime a function of
## sector lifetime -- the coupling world/actor_registry.gd's header exists
## to name and avoid.
##
## Not Resource either: nothing here is authored in the Inspector or saved
## as a .tres, and every field mutates on the sim tick -- Resource's
## serialization machinery has no role. Follows the house RefCounted data
## class pattern in godot-port/sacred.gd (Pak, Tiles, World, ...).

const FLAG_ALIVE := 1 << 0

var id: int = 0            ## assigned by ActorRegistry.spawn(); read-only by convention
var record_id: int = 0     ## reference into the record store (plan 02) -- never a copy of its fields
var cell: Vector2 = Vector2.ZERO   ## continuous cell-space position; source of truth, per R3.2
var heading: Vector2 = Vector2.ZERO   ## per-tick movement intent (Phase 4), not a bare facing -- Sim._step_actor scales it by Movement.CELLS_PER_TICK and sweeps it against the navmesh each tick
## Which way the body is TURNED, as opposed to which way it was told to go.
##
## A SEPARATE FIELD FROM `heading`, not a reuse of it, because the two are
## genuinely different quantities and Sim._step_actor says so in its own header:
## `heading` is a per-tick INTENT that path-following deliberately overrides
## without ever writing back, and it is Vector2.ZERO the instant an actor stands
## still. A renderer reading `heading` therefore sees zero for a whole ordinary
## session -- click-to-move never sets it, and there is no keyboard path yet --
## and a character that merely stopped walking would snap back to its mesh rest
## orientation. `facing` is written by _step_actor from the delta the body
## ACTUALLY moved, after the path override is resolved, and then HELD. Because
## it is the sim's own deterministic quantity, click-to-move, scripted intent
## and replay all turn an actor identically.
##
## SEEDED TOWARDS THE VIEWER (PI/4 = cell (1,1)) rather than at zero, because an
## actor who has not moved yet still has to face somewhere, and zero previously
## meant "do not turn the rig at all" -- which left it in its MODEL REST
## orientation, side-on for the Seraphim, for the whole first stretch of every
## new game. Measured against retail's Seraphim campaign start (analysis/tools/
## drive/menu.sh route `new`, t=34000): retail draws her frontal, mirror-symmetry
## axis at the mask centre, IoU 0.668 -- against 0.376 with the axis 69% across
## for the port's rest pose.
##
## PI/4 IS DERIVED, NOT CHOSEN, and is the same angle view/player_view.gd pins as
## PlayerView.TOWARDS_VIEWER (spelled as the literal here because world/ may not
## name a view type -- parity/verify.gd enforces that): the isometric projection
## is px=(x-y)*HW, which forces x=y for a screen-vertical facing, and
## py=-(x+y)*HH against sector_view's mz=(-p.y/HH), which forces x+y>0 for the
## near side. (1,1) is the unique solution.
##
## ponytail: one class, one capture. This is the retail-facing default for a
## standing start; it is not evidence about other classes, respawns or interiors,
## and the moment the actor moves the sim overwrites it.
var facing: Vector2 = Vector2.from_angle(PI / 4.0)
var hp: int = 0
var hp_max: int = 0
var flags: int = 0
var ticks_simulated: int = 0


## Sector this actor's cell currently falls in. Computed on demand, NEVER
## stored: a stored sector field would make the sector an owner again, which
## is exactly what ActorRegistry exists to prevent.
func sector_key() -> int:
	return int(cell.y) / Sacred.SECT * 100 + int(cell.x) / Sacred.SECT


## One tab-separated line for the --actor-probe dump (and any future
## save/replay tooling). Both cell components are formatted "%.6f" so the
## line is byte-stable across runs. Terminated with a trailing tab so every
## field boundary -- including the last -- is a tab, matching the registry's
## own dump() lines.
func dump_line() -> String:
	return "actor\t%d\trec=%d\tcell=%.6f,%.6f\thp=%d\thpmax=%d\tsect=%d\tticks=%d\t" % [
		id, record_id, cell.x, cell.y, hp, hp_max, sector_key(), ticks_simulated]
