# Production parity roadmap

> **Superseded for implementation ordering by the
> [2026-09-29 revision plan](implementation-plan-2026-09-29.md).**
> This document preserves the September17 benchmark history. Its score is not
> a current passing baseline: the fresh September29 run refused a metric
> because repeated actor captures differed. The current loader also uses a
> bounded120second readiness deadline, not the600frame behavior described
> below. Read the revision's capability/evidence distinctions before acting
> on an old checkbox.

## Goal and current boundary

Deliver a single-player Sacred Gold reimplementation on Godot that reads the
user's retail install at runtime, with close visual and behavioral parity.
No retail assets, captures, decompiler output, or databases may be published.
Multiplayer remains out of scope. This is a roadmap, not a claim that the
missing systems are implemented or that their designs have been recovered.

The current engine README calls the project pre-alpha: a world viewer with a
simulation core and one completed scripted fight. It explicitly lists inventory,
skills, dialogue, audio playback, and save/load as absent. Before implementing
any of these, reconcile the relevant source with `analysis/open-questions.md`
and the format documents; do not convert an old status paragraph into a spec.

## Established benchmark — 2026-09-17

Run from the private workspace:

```sh
bash autoresearch.sh
```

Implementation: `tools/autoresearch_benchmark.py` in the engine repository.
Canonical wrapper: `donotpublish/autoresearch.sh`, outside Git by policy.
Artifacts: `donotpublish/tmp/autoresearch-start-scene/`.
Dependencies: Godot 4.7.2.stable.arch_linux.ed1daf0bf, Xvfb/xvfb-run,
Python 3 with Pillow, and the existing private install and reference capture.
No network requests occur during measurement.

The workload launches the actual default Seraphim scene twice at 1024x768,
Forward+/Vulkan, fixed 60 FPS, capturing four simulation seconds after the
existing scene-settle boundary. Audio output uses Dummy. Both renders must be
pixel-identical or the benchmark fails without emitting metrics. A timeout,
Godot error, missing output, changed reference or Godot version also fails.
The reference is the existing local retail capture at
`tmp/actor-pose-20260907/startgate-after1256/retail-4000.png`, SHA256
`f59793607a489d2bdf45ee90df51f0bdd79aeb7b63c46267c1567ca6fbd58820`.
It was inspected as a real cathedral gameplay frame, not recaptured this session.

| Metric | Baseline | Interpretation |
|---|---:|---|
| world_delta_pct (primary, lower) | 5.05 | Any RGB channel differs; rows 0–599 |
| world_mae | 1.85 | Mean per-pixel maximum channel error, 0–255 |
| taskbar_delta_pct | 11.01 | Rows 600–767; historical band name |
| taskbar_mae | 6.96 | Same error definition |
| full_delta_pct | 6.35 | Entire frame |
| full_mae | 2.97 | Entire frame |
| repeat_delta_pct | 0.00 | Exact same-build repeat requirement |

The benchmark reuses `analysis/tools/parity/png_delta.py`; it does not update
`start-scene-baseline.tsv`. This is a new fixed-schedule baseline, not a direct
continuation of the old wall-clock `Drive.run` experiment. Identical renders
were observed on the current NVIDIA/Vulkan stack; this does not prove
cross-GPU determinism. A renderer, driver, retail-data or capture-protocol
change requires repeat validation and an explicit baseline review.

Limitations: one view, one hero, no input route, no combat or save/load coverage.
The reference's animation phase is not synchronized to Godot's pose. A metric
improvement must not remove content, change framing, mask errors, or hard-code
reference pixels. The existing settle helper has a 600-frame ceiling rather
than an explicit failure on exhaustion; strengthen that contract before
expanding this to heavy scenes. Never call this score “percent game complete”.

## Ordered work and acceptance gates

### 1. Measurement integrity and broader references

- [x] Establish the fixed, offline start-scene workload and repeat control.
- [ ] Add an explicit failed-settle verdict, then exercise an intentionally
  exhausted settle budget to prove incomplete scenes cannot pass.
- [ ] Record synchronized input/tick routes for walking, entering/exiting a
  building, NPC interaction and a scripted fight. Preserve captures and their
  build/configuration provenance locally; publish only authored descriptions.
- [ ] Expand to all seven player classes, both campaigns, outdoor terrain,
  liquid sectors, occlusion boundaries and non-default resolutions.
- [ ] Set human-approved visual tolerances by scenario after measuring each
  oracle's repeat noise. Keep world, actor and UI errors separate.

Acceptance: repeatable routes; no menu-only, blank, stale or unfinished-loading
capture can yield an accepted score. Existing decoder and replay gates remain
independent of the screenshot score.

### 2. Close visible start-scene discrepancies

