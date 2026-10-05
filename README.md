# OpenHeilig — engine

An open reimplementation of the *Sacred Gold* engine on Godot 4.7.

It reads **your own retail install** at runtime and ships none of it — no
assets, no textures, no models, no audio are contained in or redistributed by
this repository. Without a legally obtained copy of the game it does nothing.

## Status

Public **development snapshot**, not a released game and not a completed
0.0.1. The approved release target is the
[playable Seraphim retail slice](docs/milestone-0.0.1.md): start → walk →
talk/quest → real combat → loot/equip → save → restart/load → continue,
with retail-matched presentation and consequences along that bounded route.

Current code is substantially newer than the original world viewer, but
components, ordinary controls and retail acceptance are different claims:

| Area | Present in this snapshot | Not yet established |
|---|---|---|
| Retail resources/world | Runtime readers, sector streaming, terrain/statics, interiors and native-style floor composition | Complete scene breadth, actor visibility and strict full-frame parity |
| Models | Granny meshes/poses/animation, equipment rendering, all eight class body mappings including native Vampiress day body | Complete action/equipment/form selection, opening chronology or all class tutorials |
| Movement | Click/drag commands, fixed-tick simulation, actor registry, path windows and camera follow | Complete Gold admission and continuous retail-equivalent travel |
| Character/session | Template-derived HP, item instances, progression commands and content-bound state owner | Complete authoritative equipment/stat/action state |
| Combat | Recovered hit/damage kernels, two-sided demonstration brains and reward/loot APIs | Native quest causality, full damage channels, retail ranges/cadence/arts and ordinary encounter coverage |
| Inventory | `I` opens a text listing; ownership/transfer APIs exist | Retail grid, ordinary pickup/equip/use controls and correct listing filters |
| Scripts/dialogue | Expanded VM, selected-class bootstrap, real dialogue/choice components and queued-talk helper | Ordinary talk input, durable task/sector lifecycle and the complete Seraphim conversation→quest route |
| Persistence | CLI engine-owned JSON save/load with exact content identity and dialogue state | Ordinary save/load UI and complete restart/continue correctness |
| HUD/audio | Retail sheet taskbar, health/art updates, sector/fight music and script-sound paths | Complete actionable HUD, portrait/journal/compass, audio-event parity |
| Movies | Explicit CLI playback and display/audio probe using user-local conversion | Normal menu/script/world-return integration or full cinematic coverage |
| Mods/cache | Data-only whole-file profiles, exact identity, early mounting and source-keyed derived texture caches | Record merges, media replacements, executable mods or hot reload |

Fresh production verification on 2026-10-05 reached the 1024×768
Forward+/Vulkan Seraphim world, accepted a movement click and opened the `I`
panel. The actual frame still obscured the hero and showed a text-only empty
inventory. This run used Dummy audio with retail sound muted, so it proves no
audible playback. Source inspection also found unwired ordinary talk/pickup,
demonstration combat inputs and incomplete composite save continuation.

A fresh source checkout imported and passed **87/87 component checks** with
explicit LGP install and optional Windows Gold UI-table fixture on 2026-10-05.
An actual intro-media probe produced two changing frames, mixer peak 0.537200
and a clean skip return. Neither establishes the missing gameplay journey.

The [milestone contract](docs/milestone-0.0.1.md) records these blockers and
the acceptance gates. No passing check count, improved start-scene ratchet or
isolated model render is a claim of 1:1 gameplay. Full campaigns, other-class
qualification, multiplayer and retail world-save interchange are outside
0.0.1. See [tooling and verification](docs/tooling.md) before treating a
research harness as a release gate.

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

`run.sh` wraps this. Pass `--install` explicitly on a fresh checkout; later
runs may use `Sacred.find_install()`'s remembered path. `./run.sh --checks`
runs the existing component gates under a timeout and prints `PASS=n FAIL=n`;
some require additional private retail fixtures. `--layers` runs
`parity/verify.gd`; `--flags` lists parsed flags. See the tooling document
for corpus requirements and the limits of each gate.

The path is remembered in `user://openheilig.cfg` as `install_path`, so later
runs need no flag. `main.gd` is the composition root: it resolves the install,
builds the readers, and dispatches on the CLI flags (`--grn=NAME` renders a
single model, and so on).

Class selection uses `--class=type_npc_zwerg` (Dwarf), or another supported
`type_npc_*` class directory. The selected class must have a matching retail
template, a mapped body model, and an authored `StartPosition`; startup exits
with an error instead of silently substituting another class. All eight class
body mappings now include the Vampiress's native day body, `VLADY_D.GRN`
(class/type 6). `VLADY_N.GRN` is her second form, not a ninth selectable class.
This does not establish day/night transformations or completed tutorials.
Selected-class dialogue now bootstraps, but ordinary talk and completed
in-world quest/dialogue journeys remain unqualified.
Encounter statistics and combat arts use that same selected template (or
`--hero=<pax>` import), and encounter scripts use the selected campaign tree.
The fixed demonstration quest is still not a complete campaign quest scheduler.

