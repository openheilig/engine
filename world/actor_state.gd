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
