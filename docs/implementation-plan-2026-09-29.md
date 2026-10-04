# OpenHeilig retail-parity and modernization implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development` or `executing-plans` only after the user authorizes implementation. Execute one independently verifiable outcome at a time. Checkboxes below describe future work, not work performed by this revision.

**Goal:** Deliver a modern, asset-free engine using the user's Sacred Gold resources, first through a genuine playable route, then complete single-player parity, with measured performance and explicit mod/platform support.

**Architecture:** Retain Godot, runtime `RefCounted` readers, the actor registry, fixed-tick simulation and recovered hybrid renderer. Add a resolved content-set boundary and authoritative session state as their consumers need them; all gameplay commands enter simulation, and views/audio/UI consume committed state/events. Extract responsibilities from `main.gd` during these cutovers rather than undertaking a standalone rewrite.

**Tech stack:** Current observed baseline Godot4.7.2.stable.arch_linux.ed1daf0bf, GDScript, Forward+/Vulkan, existing Python/shell research tools and retail oracles. Native extensions are conditional on measured need or an explicit codec requirement, not a planned language migration.

**Spec:** [Research audit and proposed product contract](../../research/engine/engine-revision-2026-09-29.md). This relative link is resolved from the engine repository's `docs/` directory via the sibling research repository.

**Status:** Proposal only. No engine implementation started. Research established current paths, product scope, several corrections and concrete RE entry points. It did **not** establish every class ability, item modifier or save-section semantic. Tasks with an unresolved semantic prerequisite must produce the stated evidence contract before code is authorized; they may not substitute guessed rules. This is a scope/dependency/acceptance plan, not a claim that all remaining rules are already executable specifications.

## Global constraints

- Read the user's own retail data at runtime; never ship extracted data, converted assets, reference captures, executable tables, saves, decompilation or proprietary analysis binaries.
- `formats/` remains on-demand `RefCounted` decoding. Derived caches go to engine-owned user storage, not `res://` or the retail tree.
- `world/` owns authoritative state and is independent of render residency and the active scene tree. Views never decide gameplay outcomes.
- Preserve recovered integer/floating conversion points, identity spaces, script ordering, affine scale/shear, encoded color and native draw order where relevant.
- Unknown required opcodes, content identities and unsupported versions fail explicitly. No silent fallback to another hero/install, no fake missing mechanics.
- Use shipping Gold to establish behavior. Armalion/demo are leads; names, class layouts and equal offsets alone are not proof.
- Strict-reference mode and modern enhancements are separate options with the same gameplay command/state core. Deviations must be named and independently tested.
- Multiplayer remains excluded under standing project policy. The deliverable is **single-player Sacred Gold parity**, not an unqualified1:1 product. Section14 records what literal whole-product parity additionally requires.
- Authoritative state/saves must not depend on loading speed, camera movement, display refresh or worker completion order.
- No untrusted GDScript/PCK/native DLL execution under a “sandboxed mod” claim.
- No implementation pass ends on parser/unit checks alone: exercise the changed player-visible route, and retain evidence privately.
- Every change updates the matching authored research/status documentation and a four-field findings row. Never rewrite old findings to hide a correction.

## 1. Decision and alternatives

### Recommended: complete the current engine in playable increments

Keep the now-substantial rendering and format investment. The first deliverable is not another static scene: it is new game→walk→talk→quest→fight→loot/equip→save→restart/load→continue through ordinary UI with real state. Repeat this loop while expanding coverage. This minimizes discarded work and exposes integration defects early.

### Rejected: finish all visual1:1 work before gameplay

It leaves scripts, ownership and persistence unexercised and rewards reducing a single screenshot delta. Actor chronology, equipment and quest state also determine the correct image, so rendering cannot be finalized independently of gameplay.

### Not justified now: engine/language rewrite

Measured costs are specific CPU construction, command rebuilding, decoding and navigation work. They do not establish that Godot itself makes the project impossible. A rewrite would discard verified behavior and reproduce the same semantic gaps. An isolated native decoder/geometry kernel remains an evidence-gated option.

## 2. What counts as progress

Maintain separate acceptance ledgers; do not average these into a “percent complete” number:

1. **Player journeys:** executed via production UI/commands, with durable state and retail-equivalent outcomes.
2. **Behavior/resource contracts:** known/implemented/production-used/observed across each supported corpus. A reader and a test do not imply a feature.
3. **Presentation:** scene/state/pose-aligned visual channels, audio events and UI interactions; exact versus tolerated differences stated separately.
4. **Performance/reliability:** startup, loading, travel, combat, frame percentiles, memory/VRAM, data loss and long-session behavior.

The existing `--fight` route is a diagnostic, not the interactive combat acceptance test. `AutoSave` request count is not saved state. A displayed new hero is not class support. Pixel equality is not script or campaign correctness.

## 3. Milestones and dependency order

| Milestone | Work packages | Observable exit |
|---|---|---|
| M0: trustworthy contracts | E, R0 | State-aligned scenarios, supported-install identity, explicit blocking facts |
| M1: coherent world | R1, W1, S0 | Correct travel/support admission; persistent actor/session identity independent of views |
| M2: authoritative character | C, P | Real stats/items/progression state with safe session persistence |
| M3: first real play loop | W2 + S1, B, U0, A0 | Persistent world/script integration; talk→causal quest→two-sided fight→loot/equip→restart/load→continue |
| M4: complete single-player scope | G, U1, A1 | All eight classes and both campaigns, services/transitions/endings and applicable difficulties |
| M5: strict compatibility | F, X | Declared retail build/save/media matrix and fidelity scenarios qualified |
| M6: modern moddable release | D, M, Q | Reproducible mod profiles, modern controls/UI, measured performance, asset-free distribution |

**Performance track Q starts at M0 and continues through every milestone.** Resource identity/cache correctness starts before mod UI, not after. Persistence begins with authoritative state, before a long campaign depends on it. Audio/UI are integrated while each interaction is built, not reserved for a final decoration phase.

