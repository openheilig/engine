# OpenHeilig — engine

An open reimplementation of the *Sacred Gold* engine on Godot 4.7.

It reads **your own retail install** at runtime and ships none of it — no
assets, no textures, no models, no audio are contained in or redistributed by
this repository. Without a legally obtained copy of the game it does nothing.

## Status

Pre-alpha, and honest about it: this is a **world viewer with a simulation
core**, not a playable game. What runs today:

- **World streaming.** Sacred's 100×100 sector grid loads straight out of the
  retail install — terrain mesh, texture arrays, static props, buildings —
  with the camera driving sector residency.
- **Terrain and object rendering.** Custom shaders for both, matching the
  retail isometric projection.
- **Granny `.GRN` models and animation.** Meshes, skeletons and 3413 of 3421
  animation clips decode; skeletal animation retargets across characters.
- **A fixed-tick simulation.** Actor registry, movement, path windows,
  cell-space walkability over Sacred's region grids, interior/exterior swap.
- **A record/replay harness.** Runs are recorded and replayed deterministically
  so a change that alters simulation output is caught rather than argued about.

Not implemented: combat, items, inventory, skills, quests, dialogue, UI,
sound, multiplayer, save/load. Do not expect to play anything.

## Start here

| I want… | Read |
|---|---|
| to run it | [Running it](#running-it), below |
| to read a retail format | [formats/](formats/) |
| the simulation — actors, movement, replay | [world/](world/) |
| the rendering — streaming, models, cursor | [view/](view/) |
| to prove a decoder is right | [parity/](parity/) |
| a gate that answers one question | [checks/](checks/) |
| how a fact was originally found | [probes/](probes/) |
| **why any of this is trusted** | [How correctness is established](#how-correctness-is-established), below |

## Running it

You need Godot 4.7 (Forward Plus) and a Sacred Gold install.

```
godot --path . -- --install=/path/to/sacred
```

The path is remembered in `user://openheilig.cfg` as `install_path`, so later
runs need no flag. `main.gd` is the composition root: it resolves the install,
builds the readers, and dispatches on the CLI flags (`--grn=NAME` renders a
single model, and so on).

## Layout

```
main.gd        composition root and CLI dispatch; main.tscn is the entry scene
sacred.gd      the Sacred namespace: install discovery + a facade over formats/
iso_camera.gd  the isometric camera (owns a _process, so not a view/ file)
formats/       the runtime readers, one file per retail format
world/         the fixed-tick simulation: actors, movement, walkability, replay
view/          rendering: sector streaming, Granny models, player, cursor
parity/        verify.gd and grnwalk.gd -- what the Python side is diffed against
checks/        single-purpose gates, all sharing check.gd
probes/        one-shot investigations, kept for reproduction
shaders/       terrain, terrain mask and object shaders
```

| Path | What |
|---|---|
| `main.gd`, `main.tscn` | Composition root and entry scene. |
| `sacred.gd` | The `Sacred` namespace: install discovery, and a facade re-exporting everything in `formats/`. Decodes nothing itself. |
| `formats/` | [The runtime readers](formats/), one file per retail format — pak, world, texture, regions, models, saves, script bytecode. |
| `iso_camera.gd` | The isometric camera. Not in `view/` — it owns a `_process`, which `view/` forbids. |
| `world/` | Simulation: `sim.gd` fixed-tick loop, actor registry and state, movement, path windows, walkability, interiors, record/replay. |
| `view/` | Rendering: `sector_view.gd` world streaming, `model_view.gd` Granny renderer, player and cursor views, rig placement. |
| `parity/` | [`verify.gd` and `grnwalk.gd`](parity/) — the two scripts the Python side diffs against. |
| `checks/` | [Single-purpose gates](checks/), all sharing `check.gd`. Each answers one question against the retail data. |
| `probes/` | [One-shot investigations](probes/). How the facts in `research/` were found; kept for reproduction, not run in normal work. |
| `shaders/` | Terrain and object shaders. |

`world/` and `view/` are a checked boundary, not a convention: `parity/verify.gd`
holds a `LAYER_RULES` table and fails if `world/` touches the scene tree or
threads, or if `view/` names a simulation type or defines its own per-frame
entry point.

## How correctness is established

Nothing here is inferred from how it looks on screen. Every reader is checked
against an independent decode:

- `parity/verify.gd` prints the same facts as the Python `verify_ref.py` in the
  [tools](../tools) repo, so the two implementations can be diffed byte for
  byte. Two independent decoders agreeing is the evidence; one decoder looking
  plausible is not.
- `checks/` holds single-purpose gates, each answering one question against the
  retail data.
- The replay harness gates simulation changes on identical output.

Every check and probe runs headless and states its own command line in its
header comment:

```
godot --headless --path . --script res://checks/floor_check.gd
```

## Related

This is one of three repositories:

- [research](../research) — what the formats are, and how each finding was
  established.
- [tools](../tools) — the analysis and extraction tools, and the Python half
  of every parity gate.

## Licence

MIT — see [LICENSE](LICENSE). Covers this source only; it grants no rights in
Sacred or Sacred Gold.

## Legal

Sacred and Sacred Gold are the property of their respective rights holders.
This project is an unaffiliated, clean-room reimplementation of the engine
that reads data the user already owns. No game data is included here.
