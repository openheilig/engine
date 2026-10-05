# Tooling and verification

**Status:** Development-snapshot audit, 2026-10-05. Installed, mounted, exercised and release-qualified are different states.

## Dependency tiers

| Purpose | Required | Not required |
|---|---|---|
| Play the engine | Godot 4.7; Forward+/Vulkan-capable graphics drivers; legally owned compatible Sacred Gold install; working audio output for sound | Python, Node, AI skills/MCP, IDA, Ghidra, Wine, retail shims |
| Current media CLI/probe | User-provided `ffmpeg`/`ffprobe` with Theora/Vorbis support; graphical/audio run | Bundled codecs, converted retail video in the repository |
| Maintainer checks/captures | POSIX shell, `timeout`, Godot; Python/Pillow for image tools; Xvfb/xauth for isolated graphics; some tools additionally use NumPy or ImageMagick | Research databases or AI tooling for ordinary component checks |
| Retail oracle/reverse engineering | Owned runnable retail copy, appropriate local launcher and our rebuilt 32-bit shims; optionally multilib GCC, GDB, apitrace, IDA/Hex-Rays or Ghidra/JDK | A public copy of our private install, databases, captures or decompilation |

The exercised engine build is `4.7.2.stable.arch_linux.ed1daf0bf`, Linux, Forward+/Vulkan. Other platforms/backends/build strings are not implicitly qualified. Godot's import cache is regenerable, not published. On a fresh checkout import the project before standalone script checks:

```sh
godot --headless --editor --path /path/to/engine --import --quit
sh /path/to/engine/run.sh --install=/path/to/owned/sacred
```

Explicit install selection is the reliable public entrypoint. The engine then remembers it in `user://openheilig.cfg`; no developer absolute path or purchased assets are needed in `res://`. Python/AI tools are not part of this launch chain.

## Existing checks: how to run and what they prove

```sh
sh /path/to/engine/run.sh --checks --install=/path/to/owned/lgp-install
sh /path/to/engine/run.sh --layers --install=/path/to/owned/lgp-install
sh /path/to/engine/run.sh --flags
```

The check/layer wrapper forwards the selected install. These checks are currently **corpus-qualified component checks**, not universal tests against any edition. Some require the LGP data and its shipped `save/game01.pak`. The optional cross-build UI-table arm needs an owned Gold Windows executable:

```sh
sh /path/to/engine/run.sh --checks --install=/path/to/owned/lgp-install --pe-exe=/path/to/owned/Sacred.exe
```

Without `--pe-exe`, that PE arm reports SKIP, not cross-build success. Engine-owned check scratch and converted caches go under `user://`; do not commit or upload them. Individual checks can be run with `godot --headless --path /path/to/engine --script res://checks/NAME_check.gd -- --install=...`.

| Instrument | Valid proof | Invalid conclusion |
|---|---|---|
| Component checks | The named decoder/state/command invariant exercised by that check | Completed player journey or retail visual parity |
| Independent reader parity | Agreement on declared sampled inputs from two implementations | All fields/builds or complete gameplay |
| Record/replay | Repeated simulation intent/output and divergence controls | Native quest causality or correct rendering/audio |
| Windowed production smoke | The actual commands, frames and state observed | Other unexercised controls, paths or audible playback with Dummy/muted audio |
| `tools/verify_scenarios.py` | Existing engine spawn/walk repeat workload, subject to the limitations below | A post-walk checkpoint, reference-retail equality or 0.0.1 completion |
| Tools `parity/start_scene_gate.sh` | Historical world-band regression ratchet | Zero pixel difference, HUD parity or a completed 1:1 reel |

Current scenario limitations are release blockers, not hidden allowances: state is captured before the input drive; declared expected state is not enforced; travel pixels are advisory; the runner has missing-output/empty-selection weaknesses and its advertised reference `--check` mode is not implemented. It assumes the private `godot-port`/`install` workspace aliases and pins the exact Arch Godot build. Do not use a PASS from it as certification of the selected Seraphim route.

The start-scene ratchet permits nonzero disagreement, gates only the world band and can rewrite its tracked baseline on improvement. An existing-directory invocation is therefore not strictly read-only. Preserve its historical measurements; do not silently change the reference/baseline or call the ratchet a strict equality gate.

## Tools repository and private oracle boundaries

