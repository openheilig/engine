# OpenHeilig — engine

An open reimplementation of the *Sacred Gold* engine on Godot 4.7.

It reads **your own retail install** at runtime and ships none of it — no
assets, no textures, no models, no audio are contained in or redistributed by
this repository. Without a legally obtained copy of the game it does nothing.

## Status

Pre-alpha, and honest about it: this is a **world viewer with a simulation
core and one scripted fight that finishes**, not a playable game. What runs
today:

- **World streaming.** Sacred's 100×100 sector grid loads straight out of the
  retail install — terrain mesh, texture arrays, static props, buildings —
  with the camera driving sector residency.
- **Terrain and object rendering.** Custom shaders for both, matching the
  retail isometric projection.
- **Granny `.GRN` models and animation.** Meshes, skeletons and 3413 of 3421
  animation clips decode; playback applies authored local bone poses.
- **A fixed-tick simulation.** Actor registry, movement, path windows,
  cell-space walkability over Sacred's region grids, interior/exterior swap.
- **A record/replay harness.** Runs are recorded and replayed deterministically
  so a change that alters simulation output is caught rather than argued about.
- **The scripted cast, where retail puts it.** `startcode.bin` decodes to 2565
  NPCs across the eight character classes plus 16,021 objects, each with its
  body model, hand items and starting cell; `--npcs` draws them at those cells.
  Placement only — nothing animates or acts.
- **The hero, where retail starts her.** The Seraphim at cell 3236,2511 with
  composed armour and hand items, playing an `IDLE` clip, facing driven through
  the alignment bone above `Bip01`.
- **One quest that closes, and one that starts the game.** `world/script.gd`
  interprets eight opcodes of the quest bytecode and *refuses* the ones it does
  not know rather than skipping them — and refuses just as firmly when the HOST
  cannot receive an opcode's effect, so a hook never runs halfway.
  `world/quest_log.gd` holds quest state; `world/quest_cast.gd` adds the NPCs a
  hook creates, as data `main.gd` turns into rigs; `world/encounter.gd` runs
  quest 74 end to end against a hostile NPC. A new game now runs **quest 1
  (`Tutorial`)**, whose OnEnter stands a novice nun beside the Seraphim as
  retail does — `--noquests` opts out. `world/combat.gd` implements
  retail's to-hit **and** its damage resolution — one shared curve used twice,
  transcribed and then confirmed live under gdb against the retail binary. The
  gate checks it against numbers the binary itself printed. Only the physical
  channel is fed: armour and resistances have nothing to read them off an actor
  until there is an inventory.
- **Retail's taskbar.** `view/hud.gd` draws the console, wings, buttons and
  combat-art arc from retail's own 1887-rect table at retail's own coordinates.
  The life and mana gauges are **not** drawn: all 46 `cUI_Taskbar2` functions
  were enumerated and the class references no orb art and computes no fraction.
  The gap is left visible rather than invented.
- **Measured numbers, not chosen ones.** AT and PA from skill levels over
  attribute bases, difficulty scaling for non-heroes, per-sector creature level
  bands, and sector music *selection* (`formats/sectors.gd`) — selection only,
  since there is no audio layer to hand the result to.

Several readers have no feature behind them yet: the faction matrix, `.pax`
hero saves, `triggers.pak`, `formats/equipment.gd` and `formats/wpmod.gd` are
decoded and gated with no production caller.

Not implemented: inventory, skills, dialogue, sound playback, multiplayer,
save/load. Do not expect to play anything.

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

`run.sh` wraps this and needs no arguments — the install is found by
`Sacred.find_install()`. `./run.sh --checks` runs every gate in `checks/` under
a timeout (a failed `assert()` hangs rather than exits) and prints
`PASS=n FAIL=n`; `--layers` runs `parity/verify.gd`; `--flags` lists the flags
`main.gd` actually parses by reading them out of it. Anything else is passed
through to the game.

The path is remembered in `user://openheilig.cfg` as `install_path`, so later
runs need no flag. `main.gd` is the composition root: it resolves the install,
builds the readers, and dispatches on the CLI flags (`--grn=NAME` renders a
single model, and so on).

To inspect an authored native motion rather than choose a clip by name:

```
godot --path . -- --grn=SERAPHIM.GRN --motion=2
```

`--motion=0..255` resolves the model header's motion reference through the
archive's kind-65 table and plays that clip. Missing references fail rather
than substitute another animation. Use it with `--grn`, without `--anim`.
This is explicit motion selection in the model viewer; gameplay's
actor-state/equipment-to-motion selection remains separate.

## Layout

```
main.gd        composition root and CLI dispatch; main.tscn is the entry scene
sacred.gd      the Sacred namespace: install discovery + a facade over formats/
iso_camera.gd  the isometric camera (owns a _process, so not a view/ file)
drive.gd       --drive=/--shots=: scripted input and timed captures
debug_overlay.gd  the F3 developer overlay (owns a _process, so not a view/ file)
formats/       the runtime readers, one file per retail format
world/         the fixed-tick simulation: actors, movement, walkability, replay
view/          rendering: sector streaming, Granny models, player, cursor
parity/        verify.gd and grnwalk.gd -- what the Python side is diffed against
checks/        single-purpose gates, all sharing check.gd
probes/        one-shot investigations, kept for reproduction
shaders/       encoded floor composition, spatial objects, actors and liquids
```

| Path | What |
|---|---|
| `main.gd`, `main.tscn` | Composition root and entry scene. |
| `sacred.gd` | The `Sacred` namespace: install discovery, and a facade re-exporting everything in `formats/`. Decodes nothing itself. |
| `formats/` | [The runtime readers](formats/), one file per retail format — pak, world, texture, regions, models, saves, script bytecode. |
| `iso_camera.gd` | The isometric camera. Not in `view/` — it owns a `_process`, which `view/` forbids. |
| `debug_overlay.gd` | The developer overlay: resolution, framerate, camera and mouse cell, player, sim tick, sector residency, draw calls and memory. **F3** toggles it; `--overlay` starts it shown so a `--shot=`/`--drive` capture can carry it. Hidden by default, so a run that never presses F3 photographs exactly what it photographed before. Not in `view/` — it owns a `_process`. |
| `drive.gd` | `--drive=`/`--shots=`: plays a timeline of scripted input and captures at stated milliseconds. Speaks the retail autopilot's own `ms verb args` grammar, so one script drives both engines. Refuses `--shots=` at anything but 1024×768 — the only size retail can be captured at. Front-ended by `tools/drive/session.sh`. |
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