Parallelism only after shared contracts: resource profiles and route instrumentation can proceed independently; navigation/script scheduling share actor identity; stats and inventory share item instances; audiovisual consumers can proceed once event payloads are frozen. One integration owner maintains session/command/save schemas. Never have concurrent workers independently invent actor IDs, clock ownership or resource precedence.

**Concrete execution waves:** (1) E1/R0 and the named semantic tickets;
(2) R1/S0 and Q0; (3) W1/C1 and P1 for the state they introduce;
(4) C2/C3 and their durable-state integration; (5) W2+S1 as one
world/script integration outcome, with P1 updated for tasks/handles;
(6) B1/B2 with U0/A0 consuming their real commands/events, producing M3;
(7) G/U1/A1; (8) F/X and D/M/Q qualification where dependencies permit.
P2 retail hero compatibility need not block the first engine-owned save loop.
P1's full cross-system acceptance grows with each real state owner and is
required again at M3; do not claim a movement-only snapshot is a complete save.
W2 and S1 deliberately share an acceptance boundary: neither a scheduler with
fake effect hosts nor world events delivered to a no-op VM may be called done.

## 4. Phase 0 — documentation discovery and semantic admission

### E0. Discovery completed by this revision

Read the audit before opening historical plans. It reconciles current source against manuals, recent findings, the corpus and live execution. Reuse these sources rather than repeating a global decompilation sweep:

| Contract | Existing authoritative entry points |
|---|---|
| Current engine composition | `main.gd`, `sacred.gd`, `world/sim.gd`, `world/actor_state.gd` |
| Retail product/UI | Gold/LGP/Underworld manuals and2.28 readme; audit§3 |
| Gold world admission | LGP80EE194/80EE244, ENG636C10/636D20, RUS637040/637150; corrected `research/formats/footprints.md` |
| Region/sector scripts | LGP829EFBC/829F9D4/829FAF4,825D7A2; `research/formats/script-bytecode.md` |
| HP/stats | LGP820E04C→81F4FFA, ENG5658F0, RUS565BA0; corrected `research/engine/combat-formulas.md` |
| XP/levels | LGP82164BC→8216294; learning-point block is not XP denominator |
| Resource overlays | Findings1258/1259; `research/formats/{install-inventory,pak-containers}.md` |
| Model/render behavior | Findings1247–1270; `formats/models.gd`, `view/{model_view,model_canvas,floor_view,sector_view}.gd` |
| Persistence | `formats/{pax,hero}.gd`, `research/formats/pax-saves.md`; hero versus full-world saves |
| Current performance | Findings1272–1275 and fresh audit§5; no valid new image score |

Allowed existing engine APIs include `Pak.blob/read_at/source_path`, `Hero` decoded properties, `Triggers.state/replace_state/set_bits/reset_bits`, `ScriptVM.run(code, offset, length, host)`, `ScriptVM.decode/can_run`, existing ActorRegistry operations and Sim command/path entry points. Read their current signatures before changing them. Do not infer unsupported behavior from the method name.

Godot APIs allowed for the planned boundaries: `FileAccess`, `PackedByteArray`, `Image`/`ImageTexture`, `RenderingServer`, `WorkerThreadPool`, `ConfigFile`, native `FileDialog`, existing audio-stream classes and exported-project tooling. Follow the audit's official links. `ResourceLoader` does not decode Sacred containers; `load_resource_pack` does not sandbox code; standard VideoStream playback is not proof of MPEG-1 support; generic Node3D TRS does not preserve the recovered full affine poses.

### E1. Establish semantic scenario manifests

**Files:** evolve `drive.gd`, `tools/autoresearch_benchmark.py`, existing tools-repo `drive/` and `parity/`; add an authored scenario manifest owned by the tools repo. Private captures/state traces remain outside it.

- [ ] Define each scenario by content/build/configuration identity, player/quest/world state, input commands, simulation time and capture channels.
- [ ] Replace loading-relative visual capture with “resources ready, authoritative checkpoint restored, specified ticks/actions/pose advanced, frame presented.” Include a real-time travel capture separately so pausing a snapshot cannot hide gameplay faults.
- [ ] Preserve strict repeat rejection; report state mismatch separately from visual mismatch. Do not silently reuse a reference from another quest/NPC position.
- [ ] Add negative controls: wrong state, unfinished load, missing actor, stale output, changed corpus, lost input and exhausted deadline must refuse a parity result.

**Produces:** reproducible scenarios and machine-readable outcomes, not new retail assets in Git.
**Acceptance:** two runs at the same semantic checkpoint agree within the declared deterministic channel contract; an intentionally different NPC/task state cannot pass as the same scene. The current2702-pixel repeat failure is not re-baselined away.

### E2. Finish high-risk semantic specifications before their code tasks

These are focused prerequisite tickets, not another open-ended research campaign:

| Ticket / blocks | Exact remaining fact | Required evidence before implementation |
|---|---|---|
| NAV / W1 | Which Gold predicate each actor/action uses; support resolution; coordinate-trigger index population/mutation | Follow80EE10C/80EE194 callers and index producers; compare ordinary/blocked/liquid/door/layer/actor cases, with both allowed and denied runtime outcomes |
| HP / C1 | Full81F4FFA inputs, field order, modifiers, current-pool authority and rounding | Same-process input/output samples for new hero, NPC, skill/equipment change, level change and damage; cross-check ENG/RUS offset differences |
| XP / C3 | Cumulative thresholds and full award modifiers, not just creature base reward | Disassemble x87/pow return flow in8216294/8213ED6; measure below/at/above level boundaries and points separately |
| ITEM / C2 | Equipment pool selection, instance rolls, modifier units/chance/conditions and recomputation order | Item acquisition/equip/unequip controls; record inputs and displayed/actual stats; raw aggregate helper is not authority |
| TASK / S1 | Condition/call/task/dialogue scheduling and completion causality | Trace selected real tutorial/quest chain; distinguish OnEnter from task progression, once-only effects and reentry |
| ART / B2 | Dispatch, timing and effect for each art family | Same action at two levels/gear states; recovery and effect/state comparison; branch/secondary-effect coverage |
| SAVE / P2,X1 | Full-world section ownership/version and restore order | Save→modify one state→save differential plus native load observation; ownership/sentinels and roundtrip witnesses |
| MEDIA / A1 | Shipped codec/profile-to-event mapping and timing | Actual audio/movie playback/skip/return; licensing/platform dependency decision |