Relevant existing files: `view/player_view.gd`, `view/model_view.gd`,
`view/sector_view.gd`, `view/hud.gd`, `main.gd` and `shaders/`.

- [ ] Recover actor pose/skin/material differences using the native Granny
  evidence and independent builds, then measure the hero region and full world.
- [ ] Resolve the novice nun's placement/pose and marker against an equivalent
  retail quest state. The benchmark screenshots currently disagree visibly.
- [ ] Restore portrait contents, gauges and combat-art presentation from retail
  data and recovered composition rules; no stand-in art or invented fractions.
- [ ] Verify exterior edges, object ordering, shadows and liquid reflections on
  dedicated scenes so a cathedral-only improvement cannot conceal regressions.

Acceptance: each edit has retail evidence, a counterexample/control, and a
fresh render. Do not optimize the primary score by hiding the hero or NPCs.

### 3. Complete one playable vertical route

Existing data/simulation boundaries: `formats/`, `world/`, `view/`; readers stay
plain RefCounted runtime readers, and simulation stays separate from rendering.

- [ ] Inventory/equipment: pickup, stack/split, equip/unequip, requirements,
  stat recomputation, appearance and persistence; verify the same retail items.
- [ ] Combat/skills: feed real equipped statistics into damage/resistance,
  resource costs, cooldowns, effects, death and rewards. Compare state changes
  and timing, not just whether an animation played.
- [ ] Dialogue/quests: branching conditions, effects, journal and quest-state
  transitions; unsupported opcodes must remain explicit failures.
- [ ] Audio: music transitions and positional effects selected from retail data;
  verify actual output, mute/settings behavior and resource teardown.
- [ ] Save/load: reproduce the intended persistence contract, including equipped
  items, quests, actors, location and relevant timers. Exercise write/load/write
  and interrupted-write recovery; do not overwrite a user's retail saves.

Acceptance: new game → movement/interior transition → dialogue → quest combat
→ loot/equip → save → restart/load → continue, with observed retail-equivalent
outcomes. One route does not establish full-campaign completion.

### 4. Campaign breadth and compatibility

- [ ] Expand the vertical route coverage to each hero and both campaigns.
- [ ] Enumerate every script opcode and content feature encountered by campaign
  routes; distinguish decoded, implemented and behaviorally verified states.
- [ ] Exercise locale, install case sensitivity, missing/corrupt data, settings,
  input rebinding, window/fullscreen changes and supported resolutions.
- [ ] Verify the supported retail build matrix; cross-build agreement is evidence
  for semantics, not permission to assume identical binary addresses.

Acceptance: an explicit support matrix with reproducible scenarios and no
silently skipped campaign-critical effects.

### 5. Release qualification

- [ ] Profile representative travel/combat/loading and long-session memory; set
  hardware-specific frame-time and memory ceilings from measurements.
- [ ] Run fresh-install and cold-cache checks without developer-local state.
- [ ] Document remaining incompatibilities and third-party/provenance licensing.
- [ ] Establish off-machine backup/remotes for authored repositories only, after
  checking current configuration and obtaining publication authorization.
- [ ] Reconcile the older no-export policy with the intended distributable
  asset-free engine before adding release/export automation.

Acceptance: supported-platform end-to-end runs, no known data-loss paths,
bounded resource growth, reproducible installation and a licensing-clean
asset-free distribution approved under the project's publication policy.

## Execution discipline

Choose one unchecked outcome at a time. Load its Godot/process skills; read
existing research before reversing. Use IDA/Ghidra only for a named missing
semantic fact, cross-check builds, and confirm consequential behavior live.
Keep the benchmark, oracle files and measurement definitions outside an
optimization's writable scope. A visual improvement is insufficient if it
breaks replay, reader parity or the exercised gameplay route.

## Research used for this setup

- Godot 4.7 Movie Maker documentation, resolved through Context7/find-docs:
  https://docs.godotengine.org/en/4.7/tutorials/animation/creating_movies.html
  — fixed-FPS capture rather than wall-clock screenshots.
- Godot seeded RNG documentation:
  https://docs.godotengine.org/en/4.7/classes/class_@globalscope.html
  — explicit seeds where the workload uses randomness.
- GitHub offline-rendering example (historical Godot 3, not an API authority):
  https://github.com/Calinou/godot-video-rendering-demo
- Godot forum input/tick replay discussion (historical community guidance, not
  proof of engine-wide determinism):
  https://forum.godotengine.org/t/how-to-record-and-replay-game-events-demo-files/20626

Wigolo was requested and its skill loaded, but neither its MCP tools nor a local
executable were available. Context7 and the available web search/read tools were
used instead. No third-party implementation was copied into the engine.
