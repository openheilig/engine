# 0.0.1 — playable Seraphim retail slice

**Status:** Approved scope, unreleased. Publishing the development repositories does not complete this milestone.
**Scope decision:** Playable Seraphim slice selected on 2026-10-05.
**Goal:** Run one real Ancaria opening journey through ordinary controls, with retail-equivalent presentation and consequences: start → walk → talk/quest → fight → loot/equip → save → restart/load → continue.

This contract controls **0.0.1 release scope**. The [retail-parity implementation plan](implementation-plan-2026-09-29.md) remains the subsystem reference and longer-term roadmap. Its broader class, campaign, service, compatibility and modernization work is not automatically part of this release. Complete a route, not another decoder census or engine rewrite.

## What will work

- A user supplies a legally obtained Sacred Gold installation; the engine reads it at runtime. Source and eventual engine-only packages contain no game assets or converted caches.
- Seraphim, Ancaria, the authored Silver Creek opening at cell 3236,2511: actual starting attributes, equipment, position/layer and initial quest state, not the demonstration encounter's state.
- Continuous click movement and camera follow through the chapel and the bounded exterior route, with native support heights, collision, doors/storeys and correct roof/wall admission where the route encounters them.
- Authored NPC appearance, identity, placement, movement and interaction; original dialogue and choices, with the quest and journal changes those choices actually cause.
- One actual retail encounter reached by that route. Targeting, approach, animation, hit/block/damage, retaliation, death, rewards and the demonstrated combat-art behavior must follow recovered retail contracts.
- Real dropped item instances, pickup, inventory and equip/unequip through an actionable interface. The displayed weapon, statistics, ownership and saved state agree.
- The visible route's world, hero, NPCs, shadows, lighting, animation chronology, cursor, HUD, inventory/dialogue and audio agree with the declared retail reference. Sacred's combat-art recovery is not replaced with an invented mana pool.
- Engine-owned session save and restore through normal controls, including a process restart. Actors, items, progression, quest/dialogue bindings, world state and pending durable script work resume consistently. A save is bound to the exact content profile.
- A repeatable, state-aligned showreel capture route and an asset-free, documented way to run the released engine.

This is a **bounded route promise**, not certification of every cell in Ancaria. Existing exploration or class-selection flags outside that route remain experimental unless separately qualified.

## What will not be promised

| Outside 0.0.1 | Boundary |
|---|---|
| Complete Ancaria or Underworld campaigns | No full-campaign progression, endings or all-side-quest claim. |
| All eight playable classes | Native body support is not complete tutorial, ability or form support. Vampiress/Daemon transformations and Dwarf-specific systems are not this slice. |
| Every art, skill, weapon and item roll | Only behavior actually used by the chosen route is certified; unsupported operations must refuse explicitly. |
| Every service | Trading, smithing, combos, rune exchange, stash and horses are excluded unless the frozen route genuinely requires them. |
| Multiplayer | No LAN, internet, co-op or server compatibility. |
| Retail world-save interchange | Engine JSON sessions are not retail `gameNN.pak` saves. A hero `.pax` reader is a separate compatibility feature. |
| Complete retail menus, Extras and cinematics | Full menu/movie coverage does not block the selected gameplay reel. A cinematic is required only if the frozen retail route actually invokes it. |
| Arbitrary executable mods | No GDScript/PCK/native plugins or claimed arbitrary-code sandbox. Existing data-only profiles remain experimental; the fidelity reel uses an unmodified base profile. |
| Broad platform/build/locale support | Initial qualification is Linux, Forward+/Vulkan and the measured LGP retail-data installation. Windows Gold ENG/RUS binaries are independent semantic cross-checks, not proof of an engine platform or locale port. |
| Performance superiority | No “faster than retail” claim without matched route, quality and state measurements. |

## Meaning of 1:1

“Looks similar” and a passing regression ratchet are insufficient. Acceptance has four separate gates; a result cannot average one failure away with another success.

1. **Content/state:** Same retail build/data identity, class/template, difficulty, location/layer, actor/handle identities, equipment, quest/dialogue/world state and relevant random decisions. Record commands, resulting state and causality at every checkpoint.
2. **Chronology:** Same movement, actions, NPC paths, animation selection/phase, dialogue/event order and sound triggers against a documented simulation timeline. Freezing an idle pose can validate a still, not a walking/combat reel.
3. **Presentation:** Compare the complete 1024×768 frame, including HUD, actors and cursor, plus the actual audio events. Do not hide actors, crop away failed UI, use a replacement hero, choose an easier state or post-align images to make the comparison pass. Strict aligned deterministic frames require zero unexplained differing pixels. A backend-specific difference remains a named failure unless a separate, explicitly approved exception changes the claim.
4. **Interaction/persistence:** Real input produces the native consequences; save/restart/load preserves them and continuation does not duplicate rewards, actors or tasks. A batch flag or a direct test-host call cannot substitute for the player-facing journey.