Each ticket ends in a small versioned fact sheet: identity, inputs, outputs, ordering, side effects, integer/float semantics, supported builds, witnesses, counterexample, residuals. Existing named/cross-build facts are reused; unresolved rules never get plausible placeholders. Stop only the dependent task, not unrelated implementation with complete contracts.

## 5. Resource and session foundations

### R0. Recognized retail installation and explicit profile

**Modify:** `sacred.gd`, `main.gd` boot path, `formats/ui_elements.gd` and other executable-table consumers.
**Proposed new files:** `formats/install_profile.gd`, `formats/executable_tables.gd`; a minimal install-selection/error surface in `view/` when the boot flow needs it.

- [ ] Inventory required files/capabilities for each supported Gold build/campaign/locale. Enumerate casing once; reject ambiguous case-fold collisions.
- [ ] Make explicit invalid `--install` fail with that root's exact reason instead of silently selecting another corpus. Persist absolute canonical selection without clobbering unrelated config keys.
- [ ] Recognize supported ELF/PE executable layouts by fingerprint and checked ranges. Read user-owned embedded UI/rule tables without running the binary; unknown layouts fail explicitly.
- [ ] Start with proven LGP and Gold2.28ENG/RUS profiles. Do not claim demo/Armalion/Plus-only support from a shared archive magic.

**Produces:** immutable install profile: build/content identity, logical paths, locale/campaign capabilities and table provenance.
**Acceptance:** LGP lowercase and Windows mixed-case roots load their own resources; same missing file has a precise error; no Linux `sacred` dependency on an otherwise valid Windows profile; unknown executable does not pass only because two GUI anchors match.

### R1. Retail family resolution and cache identity

**Modify:** `formats/{pak,items,texture,models,weapons,rigs}.gd`, `sacred.gd`, all production resource constructors in `main.gd`/views.
**Proposed new file:** `formats/content_set.gd`, owning immutable mounted family indexes and provenance.

- [ ] Mount base/numbered families together: texture00..15 concatenation including empty entries; admitted item00..15 target/rebase rules; models00..14 separate mesh/motion namespaces.
- [ ] Preserve texture name last-wins, model name first-wins, direct numeric identity and ascending weapon inheritance. Do not resolve each with one generic override rule.
- [ ] Replace size-only texture/rig cache keys with ordered content identity and decoder/output version. Shared immutable texture/model metadata may now be reused safely.
- [ ] Migrate every consumer to the same content set; remove primary-only alternate paths, including model previews. Existing raw readers may remain low-level implementation details, not parallel resolution policies.

**Produces:** content fingerprint; stable definition/resource identity; family-specific read/lookup; provenance diagnostics; generation-owned immutable caches.
**Acceptance:** known duplicate texture families, numbered type3999→merged texture25536 witness, empty slots, missing numbered packs and equal-length altered archives resolve correctly. Model/motion overlay acceptance requires its own witness. Vanilla profile results do not change as a side effect of adding mod infrastructure.

### S0. One authoritative session and command path

**Modify:** `world/{sim,actor_registry,actor_state,record_store,replay}.gd`, `main.gd` production orchestration.
**Proposed new file:** `world/game_session.gd`, a plain state owner, not an autoload/event-bus framework.

- [ ] Session owns content identity, campaign/class/difficulty, actors/items, quests/tasks/triggers, clocks and RNG streams. Reuse existing structures; add state only when a consuming task needs it.
- [ ] Define commands by stable actor/item/target identity plus tick/sequence; input/UI/retail scripts submit them through one path. World cell/support identity is not a screen coordinate or view node.
- [ ] Define committed outcomes for views/audio/journal: actor action, movement, HP/stat change, item transfer, quest/task change, transition and sound request. Presentation cannot feed timing back into rules.
- [ ] Move the batch Encounter off its independent production truth path as real combat lands; keep diagnostics exercising the same commands. Remove obsolete side-channel state and duplicated quest logs.

**Acceptance:** renderless and rendered runs of the same commands have identical relevant state; camera-only pans and delayed model loading cannot change actor creation, quest entry or RNG. Missing render art does not erase a gameplay actor. Unsupported save/session versions are explicit.

## 6. World simulation and navigation

### W1. Gold admission, support and actor movement

**Requires:** NAV evidence ticket; R1/S0.
**Modify:** `world/{walkable,path_window,movement,interior,sim}.gd`, `formats/{world,regions,triggers,statics}.gd`, `iso_camera.gd` command conversion.

- [ ] Replace the disproved height-byte fallback and Armalion transfer with recovered Gold world/support/trigger behavior, including caller-specific class2 permissions.
- [ ] Share mutable trigger state with navigation and rendering; remove the competing static-mask interpretation where made obsolete by the shipping contract.
- [ ] Resolve actor-sized/diagonal/step/layer constraints and target reachability from retail evidence; do not enable diagonal AStar just because it looks smoother.
- [ ] Support routes across the current192×192 window and recentering without synchronous full-window stalls or losing goals. Separate path request/result from frame presentation.
- [ ] Derive WALK/RUN/IDLE transitions from authoritative movement/action state, not whether the most recent render frame happened to contain a fixed tick.

**Acceptance:** allowed/denied cells, liquid/special traversal, narrow obstacles, locked/open door, both crossing directions, stairs/support layers, long destination, out-of-bounds destination and route cancellation match retail. Return after unload/revisit without changing traversal state. Continuous walking does not flicker WALK↔IDLE between simulation ticks.

### W2. Persistent world lifecycle and interactions

**Requires:** W1/S0 and the relevant C/P state; implement together with S1.