[OpenHeilig tools](https://github.com/openheilig/tools) contains authored readers, analysis helpers, capture drivers and shims. It is not a bundled runnable retail installation.

- Explicit-input readers and image analysis are the portable starting points. For example, `python3 TOOLS/parity/png_delta.py PRIVATE/retail.png PRIVATE/port.png --mae` analyzes existing frames without launching either game. Its rounded percentage can print `0.00` for a nonzero changed-pixel count; strict release acceptance must retain the exact count.
- `SACRED_INSTALL` and `SACRED_PORT` are used by some tools. They are **not universal overrides**, and the engine's install selection is its CLI/config mechanism. Several legacy wrappers still call through private `analysis/tools` aliases. Check the invoked script rather than trusting the old blanket fresh-clone promise.
- `look.sh`, `shot.sh`, `session.sh`, replay/follow/race drivers and probes launch processes and write output. Some legacy retail drivers also delete shared `/tmp` captures/logs, terminate `sacred`, change persistent retail preferences or use the private `play.sh` launcher. Do not run them as read-only health checks, concurrently against another owned oracle run, or blindly in public CI.
- Merely setting `TMPDIR` cannot redirect the hardcoded capture/profile paths inside `autopilot.c`. The current private-scratch/process-ownership cutover is still incomplete in that chain. Use the documented private workspace recipe until the whole chain is corrected.
- Binary patch/save helpers can mutate their inputs or write executable outputs. `live/patch_1002.py --check` has an explicit no-write mode; its default does not. Read each header and retain originals before an intentionally mutating research operation.
- Ghidra/IDA rename, type, comment, open, import, patch and save operations are not read-only. A session-list reply is not a successful decompilation or a runtime witness.
- Old Bevy/OBJ exporter and video-overview probes are not engine prerequisites or exact frame oracles. Bevy stays private; no converted model/video/image is a publication candidate.

No automatic public CI, GDScript lint pass or complete standalone retail-driving setup is claimed by this snapshot. The [0.0.1 contract](milestone-0.0.1.md) requires a fresh-checkout and engine-only package qualification before release.

## Skills, MCP and optional research tools

| Tool/workflow | Audit evidence | Correct role |
|---|---|---|
| Godot + Xvfb | Fresh production input/render run exercised | Runtime and actual surface verification |
| IDA MCP | Mounted routes; session enumeration replied with no open database | Primary existing private corpus/Hex-Rays workflow once an owned database is opened; no new function-output proof from enumeration |
| Ghidra 12.1.2 + JDK 21 | Installed; prior process-local provider admission recorded in research finding 1385 | Optional independent native analysis, not redistributed |
| REA 3.1.0 | Installed CLI; no REA MCP routes mounted here; prior PE import succeeded but requested function timed out | Selective second opinion; not original-source recovery or replacement for our corpus. Do not repeat bulk imports/setup to claim progress. |
| graft 0.20.0 | Actual map covered one Python file, six symbols, eighteen edges | Limited source navigation; no GDScript coverage or engine gate. Queries may refresh local caches. |
| Context7 CLI 0.5.12 | Installed metadata; Context7 MCP not mounted | Optional Godot/library documentation; not evidence of retail mechanics |
| wigolo MCP | Not mounted here | A skill mentioning it does not make it callable; use available read/search sources instead |
| Godot AI/MCP 5.0.5 | Installed metadata; no mounted Godot route or required project addon integration qualified | Not a working editor/runtime dependency in this project |
| LSP/lint | No language servers configured for this assistant project; no GDScript lint executable qualified | Do not claim a lint/editor diagnostic pass. Use the real Godot import/runtime checks. |
| Stitch | Mounted, not exercised or needed | Not a retail engine/release verifier |

Process skills are useful procedure, not proof. Use research discipline and result/control/private-output rules; read current source and format documents before reverse engineering. The project's retail-data reader map was stale (it claimed no weapon reader despite `formats/weapons.gd`), so skill inventories must be checked against current files. Generic Godot recommendations for authored Resources, autoloads, GUT/gdUnit4 or avoiding pixel comparisons do not override this project's runtime `RefCounted` readers, existing check convention and explicit retail-parity contract. Do not install/upgrade or change persistent MCP/global configuration merely because a skill suggests it.

Optional-tool metadata and the earlier REA assessment are not fresh execution claims. The maintainer's installed software is not a dependency list for players. Public source does not contain the private credentials, databases or binaries needed for optional proprietary research workflows.

## Current qualification

The current development snapshot reaches the windowed Seraphim scene and accepts input; the `I` text panel is visibly reachable. That observation does not close ordinary talk, pickup/equip, save UI, canonical combat/rewards, movement/actor visibility or complete save continuation. Audio requires an actual audible or mixer-side witness, not a printed `playing=true` on a muted/Dummy run.

Qualification of **0.0.1** requires the selected authored C0–C5 Seraphim route, after-action state checkpoints, aligned full-frame retail presentation, actual audio and fresh-process save/load continuation, plus negative controls and inspected asset-free artifacts. Research tools and passing component totals cannot waive those requirements.

### Historical findings-log gate

The research ledger's shape checker currently rejects five older anomalies:
decimal-bearing slugs in findings 996/1129, missing paragraphs 1172/1173 and
the physical ordering of 1151 before 1150. New publication rows are validated
as four fields. Existing evidence is kept append-only; repairing provenance
requires tracing the original records, not silently renumbering, inventing
missing findings or pretending this checker passed.