Retail's own repeated runs establish temporal/random variability; they do not authorize a blanket pixel allowance or a hidden mask. Store per-region deltas and mean error for diagnosis, but neither a nonzero percentage nor an improved mean error is the release verdict.

`tools/parity/start_scene_gate.sh` in the tools repository is a **historical world-band regression ratchet**. Its nonzero baseline, 0.10 percentage-point tolerance and advisory HUD band mean PASS does **not** establish this contract. The existing engine scenario runner compares engine repeats; its frozen poses and advisory travel pixels do not establish retail equivalence either. Preserve those instruments without relabeling them as the 0.0.1 gate.

## Frozen showreel route: required evidence before implementation resumes

The opening anchor is known: Seraphim template `hero01.ptx`, chapel sector 50,39, authored start cell 3236,2511 and quest 1's `novizin1` handle (`res:17095`, creature 679, destination 3237,2514). That is **not yet a recovered end-to-end quest/combat route**.

The first release-blocking work item records the actual retail opening and freezes the following route manifest from observed behavior:

| Checkpoint | Required witness |
|---|---|
| C0 — ready opening | Build/content identity; template, HP/loadout, start/layer; initial quests; visible actors and camera. |
| C1 — chapel exit/travel | Exact input destinations and resulting player/NPC cells, support/storey/trigger state; moving and arrived frames. |
| C2 — authored conversation | Actor handle/type/cell, dialogue/procedure identity, exact selected choices, accepted/declined outcomes, journal/compass state. |
| C3 — native objective/encounter | The quest/script/world cause for the encounter, foe identity and statistics, actions and event timeline. |
| C4 — death/reward/loot/equip | Native reward and drop-generation inputs/outcomes; acquired instance, ownership/slot, resulting hero stats and appearance. |
| C5 — restart/continue | Save before exit; fresh-process load; same authoritative state; resumed route with no replayed reward or lost script/dialogue binding. |

Keep exact trace/capture/save evidence private. Commit only our authored manifest and descriptions of the observed contracts. Do not invent the currently missing dialogue, objective, foe, reward or drop witness. In particular, the existing quest-74 demonstration and its port-authored kill/reward connections are **not** an approved replacement for C2–C4.

The reel records this same ordinary-input run. Edited excerpts may show the checkpoints, but a separate continuous run must prove the whole journey. No fabricated transitions, injected loot, automatic test-only kills, skipped failures or claim that missing UI is intentionally retail-equivalent. Captures stay outside the source repositories; this publication does not authorize uploading retail media.

## Release-blocking work, in dependency order

Each row is one independently rejectable outcome. Read its source and research before editing; update the session/save contract with every newly durable field. Use the existing modules, not parallel state owners or a new engine.

| Order | Outcome and existing ownership | Acceptance |
|---|---|---|
| 1 | Freeze the native route and aligned oracle. E1/F; engine `drive.gd`, `tools/checkpoint.gd`, `tools/scenarios.json`; tools `drive/` and `parity/`; research `engine/game-wiring.md`, `formats/script-bytecode.md`. | Actual retail C0–C5 run recorded; install/settings/state/timing identities and negative controls documented. Unknown causal links remain explicit blockers. |
| 2 | Restore visible opening and continuous travel. W1/F; `main.gd`, `iso_camera.gd`, `world/{sim,movement,walkable,interior}.gd`, `view/{sector_view,floor_view,player_view,hud}.gd`. | Hero and required NPCs remain correctly visible; native chronology/support/admission; no unexplained IDLE/WALK oscillation or walk-in-place; full-frame opening/travel parity. |
| 3 | Complete causal talk/quest and script lifecycle for the frozen route. S1/G; `world/{dialogue,script,quest_cast,quest_log,talk_command,game_session}.gd`, `formats/{startcode,vectoren}.gd`, `view/dialogue_view.gd`. | Real approach → selected choice → native quest/journal/world effect; refusal is pre-mutation; handles and scheduled work survive view unload and restart. Validate both choice branches and cancellation. |
| 4 | Replace demonstration combat/item shortcuts on the route. C/B/U; `world/{ai,combat,encounter,actor_stats,item_state,game_session}.gd`, relevant `formats/` readers, inventory/loot/player/HUD views. | Native target, range, cooldown, loadout, HP, damage, death, reward and item generation; ordinary pickup/equip; no fixed fake drop, HP or quest completion. |
| 5 | Qualify the complete save/restart/load continuation. P; `world/{game_session,save_state}.gd`, dialogue/script/item owners and normal save/load UI. | Fresh-process C5 matches pre-save authoritative state and resumes behavior; wrong profile/class/schema and malformed state refuse without mutating the live session. No duplication after a second reload. |
| 6 | Complete route presentation, sound and runtime budget. U/A/Q/F; route views/HUD, audio/controller paths and profiled streaming/decoder code. | Complete frame and event/timing parity, visible feedback during loading, real audio observed, measured traversal/combat/UI frame distributions and bounded memory across repeat/revisit/reload. |
| 7 | Qualify and package, then tag. X/Q; engine-only export, public checkout instructions, release notes and artifact/history admission. | Fresh public checkout and declared retail install run C0–C5; inspected source/package contains no retail/private bytes; every gate below passes. Only then create `v0.0.1`. |