**Modify:** `world/{sim,interior,actor_registry}.gd`; add `world/interaction.gd` and `world/spawn_state.gd` when their live consumers land; reduce `main.gd` teleport/special-case paths.

- [ ] Execute actor-region/sector Init/Enter/Exit in recovered order with persisted once-only initialization. Render-sector load/unload only creates/removes views.
- [ ] Implement actual object targeting/use, locks/prerequisites/delayed unlock, container/door state, portals/stairs/campaign gates and companion placement using authored rules.
- [ ] Execute authored spawn pools, faction/level selection, death/removal and respawn timers; retain state across render unloads.
- [ ] Separate simulation activation from visibility without deleting offscreen quest/AI identity. Persist the timer/RNG consequences of activation changes.

**Acceptance:** entering twice does not duplicate unique actors; leaving/reentering does not reroll persistent state; camera exploration alone spawns nothing semantically; door clicks do not bypass locks by teleporting to another cell. Day/night and respawn clocks survive save/load and pause according to retail.

## 7. Character, items, progression and persistence

### C1. Real actor statistics and HP

**Requires:** HP evidence ticket; S0.
**Modify:** `world/{actor_state,combat,encounter}.gd`, `formats/{hero,creatures,balance}.gd` as applicable; add `world/actor_stats.gd` for shared stat derivation.

- [ ] Build base/current/derived stat state from templates, creature definitions, level, difficulty and equipment rather than hero100/foe40/raw7 defaults.
- [ ] Implement81F4FFA-derived HP in verified offset/attribute order with exact truncation/modifier ordering and current-pool rescaling. Keep observed special fallbacks conditional, never universal.
- [ ] Reuse recovered hit/damage kernels for all four channels, with actual attack/defense inputs. Attribute vs skill vs effective-stat namespaces stay distinct.
- [ ] Make stat recomputation explicit on equipment, level, skill, form and effect changes; views read the resulting state.

**Acceptance:** same input actor/gear produces retail HP/AT/PA/damage/resistance values; controlled change affects only expected outputs; damage/heal/max-HP change uses the correct pool and health fraction. No copied sector fields or guessed attribute labels.

### C2. Inventory instances, equipment and ownership

**Requires:** ITEM evidence ticket; R1/C1.
**Modify:** `formats/{hero,items,equipment,wpmod,weapons,armour}.gd`, `world/npc_dressing.gd`, `view/player_view.gd`, `main.gd` dressing path.
**Proposed new files:** `world/item_state.gd`, `world/inventory.gd`; inventory UI arrives with U0.

- [ ] Separate immutable item definition from mutable instance identity, rolled modifiers, location/owner, quantity and equipment slot.
- [ ] Implement pickup/drop/consume/equip/unequip and capacity/requirement rules as validated transactions. Implement stacking/splitting only for categories retail actually stacks.
- [ ] Recover and apply candidate sampling, probability/ranges/conditions and modifier units; replace raw-all-candidates helpers as production truth.
- [ ] Derive starting equipment from template/runtime creation, not START_SET6. The same equipped instances feed stats, appearance, inventory UI and save state.

**Acceptance:** two instances of one definition retain different rolls/ownership; full inventory, invalid requirements and failed swaps neither duplicate nor lose items; equip/unequip restores expected stats/appearance; native generated definitions and item texture overrides remain correct.

### C3. XP, skill allocation and death/recovery

**Requires:** XP ticket and recovered retail death contract; C1/C2.
**Modify:** `world/combat.gd`, `formats/hero.gd`, session progression state; proposed `world/progression.gd`.

- [ ] Apply complete XP award/threshold/level logic and points, including relevant difficulty/survival/actor modifiers; base creature reward alone is insufficient.
- [ ] Implement attribute/skill choice and starting-skill option, rune learning and unlocked weapon/art slots at the actual boundaries.
- [ ] Apply death, recovery/respawn, penalties, quest/companion consequences and relevant persistence rules; keep multiplayer-only hardcore outside single-player claims.
- [ ] Drive health/XP/level UI from authoritative values, not the misidentified learning-point formula.

**Acceptance:** below/at/above a level threshold, multi-level award, maximum/range boundary, gear-modified stats, repeated death/reload and reward-once behavior match retail. Slot unlocks and point expenditure cannot diverge between UI and actual actions.

### P1. Safe native OpenHeilig session saves early

**Requires:** S0 and each state's owner; integrate continuously as C/W/S/B land.
**Proposed new files:** `world/save_state.gd`, `world/save_store.gd`; modify `world/quest_log.gd` autosave, main boot/menu and settings storage.

- [ ] Specify versioned engine-owned snapshot schema with campaign/content identity, stable actor/item/script references, RNG/clocks, position/support, triggers, quest/task/init bits, inventory/progression, effects/cooldowns and world lifecycle state.
- [ ] Save at a simulation boundary; complete temporary write/flush then same-filesystem publish, with recoverable prior valid save. Establish platform crash-durability behavior rather than assuming rename alone makes disk writes durable.
- [ ] Restore transactionally: validate/migrate content/schema, construct identities, resolve references, then activate the session. No half-restored live world.
- [ ] Wire real autosave requests and ordinary save/load UI. Never overwrite retail saves or place writable state in the install.

**Acceptance:** process restart reproduces future relevant state, not just the frame; save during NPC movement/effect/cooldown, changed inventory/trigger, departed sector and unfinished quest resumes correctly. Truncated/interrupted write keeps a valid prior save; wrong/missing mods and unsupported versions fail with actionable diagnostics. Replay is not the save format.

### P2. Retail hero import/export

**Requires:** verified AMH version/section ownership, C/P1.
**Modify:** `formats/{pax,hero}.gd`; add versioned reader/writer modules only for supported formats, separate from asset `Pak`.

- [ ] Import properties/equipment/arts into a **new** campaign, not imported world/quest progress; validate class/form/level eligibility and content identity.
- [ ] Preserve unknown sections where required for lossless compatible export; do not write a file retail accepts structurally but restores incorrectly.
- [ ] Qualify export back to retail separately from importing retail heroes. Add legacy versions only after their migration contract passes.

