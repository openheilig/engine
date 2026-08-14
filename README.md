# OpenSacred

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

## Running it

You need Godot 4.7 (Forward Plus) and a Sacred Gold install.

```
godot --path . -- --install=/path/to/sacred
```

The path is remembered in `user://opensacred.cfg` as `install_path`, so later
runs need no flag. `main.gd` is the composition root: it resolves the install,
builds the readers, and dispatches on the CLI flags (`--grn=NAME` renders a
single model, and so on).

## Layout

| Path | What |
|---|---|
| `main.gd`, `main.tscn` | Composition root and entry scene. |
| `sacred.gd` | Runtime readers for the retail formats (pak, world, static, mixed, items). |
| `world/` | Simulation: `sim.gd` fixed-tick loop, actor registry and state, movement, path windows, walkability, interiors, record/replay. |
| `view/` | Rendering: `sector_view.gd` world streaming, `model_view.gd` Granny renderer, player and cursor views, rig placement. |
| `*_check.gd`, `verify.gd` | Parity harnesses. See below. |
| `*.gdshader` | Terrain and object shaders. |

## How correctness is established

Nothing here is inferred from how it looks on screen. Every reader is checked
against an independent decode:

- `verify.gd` prints the same facts as the Python `verify_ref.py` in the
  [tools](../tools) repo, so the two implementations can be diffed byte for
  byte. Two independent decoders agreeing is the evidence; one decoder looking
  plausible is not.
- The `*_check.gd` scripts (all sharing `check.gd`) are single-purpose gates,
  each answering one question against the retail data.
- The replay harness gates simulation changes on identical output.

The format documentation these implement lives in the
[research](../research) repo.

## Licence

Not yet chosen — see the top-level `../README.md`.

## Legal

Sacred and Sacred Gold are the property of their respective rights holders.
This project is an unaffiliated, clean-room reimplementation of the engine
that reads data the user already owns. No game data is included here.