Do not reopen all eight classes, optional movies, arbitrary mod APIs or campaign services while this route is incomplete. Research is demand-driven by a named failed checkpoint, not a new whole-corpus sweep.

## Runtime and distribution gates

- Declare the exact Godot build, renderer, OS/GPU, resolution, install/content identity and settings in the qualification report. The currently exercised engine is Godot 4.7.2, Forward+/Vulkan on Linux; another backend is a separate qualification, not a fallback for failing pixels.
- Performance target on the declared reference hardware: 60 Hz, route p95 frame time ≤16.7 ms, p99 ≤33.3 ms, no >100 ms stall during settled ordinary traversal; input/loading feedback within 100 ms. These are release targets, **not current measurements or guarantees**. Record actual time-to-ready and memory/VRAM bounds; include warm/cold process/cache conditions. Never report offline fixed-FPS capture time as throughput.
- Run the existing checks and independent-reader/replay gates, but also exercise the actual visible/input/audio/save journey. A count of passing checks is not retail parity.
- Repeat from a fresh process and after save/load, with negative controls for lost input, wrong quest/actor/profile state, unfinished loading and a visibly displaced actor/HUD frame. Each must refuse or fail, not produce a reassuring score.
- Audit every reachable published Git object and each exported package. No retail assets, converted textures/models/audio, caches, saves, screenshots, traces, symbol tables, databases, decompiler output, third-party proprietary binaries or credentials.
- Engine-only export is permitted by the 2026-10-04 policy in the implementation plan. This does not permit bundling retail data, private reference media or an install with the engine.

## Current evidence and blockers — 2026-10-05

The development snapshot is not a completed 0.0.1 candidate. A fresh 1024×768 Forward+/Vulkan production run opened the Seraphim world, accepted a click (`click_goal` cell 3243,2508), and displayed the `I` inventory panel. Actual presented frames showed an obscured hero and a text-only empty inventory. The run used Dummy audio and the retail configuration had sound muted; it does not prove audible playback. Startup also printed repeated IDLE↔WALK transitions. These observations block fidelity/travel/presentation claims; they are not causes inferred from pixels.

Source includes authoritative session/item/progression work, selected-class dialogue/talk integration, native-body mappings, data-only profiles, engine-owned saves, audio and movie paths. Presence and component checks do not establish the combined C0–C5 journey. Remaining exact causal/timing/UI/stat/save contracts must pass the gates above. No 0.0.1 tag, finished reel or full-game parity claim is authorized by repository publication.

## GitHub tracking

[Milestone 0.0.1](https://github.com/openheilig/engine/milestone/1) remains open.
Work order follows the contract, not issue-number or creation order:

1. [Native C0–C5 route and fail-closed oracle](https://github.com/openheilig/engine/issues/2).
2. [Opening visibility and continuous travel](https://github.com/openheilig/engine/issues/6).
3. [Ordinary talk and causal quests](https://github.com/openheilig/engine/issues/3).
4. [Native combat, loot and equipment](https://github.com/openheilig/engine/issues/7).
5. [Transactional save and restart continuation](https://github.com/openheilig/engine/issues/5).
6. [Route UI, audio and runtime budget](https://github.com/openheilig/engine/issues/1).
7. [Fresh-checkout/package qualification before tagging](https://github.com/openheilig/engine/issues/4).

The separate [historical findings-log repair](https://github.com/openheilig/research/issues/1)
preserves provenance rather than silently rewriting old evidence. Publication
does not authorize resuming the entire broader implementation plan.