**Acceptance:** all eight classes, supplied advanced exports, same-definition/different-instance gear, learned arts and naming/localization roundtrip; original files remain untouched; an imported hero begins the intended new-campaign state. Underworld eligibility is tested independently of template level.

## 8. Scripts, quests and real combat

### S1. Persistent VM, tasks and dialogue

**Requires:** TASK ticket, S0/W1 and C/P state for rewards/durability; co-deliver with W2, rather than requiring a separately completed W2 scheduler.
**Modify:** `world/{script,quest_cast,quest_log,encounter}.gd`, existing `formats/{funk,startcode,vectoren,resources}.gd`; proposed `world/script_scheduler.gd`, `world/dialogue.gd`. Add dedicated QuestCode/QuestPool readers only where the existing Vectoren/Funk/Startcode ownership cannot express the verified format; these readers do not already exist under `quests.gd`/`questpool.gd`.

- [ ] Retain script scopes, stable resource-handle→actor/object identities, variables, call/condition state and pending tasks. Two NPCs sharing a creature type remain distinct.
- [ ] Implement recovered branches/calls/condition evaluation and scheduler lifecycle; distinguish known retail no-op directives from unsupported executable effects.
- [ ] Execute CreateNPC/CreateObj operand forms correctly, NPC_Goto as a task when retail does, callbacks/task completion, quest conditions/rewards and dialogue choices.
- [ ] Connect one persistent quest log to journal/HUD/save state. Remove transient tutorial-only hosts and the invented encounter-completion link.
- [ ] Keep whole-operation preflight where applicable, but do not invent transactional rollback or eager rejection of unreachable branches if retail's verified control-flow contract differs. Malformed or genuinely unsupported executed behavior is explicit.

**Acceptance:** tutorial plus an actual subsequent quest uses the same NPC identity; branch false does not perform body effects; save mid-task resumes once; repeated entry does not duplicate rewards; NPC exists even if model loading fails. Quest completion is caused by retail-defined conditions, not a hardcoded monster ID.

### B1. Interactive two-sided combat and baseline AI

**Requires:** C/W/S and action timing/range evidence.
**Modify:** `world/{sim,combat,encounter,actor_state}.gd`, input/UI dispatch and actor view; proposed `world/action.gd`, `world/ai.gd`.

- [ ] User selects/attacks real targets through commands; AI uses the same movement/action/stat interfaces for acquisition, approach, attack, retreat/leash and death.
- [ ] Enforce target validity, faction, range/LOS, attack cadence and interruption before applying damage. Action timing comes from simulation and authored motion/effect events, not render frame count.
- [ ] Apply all damage channels, real HP, mitigation, hit/block/critical/equipment effects with verified ordering; opposing attacks can kill the hero.
- [ ] Generate death/reward/loot/task outcomes once. Remove `--fight` as the only attack driver; retain it only as an adapter to the real system if still useful.

**Acceptance:** normal UI can win and lose a fight; out-of-range/occluded/dead targets cannot be remotely damaged; retaliation and interruption work; killing once awards once across save/reload; disabling views changes no combat outcome. No constant7 damage or forced quest completion.

### B2. Combat arts, status effects and combos

**Requires:** ART tickets for each family; B1.
**Modify:** `world/regen.gd`, `formats/combat_arts.gd`, actor/action/progression code; proposed `world/effects.gd` and `world/projectiles.gd` only when first consumers require them.

- [ ] Tick actual recovery clocks in simulation and execute the selected art's real effect; do not model spell readiness as mana.
- [ ] Implement effect families: direct/ranged/projectile/area, damage-over-time, heal/buff/debuff, crowd control/knockback, trap/mine, summon/companion, reflection/shield, teleport and transformation.
- [ ] Handle stacking/refresh/dispel/immunity/duration and source ownership from retail; serialize active effects and referenced actors.
- [ ] Learn/rank/assign runes and construct/use combos through actual service rules; equipment/temp levels alter both outcomes and recovery correctly.

**Acceptance:** each authored art maps to an implemented family/parameters with its exceptional branches covered; level/gear differences change real outcome; cold use fails without side effects; combo order and recovery match; unload/save cannot duplicate summons or reset cooldowns. A few generic effects do not certify every class.

## 9. Player-facing loop, UI and media

### U0. Minimum complete ordinary play surface

**Requires:** R/S/C/P/B interfaces as each arrives.
**Modify:** `view/hud.gd`, `formats/ui_elements.gd`, `main.gd`; proposed focused `view/{menus,inventory_view,dialogue_view,journal_view}.gd` rather than a monolithic GUI manager.

- [ ] Implement new/load/quit, class/name/campaign/difficulty selection, save/export and install-error surfaces; no compile-time Seraphim-only creation.
- [ ] Wire inventory/equipment, targeting/art/potion controls, dialogue choices, quest journal/compass and error feedback to authoritative commands.
- [ ] Complete portrait/health/XP, enemy/companion information and cursor/tooltip states needed by the route. Visible controls perform their actions; decorative sheet blits do not count.
- [ ] Render text from installed resources with correct hashes/encoding/fonts; separate UI locale from gameplay script tree.

**Acceptance M3:** without CLI batch flags, new hero walks to NPC, chooses dialogue, accepts a real objective, fights a retaliating enemy with real stats, receives/uses/equips loot, saves, exits, restarts, loads and continues the same quest. Capture state and UI at each transition. No manually edited flags or hidden test-only state injection in the acceptance run.

### A0. Audio as real gameplay feedback

**Modify:** sector environment consumer in `main.gd` and existing `formats/sectors.gd`; proposed new `formats/sound.gd`, `formats/sound_profiles.gd` and `view/audio.gd` (or a presentation controller outside simulation). The archive/profile research is in `research/formats/install-inventory.md`; current `formats/` does not already contain playback-ready sound/profile readers.

