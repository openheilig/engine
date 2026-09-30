class_name SectorScheduler
extends RefCounted
## S1: resolves the named Sector/Region procedures retail's interpreter runs
## as the player's view moves (script-bytecode.md: cInterpretSQW::initSector
## -> WorkFunktion "Sector50039Init"; 11,414 Sector* + 128 Region* symbols
## in the Seraphim's vectoren.bin). The procedures are ordinary FunkCode,
## run through the same ScriptVM/QuestCast the quest hooks use.
##
## Naming, transcribed from retail's own log: sector procedures are
## `Sector<x><y><Phase>` with the sector cell /64 printed %02d%03d -- the
## start cell 3236,2511 is sector 50,39, hence "Sector50039Init". Region
## procedures are `Region<n><Phase>`.

## The procedure name for a sector or region phase. For regions pass
## region_id and is_region=true (the sector x/y are ignored).
static func proc_name(a: int, b: int, phase: String, is_region: bool = false) -> String:
	if is_region:
		return "Region%d%s" % [a, phase]
	return "Sector%02d%03d%s" % [a, b, phase]


## Resolve and run one procedure into `cast`. Returns "" on success, a
## reason otherwise (absent procedures are "" too -- not every sector has
## one; the caller distinguishes via ran=). refused_op reports through the
## VM for the refusal report.
## Retail's dispatcher skips these decoded, side-effect-free-at-VM-level
## opcodes (E2 gates); sector procedures lean on them.
const SKIP_OPS: PackedInt32Array = [8, 100, 115]


static func run_proc(vec: Sacred.Vectoren, code: PackedByteArray, name: String,
		cast: QuestCast, vm: ScriptVM) -> Dictionary:
	var proc: Dictionary = vec.procedure(name)
	if proc.is_empty():
		return {"ran": false}
	var ok: bool = vm.run(code, int(proc["offset"]), int(proc["length"]), cast, SKIP_OPS)
	return {"ran": ok, "refused_op": vm.refused_op if not ok else -1,
		"offset": int(proc["offset"]), "length": int(proc["length"])}


## Sector entry, retail's two-phase shape (the log shows BOTH for one
## entry): initSector runs the Init procedure once per session's first
## entry, then enterSector runs Enter on every entry -- both feed the same
## cast. The caller owns which phases have already run.
static func enter_sector(vec: Sacred.Vectoren, code: PackedByteArray,
		gx: int, gy: int, first_time: bool, cast: QuestCast, vm: ScriptVM) -> Dictionary:
	var out := {"ran": false}
	if first_time:
		out = run_proc(vec, code, proc_name(gx, gy, "Init"), cast, vm)
	var enter := run_proc(vec, code, proc_name(gx, gy, "Enter"), cast, vm)
	if bool(enter.get("ran", false)) or not bool(out.get("ran", false)):
		out = enter
	return out
