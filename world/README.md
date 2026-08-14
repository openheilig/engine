# world — the simulation

The fixed-tick simulation layer. It owns actors, movement and walkability, and
it is deliberately ignorant of Godot's scene tree: no `Node3D`, no
`add_child`, no `get_tree`, no threads, no `call_deferred`.

That is enforced, not just intended — `parity/verify.gd`'s `LAYER_RULES` scans
this directory for those names and fails if one appears.

| File | What |
|---|---|
| `sim.gd` | The fixed-tick loop. Everything advances through `advance()`, by exact tick count. |
| `actor_registry.gd` | Actor handles and lookup. |
| `actor_state.gd` | Per-actor state. |
| `movement.gd` | Movement resolution against the cell grid. |
| `path_window.gd` | The sliding path window — pathfinding over a bounded region rather than the whole world. |
| `walkable.gd` | Which region classes are open ground. An allowlist, not a blocklist. |
| `interior.gd` | Interior/exterior swap for supported buildings. |
| `record_store.gd` | The record/replay id space and storage. |
| `replay.gd` | Deterministic replay, and the three opt-in perturbation flags the determinism gate uses. |

## Why determinism matters here

A change that alters simulation output is caught by replaying a recording and
diffing, not by argument — `tools/parity/replay_diff.sh` is that gate, and
`--control` proves the gate can still fail by perturbing a run on purpose.