- [ ] Load user's Ogg/PCM/ADPCM resources with verified decode/format support; map music, ambience, footsteps, attack/hit/miss, UI and voice events from retail definitions.
- [ ] Mix independent music/speech/effects volumes; pause/mute/device behavior is explicit. Audio requests carry identity/location from simulation, not inferred model names.
- [ ] Stream longer tracks, cap effect voices and release resources without dropping simulation events or leaking memory.

**Acceptance:** actual output/device stream and recorded sound distinguish correct event and variation; zone/indoor/combat transitions select appropriate tracks; mute toggles each channel; voice/text state agrees. A printed music ID is not playback evidence.

### U1. Full maps, services and settings

**Requires:** C/P/W/S and service price/rule evidence.
**Files:** extend focused `view/` panels and add matching `world/` services, not UI-owned inventories/gold; use existing `formats/resources.gd` and merchant/equipment tables.

- [ ] World/local maps, fog/exploration, player/quest/user markers and portal destination/cancel flow.
- [ ] Trade, stash, smithing/socket operations, rune exchange/combo creation, horse purchase/riding and companion management with verified eligibility/transaction rules.
- [ ] Skills/attributes/bonuses, inventory/target tooltips, help/tutorial skip, independent options and persisted controls.
- [ ] Every cancellation, failed transaction and full-capacity boundary leaves consistent state; confirmations do not silently execute when dismissed.

**Acceptance:** buy→equip→fight→stash→travel→retrieve→forge→sell→restart/load preserves ownership/gold/bonuses. Map reveal and portal state survive. Keyboard and mouse exercise the same services and journal state.

### A1. Movies, credits and complete media flow

**Requires:** MEDIA ticket; explicit codec/dependency policy.
**Files:** presentation movie/credits controller, resource profile, export dependencies if approved.

- [ ] Provide actual shipped MPEG/Bink variants for supported installs through an independently licensed decoder integration or user-local conversion path; document cache/version/licensing. Do not bundle converted retail movies.
- [ ] Execute intro/act/outro/credits triggers with synchronized audio, skip/back/return and state transition ordering.
- [ ] Preserve a no-movies option as an explicit preference, not a hidden fallback for broken decoding.

**Acceptance:** both campaign intros, a triggered act movie and both endings actually animate with sound, can be skipped safely and return to the correct game/menu state; corrupt/unsupported codec errors are clear. No static poster/no-op substitute.

## 10. Campaign and content completeness

### G1. All eight classes, forms and starts

**Requires:** creation/UI plus B2/S1.
**Modify:** `main.gd` class mapping/boot, `formats/{hero,items,models,rigs}.gd`, action/form systems.

- [ ] Resolve class→template→script tree→actual body/equipment/motion from native definitions. Remove Vampiress fallback and false Underworld classification; verify both her forms and their transitions.
- [ ] Validate each class-specific start/tutorial and permitted campaign entry. Supplied advanced heroes and newly created level1 templates remain distinct.
- [ ] Complete specialized mechanics: Vampiress day/form rules; Daemon transformations; Dwarf ranged/cannon/mine rules; class summons, movement skills, traps and companions.
- [ ] Verify motion/state/weapon-mode and equipment changes through idle/walk/run/attack/defend/cast/hit/death/mount/form, including missing authored motion behavior.

**Acceptance:** eight genuine class starts, not seven meshes plus a fallback; each class completes combat, equipment/service, progression, death and save/load routes in every applicable campaign. All form-specific inputs and render states are consistent with rules.

### G2. Both campaign chains and world breadth

**Requires:** W/S/B/C/P/U/A.
**Files:** existing script/task/event systems, content support ledger and only the specific missing handlers each route demonstrates.

- [ ] Drive Ancaria and Underworld main quests from legal entry to their actual endings without debug shortcuts or skipped opcodes.
- [ ] Cover side/dynamic quest template families, escorts/followers, optional/failed/declined branches, reward claims and reentry after world transitions.
- [ ] Traverse each distinct world environment/mechanism: towns, outdoors, dungeons, multiple floors/support grids, bridges/occluders, water/lava, portals and campaign gates.
- [ ] Exercise applicable difficulty unlocks and boundary levels, imported heroes, late-game dense encounters and durable long-play saves.

**Acceptance:** complete end-to-end campaign traces plus a census of every reached opcode/effect/transition; unsupported campaign-critical effect count is zero. A handler count does not replace legal-route execution. Late-game content cannot be marked supported just because its sector renders.

## 11. Strict presentation and compatibility

### F1. Native render ordering, animation and environment fidelity

**Requires:** state-aligned E1 and authoritative actor/action/world state.
**Modify:** `view/{sector_view,floor_view,model_canvas,model_view,player_view,native_actor_shadow,liquid}.gd`, relevant shaders and default animation selection.

- [ ] Use authored action/weapon/form selectors and exact supported animation evaluation/blending/rates. Keep full affine scale/shear and postskin normal semantics.
- [ ] Complete native pass/category/chain ordering, overlapping actor/object depth, special vectors, projected actor/object shadows and liquid/reflection integration.
- [ ] Drive solar/environment color, weather and time-dependent presentation from state instead of fixed white daylight. Preserve encoded texture color/alpha rules.
- [ ] Complete portrait/compass/art/potion/dial details using recovered composition and current state; resolve all required executable element-name bands rather than guessing.

**Acceptance:** independent state/pose/geometry/shading/control witnesses, not only full-frame delta. Test all eight classes, equipped/forms/mounts, multiple overlapping actors, object-on-object occlusion, door/support transitions, liquids and day/night. Static data/geometry may require exact equality; backend raster residuals need measured per-channel bounds. Do not remove content or alter framing to lower the score.

### X1. Retail full-world save compatibility and migrations

**Requires:** SAVE ticket and all authoritative state owners.
**Files:** separate AMS/world-save readers/writers and version adapters under `formats/`; session restore owns activation.

- [ ] Join every claimed supported world section to runtime state and restore order, with object identities/references, quests/tasks, triggers, RNG/clocks, exploration, inventory/companions/forms and active effects.
- [ ] Qualify current Gold saves before older versions; use `world.bin`/`static10_18.bin` migrations only when the selected historical version requires them.
- [ ] Treat native world import, native hero import and export-back-to-retail as separate advertised capabilities. Unsupported versions remain explicit, never silently converted to new game.