`--save=<file.json>` and `--load=<file.json>` use engine-owned session saves,
not retail `gameNN.pak` files. Schema-4 saves carry the hero class, progression,
items, trigger states, dialogue/NPC bindings and exact content-profile identity.
Launch with the matching `--class` and the same selected mod packages/content
when loading. Class/profile mismatches refuse before live state is replaced.
Older identity-less saves are refused rather than guessed into new numeric
definitions. For example, use `--class=type_npc_zwerg` for saving and loading
a Dwarf, and retain the same `--mod` selection.
Composite continuation is not yet qualified: durable tasks/combat clocks,
actor-ID gaps and malformed-state transactionality remain release blockers.

Repeat `--mod=<directory>` to select data-only packages. A package's `mod.json`
declares an ID/version, exact-version dependencies, and logical runtime files:

```json
{"schema":1,"type":"data-only","id":"my-items","version":"1","dependencies":[],"files":{"pak/items.pak":"pak/items.pak"}}
```

Dependencies load first; explicit selection order resolves independent ties;
the last package wins a whole file. Startup prints order, winner, and
provenance. A directory without `mod.json` becomes one explicit
content-addressed package. An items-only mod retains the base `weapon.pak`;
sibling dependencies resolve independently.

The same resolver covers admitted archive, world, balance/script, resource,
and template data. Outside paths, user saves/config, and derived caches are
not redirected. Missing/cyclic dependencies, escaping or symlinked package
paths, executable plugins, invalid archive ranges, and over-budget `.bin`
replacements are refused. The script/table replacement ceiling is 64 MiB.
Record-level merges and new record namespaces are not implemented. Arbitrary
GDScript/PCK/native code is not supported; retail bytecode still refuses
unsupported executable behavior instead of pretending to run it.

Profile identity hashes full runtime data and executable-table inputs once at
startup, using bounded streaming reads. It is not a path/mtime shortcut:
same-size byte changes produce a new identity. This conservative startup I/O
has not been qualified as a performance guarantee. Mounted inputs must remain
unchanged for the session; changing content requires restart, not hot reload.

Windowed startup shows a live verification status while one owned worker
hashes private file inputs. The main thread mounts the result only after
joining; no gameplay reads a partially resolved profile. Closing during
verification joins the worker before teardown. Headless batch startup remains
synchronous so existing `--quit-after` frame contracts are preserved.

Decoded terrain textures are cached under `user://tex-cache/v2/`. Entries are
keyed by the source texture bytes and cache/decoder version, so replacing an
archive at the same path does not reuse stale pixels. Truncated or wrong-sized
cache entries are discarded and decoded again from the archive. These are
disposable derived files, not bundled game assets.


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
movie_player.gd  media lifecycle controller (owns a _process; not in view/)
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
| `movie_player.gd` | The asynchronous conversion/playback/return controller. Owns its per-frame lifecycle outside the passive `view/` layer. |
| `drive.gd` | `--drive=`/`--shots=`: plays a timeline of scripted input and captures at stated milliseconds. Speaks the retail autopilot's own `ms verb args` grammar, so one script drives both engines. Refuses `--shots=` at anything but 1024×768 — the only size retail can be captured at. Front-ended by `tools/drive/session.sh`. |
| `world/` | Simulation: `sim.gd` fixed-tick loop, actor registry and state, movement, path windows, walkability, interiors, record/replay. |
| `view/` | Rendering and passive presentation: streaming, Granny/player/cursor views, rig placement and the inventory panel. |
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
  [tools](https://github.com/openheilig/tools) repo, so the two implementations can be diffed byte for
  byte. Two independent decoders agreeing is the evidence; one decoder looking
  plausible is not.
- `checks/` holds single-purpose gates, each answering one question against the
  retail data.
- The replay harness gates simulation changes on identical output.

Most component checks run headless and state their command in the header.
Display/audio probes, including `probes/movie_smoke.gd`, require an actual
graphical/audio run; headless success does not prove pixels or sound:

```
godot --headless --path . --script res://checks/floor_check.gd
```

## Related

This is one of three repositories:

- [research](https://github.com/openheilig/research) — what the formats are, and how each finding was
  established.
- [tools](https://github.com/openheilig/tools) — the analysis and extraction tools, and the Python half
  of every parity gate.

## Licence

MIT — see [LICENSE](LICENSE). Covers this source only; it grants no rights in
Sacred or Sacred Gold.

## Legal

Sacred and Sacred Gold are the property of their respective rights holders.
This project is an unaffiliated, clean-room reimplementation of the engine
that reads data the user already owns. No game data is included here.