**Acceptance:** copied retail save loads to equivalent state and continues; save→load→save preserves semantic state and does not rerun one-time scripts. Port-written retail-compatible files must actually load in the designated retail build if that capability is advertised. Never test against the user's only save copy.

### X2. Declared build/locale/platform compatibility

**Requires:** R0/R1 and relevant presentation/media/save work.

- [ ] Compare Win2.28ENG/RUS and LGP behavioral differences with exact binary/data/config provenance. A compatibility profile chooses differences; it never averages them.
- [ ] Exercise mixed-case installs, installed language packs, non-ASCII names/paths, missing/corrupt resources and wrong-version executable tables.
- [ ] Validate each advertised OS/GPU/renderer and native/maximized resolution; Compatibility renderer is a separate fidelity project, not an automatic fallback from Vulkan.

**Acceptance:** fresh install on each advertised platform works without private developer state, retail binary execution or copied Linux-only metadata; named unsupported cases fail before partial gameplay. English success does not certify Russian fonts/voice/hash behavior.

## 12. Data mods and modern presentation

### D1. Explicit data-mod profiles and compatibility

**Requires:** R1/P1; gameplay systems consume resolved definitions rather than scattered file paths.
**Proposed files:** `formats/mod_manifest.gd`, profile selection and provenance UI; extend `content_set.gd` instead of creating another resolver.

- [ ] Stable package IDs/versions, dependency/load order, whole-file versus record replacement and new namespaced records. Deterministic conflicts are visible before play.
- [ ] Keep vanilla retail numbered semantics underneath explicit OpenHeilig overlays; new replacement policy never changes base name/direct-ID rules.
- [ ] Harden archive/record bounds, decompression/resource limits and path containment. Avoid generated assets becoming an invisible highest-priority layer.
- [ ] Record exact mod/content set in saves; enable/disable/update creates a new resolved profile. Permit only proven-compatible migrations; reject missing required content safely.
- [ ] Publish support classes: data-only verified formats; separately ported behavior mods; unsupported native detour DLLs. No blanket “all Sacred mods work” claim.

**Acceptance:** vanilla profile remains unchanged; conflicting data packages show the winner/provenance; same-size replacement invalidates caches; dependency cycle/escaping path/corrupt index is refused; wrong-profile save cannot silently bind IDs to another item. A known numbered retail witness and an independently authored data-only mod both work.

### D2. Optional executable mod API — separate security decision

**Requires:** stable session commands/effects/save schema and an explicit trust policy.

- [ ] Prefer data/retail-bytecode extension first. If arbitrary scripts are required, select and verify a real sandbox runtime or process isolation; define allowlisted data reads, simulation commands, deterministic RNG, UI events and mod-private storage.
- [ ] Version capabilities and persistent script state. Set instruction/memory/event budgets and deterministic event ordering; a failed mod cannot partially corrupt authoritative state.
- [ ] Full-trust GDScript/PCK/native plugins, if allowed, require conspicuous explicit trust and platform/ABI qualification. They are not sandboxed and are never loaded automatically from a save.

**Acceptance:** denied filesystem/network/native imports actually fail in adversarial probes; runaway scripts are bounded; replay/order and save resume remain consistent; one mod cannot mutate arbitrary engine objects. If no proven sandbox is selected, advertise only data mods and explicitly trusted code—not an unfinished secure API.

### M1. Modern controls, display and accessibility

**Requires:** real U interfaces and command path.
**Files:** settings/profile storage, `iso_camera.gd`, input router and focused `view/` controls; strict-reference1024×768 layout stays available.

- [ ] Rebind keyboard/mouse/controller commands with conflict/reset handling; keyboard-only menu focus/cancel, controller navigation/deadzones/prompts and hold/toggle alternatives.
- [ ] Independent UI/text/cursor scaling versus world zoom; aspect-safe/high-DPI layouts; display/window/borderless/fullscreen changes. Wider visibility affects render budget, not simulation rules.
- [ ] Subtitle/dialogue history, separate audio volumes, contrast/non-color-only status, reduced flash/motion. Use semantic accessible controls where screen-reader behavior is claimed; texture-only rectangles are insufficient.
- [ ] Settings persistence preserves unrelated configuration and survives device/display changes. Document optional quality-of-life rule deviations separately from presentation changes.

**Acceptance:** entire M3 route is usable on supported input devices and UI scales; no clipped controls/text, inaccessible modal, unreadable cursor or silent remap; strict-reference command outcomes stay identical. Accessibility claims require actual surface testing, not API availability.

## 13. Continuous performance and release qualification

### Approved policy decisions — 2026-10-04

- Engine-only export/release packages are authorized. This supersedes the
  earlier source-only/no-export rule, not the prohibition on distributing
  retail assets, derived caches, captures, or private reverse-engineering
  evidence. Actual export artifacts must be inspected before release.
- D2 is restricted to data and verified retail bytecode. Arbitrary GDScript,
  PCK, native plugins, and other host-executable extensions are not approved.
  The retail VM is not advertised as an arbitrary-code sandbox. Unsupported
  executed behavior and over-budget inputs must be refused explicitly.


### Q0. Performance workloads and proposed targets

**Start:** M0, not after campaign implementation.
**Use:** existing profiler/overlay plus an improved bounded workload runner. Never time `--fixed-fps` captures as throughput.

Required workloads: process startup/first interaction; fresh-process streaming with OS cache state stated; settled idle; click travel/camera follow; door/layer/portal/region change; dense town/crowd; combat with projectiles/effects; inventory/service UI; save/load; long travel/unload/revisit. Record p50/p95/p99/max frame time, stall count/duration, input response, time-to-ready, CPU allocation/resident memory, GPU upload time/draw calls/VRAM and post-unload retention.

**Proposed release targets, not observed guarantees:** declare hardware/resolution/content tier; target60Hz with p95≤16.7ms and p99≤33.3ms on the reference tier, no >100ms stall during settled ordinary traversal, input feedback within100ms during loading, and bounded memory returning to a documented working set after repeated travel. Measure achievable loading deadlines and memory caps on the supported hardware before locking them.120Hz is a separate stretch tier. Do not claim “faster than retail” without matched actual-route A/B and quality/state equivalence.

### Q1. Remove measured redundant/atomic work

**Modify:** `formats/{models,texture,pak,world,rigs}.gd`, `view/{model_view,sector_view,floor_view,model_canvas}.gd`, path-window code where measured.

- [ ] Cache immutable parsed model/skin/animation metadata and decoded textures/uploads under R1 identities; profile memory tradeoff and eviction.
- [ ] Isolate synchronous startup, navigation fill, model construction and texture-array upload costs. Cooperative checks cannot interrupt a single long atomic call; change granularity/algorithm where evidence demands it.
- [ ] Introduce CPU worker tasks with isolated file cursors/buffers; results carry content/admission generations. Main thread validates generation and publishes GPU/tree objects. Bound in-flight bytes/jobs and join every task on completion/cancel/teardown.
- [ ] Reuse model targets/palette bindings/actor commands only where complete pose/camera/material/bounds revisions prove equivalence; stress same-cell crowd order and index-gap capacity.
- [ ] Add an isolated GDExtension kernel only if profiling still identifies a dominant loop and a controlled prototype improves end-to-end frame distributions without parity loss.

**Acceptance:** before/after control at identical state/render quality, same hardware/workload and cache conditions; p99/loading/memory all reported, including regressions. Cancellation, unload/revisit, resize/zoom and stale-worker results preserve object identity and image/state. No shared-reader seek races, discarded shear, frozen animation, content suppression or hidden readback stalls.

### Q2. Reliability, packaging and support boundary

**Requires:** explicit distribution-policy approval, completed supported feature matrix and license review.
**Files:** future `export_presets.cfg`, engine-owned release scripts/manifests, README/support docs; never add private data to an allowlist.

- [ ] Export an allowlisted engine-only package; inspect the actual artifact, not just Git status. Include only owned code and authorized dependencies/licenses; exclude retail assets/tables/caches/probes/captures and export credentials.
- [ ] Test fresh machine/profile, install discovery, read-only install, sandbox/native-dialog permissions, content errors, writable save/cache locations, upgrades and rollback/migrations.
- [ ] Long-session stress covers streaming/AI/effects/audio/save churn, resource teardown, device/display changes and interrupted writes. No unbounded memory/VRAM or silent save corruption.
- [ ] Publish supported builds/locales/platforms/mod classes and known deviations; qualify each feature independently. Configure off-machine backup/remotes for authored repositories only with the required user approval.

**Acceptance:** packaged engine starts and completes M3 from a user-selected retail install on each supported platform; no developer-private path/library/reference dependency; no game bytes in the package; stable save upgrade/rollback procedure; independent reviewer can reproduce the published scenario results.

## 14. Literal whole-product1:1 and multiplayer boundary

The standing scope is single-player. Do not silently remove multiplayer from the definition of retail, and do not silently start implementing it under this plan.

If the user later expands scope, an additional specification must cover: LAN/direct hosting and standalone server;2–4-player co-op and host-save ownership; up-to16 H&S/PvP sessions and parties up-to8; chat/invites/teleport/safe zones; shared XP/loot and network-dependent content; service-specific hardcore/death/character storage; reconnect/session authority; and Windows/LGP protocol differences. Original ClosedNet/PenguinPlay services are not interchangeable and original internet service operation is no longer available.

Three separate claims would require separate evidence: modern OpenHeilig multiplayer, protocol interoperability with retail clients, and replacement online services. None follows from deterministic single-player replay or a network-friendly API. Until such work is approved and qualified, the release wording remains **single-player parity**, with these rows explicitly excluded.

## 15. Anti-stall execution rules

1. One work package must end in a real new or corrected player-visible outcome and its evidence. Pure mapping/census growth is not a milestone.
2. Pair each new semantic rule with a discriminating control and a shipping-runtime witness. Reuse cross-build corpus; do not restart naming surveys.
3. Keep a four-state capability ledger: researched, implemented, production-used, behaviorally verified. Never collapse them to “done.”
4. Retire the old path in the same cutover. No permanent parallel combat truth, primary-only resource fallback, transient quest host or hardcoded starting outfit behind the new interface.
5. Refactor `main.gd` only along the new ownership boundaries: boot/content, session, presentation and diagnostics. Do not turn refactoring into another featureless milestone.
6. Performance evidence includes loading and worst tails. Visual evidence includes actors and chronology. A lower score caused by absent content is a failure.
7. A milestone ends at its acceptance criterion, not when all newly written checks pass. Full-campaign completion requires playing the campaign.
8. No guessed delivery dates or effort percentages. Use dependency completion, evidence and remaining semantic tickets to schedule the next package.

## 16. Verification and handoff checklist

Before any implementation phase is accepted:

- [ ] Required semantic tickets have specific evidence; no known false research claim remains the phase's authority.
- [ ] Every affected production consumer, save schema, replay/event contract and documentation entry was migrated or intentionally unchanged.
- [ ] Existing relevant checks pass; new permanent checks test consumer-visible invariants/boundaries, not copied constants/source text/mock echoes.
- [ ] Actual production route ran; visual/audio work was inspected on the shipped renderer/output path.
- [ ] Negative/control cases fail for the intended reason; no partial load, ignored error or stale capture can pass.
- [ ] Performance comparison reports environment/state/quality, percentiles and memory; no unmeasured speedup claim.
- [ ] Proprietary evidence remains private; authored result logged with provenance and limitations.

**Recommended first authorized work:** E1 + R0, then W1/S0 and C1/P1 with their concrete prerequisite tickets. Run resource-profile work and scenario instrumentation independently; do not start by polishing the remaining cathedral pixels or introducing a new engine/framework. Implementation remains stopped pending the user's decision on this proposal.
