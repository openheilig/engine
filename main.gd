extends Node3D
## OpenHeilig composition root: resolves the retail install, constructs the
## shared readers (pak/world/static/mixed/items), parses every CLI flag,
## prints the startup banner, and owns the actor world layer (registry,
## record store, sim) and the camera.
##
## Sector streaming and mesh assembly live in view/sector_view.gd
## (SectorView) -- this file constructs it once in _ready(), drives it from
## _process() alongside the sim accumulator, and never duplicates its logic.
## _process() is the single per-frame entry point: it calls SectorView.stream()
## then Sim.advance() (via _advance_sim), never two independently-ordered node
## callbacks (R10.2).
##
## Two modes:
##   (default)          stream sectors around the camera
##   --region=cx,cy,r   load exactly that fixed block, print the counts, stop
##                      streaming. This is the regression check -- 50,50,1 must
##                      stay "28672 quads, 63 textures".

const SECT: int = Sacred.SECT
## The F3 developer overlay. Preloaded, not `class_name`d: a newly added
## global class is not in Godot's script-class cache for a `--path` run until
## the project is reimported (view/rig_placement.gd documents the same trap).
const DebugOverlayScript := preload("res://debug_overlay.gd")

## Where the default run opens. Overwritten in _ready() by the class tree's own
## StartPosition record (Startcode.start_cell) -- for START_CLASS below that is
## cell 3236,2511, sector 50,39, which is retail's new-game spawn for that
## class rather than a cell anyone chose. The literal here is the FALLBACK for
## an install whose tree carries no such record, and it is deliberately the old
## sector-50,50 centre so a missing record degrades to the previously shipped
## behaviour instead of to (0,0).
@export var start_cell := Vector2(3232.0, 3232.0)  ## fallback: middle of sector 50,50

## The class whose new-game spawn the default run uses. One name, here, rather
## than a cell copied into the source: the nine base trees each declare a
## different StartPosition and the port has no class-selection screen yet, so
## this is the placeholder that a selection screen replaces.
## ponytail: a constant until there is a UI to choose with.
const START_CLASS := "type_npc_seraphim"
## The template file START_CLASS creates from. Rides beside START_CLASS as
## the same placeholder: a class-selection UI replaces both with the real
## class -> template -> type join (types are NOT file order -- hero02.ptx
## is the type-9 template).
const START_TEMPLATE := "hero01.ptx"

## bin/sets.bin record whose members the player is built from. 6 is "Uriel's
## Legacy", the Seraphim suite -- nine members, seven garments and two blades.
## A set rather than a list of mesh names because retail already decided what
## goes together, and because it keeps this constant honest: change START_CLASS
## and this is the one other line that has to move.
## ponytail: a full starting kit is not what a new retail character has -- she
## is bare with one blade (findings row 1101) -- so the garments are SKIPPED
## by default and only --dress-garments wears them. START_SET still selects the
## blade(s) equipped in the default run; a real inventory replaces this.
const START_SET := 6

## The base body's `shoes` batch (270 tris, Sera_boots.tga) is EMITTED, not
## hidden -- measured 2026-08-30 by four-way A/B across both engines: the
## legs group's own texture paints the boots with SEMI-TRANSPARENT alpha in
## the shin region, so hiding the batch (the pre-2026-08-30 state) leaves the
## hero ghost-legged below the knee; the opaque batch is what retail draws
## over that ghost. Two costs measured with the batch emitted: Bevy (alpha
## ignored, opaque materials) never needed it; and the hero's squash-shadow
## projects the batch as dark spikes under the feet -- a shadow-calibration
## followup (SHADOW_K/SHADOW_ALPHA or a per-surface shadow exclusion), not a
## reason to hide the boots. Worn garments hide their slots' base surfaces
## dynamically (set_materials_hidden_by_token) on top of this.
const BASE_HIDE := []

## Script tree -> the class's whole-body mesh in models.pak. These are the
## short, underscore-free rig names (`SERAPHIM.GRN`, `GLADIATOR.GRN`); the
## long `SERAPHIM_LEATHER_02.GRN` family beside them is ARMOUR worn over one,
## which nothing here composes yet.
##
## `type_npc_vampirelady` IS ABSENT ON PURPOSE, and the absence is the finding:
## models.pak carries no vampiress rig under any spelling tried (VAMP, LADY,
## SUCCU, NOSFE, DRACUL, WEREW). She is an Underworld class, so her mesh is
## presumably not in this pak at all. A wrong guess here would draw the wrong
## body silently, so the map has a hole and _apply_retail_start says so.
var _export_sera := false               ## --export-sera=path: dump the hero mesh as OBJ for Bevy
var _export_sera_path := ""

# --- E1 semantic scenario state (tools/scenarios.json, tools/checkpoint.gd) ---
## The scenario triple a --scenario= run carries. Empty in every other mode;
## read by Checkpoint.capture and printed on the scenario fact lines. A
## --scenario= without --checkpoint-out= is refused: a scenario run that
## captures pixels but records no authoritative state is exactly the
## loading-relative comparison that refused its own repeats.
var _scenario_name := ""
var _scenario_route := ""
var _scenario_checkpoint := ""
var _scenario_expect := {}              ## the manifest's expect block for this scenario
var _scenario_steps := []               ## the manifest's drive steps, handed to Drive.run
var _scenario_shots: Array[int] = []    ## the manifest's shots, milliseconds from settle
var _checkpoint_path := ""              ## --checkpoint-out=PATH: the JSON sidecar destination
var _checkpoint_ref := ""               ## --checkpoint-ref=PATH: reference to compare against
var _checkpoint_made := false           ## true once world_moved() has run -- a scenario
                                        ## run that never reaches its checkpoint must
                                        ## refuse, not quietly capture
var _scenario_freeze_at := NAN          ## manifest freeze_anim: park every rig at this
                                        ## clip time before checkpoint+shots so pixel
                                        ## repeats compare the same pose (NAN = no freeze)
## P1: --save=PATH writes a session snapshot at the settle boundary and
## quits; --load=PATH restores one before the first streamed frame. Both
## are ordinary CLI flags, not scenario-only -- a save that only works
## inside a harness flag is not a save.
var _save_path := ""
var _load_path := ""
## S0: the ONE owner of authoritative state (world/game_session.gd).
## Constructed by the default streaming path; _registry/_quest_log/_sim/
## _player_id become aliases of its members so pre-session call sites keep
## working while the cutover proceeds.
var _session: GameSession = null
## The live quest log and cast the new-game hook produced. Null until
## _begin_encounter/_build_quest_cast run; the Checkpoint reads whatever the
## scenario actually reached.
var _quest_log: QuestLog = null
var _quest_cast: QuestCast = null
const CLASS_MODEL := {
	"type_npc_daemonin": "DAEMONIA.GRN",
	"type_npc_darkelve": "DUNKELELVE.GRN",
	"type_npc_elve": "WALDELFE.GRN",
	"type_npc_gladiator": "GLADIATOR.GRN",
	"type_npc_magician": "MAGICIAN.GRN",
	"type_npc_seraphim": "SERAPHIM.GRN",
	"type_npc_zwerg": "DWARF.GRN",
}

## The mesh actually drawn for the player. Set from CLASS_MODEL in
## _apply_retail_start; falls back to PlayerView's own default so a tree with
## no mapping still draws a body rather than nothing.
var _player_model := PlayerView.MODEL_NAME
var _player_type := 0
var _shadow_items: Sacred.Items
var _shadow_creatures: Sacred.Creatures
var _shadow_statics: Sacred.Statics
## The retained native render configuration (byte 0x08906DA0), not an
## always-blob switch: support and creature flags still select the branch.
const ACTOR_SHADOW_DETAIL := 2
var _player_shadow_heading := Vector2(NAN, NAN)
var _player_shadow_last_facing := Vector2(NAN, NAN)

## START_CLASS's StartPosition cell, or (-1,-1) when the tree declares none.
## Separate from start_cell because start_cell is a Vector2 the camera pans to
## and may be moved by other modes, while this stays the exact integer cell the
## file gave, which is what _resolve_spawn tests for walkability.
var _retail_start := Vector2i(-1, -1)
var _retail_start_layer := 0

## The MVP encounter (world/encounter.gd): the hostile, the NPC beside it and
## quest 74, all at START_CLASS's own start. Built once the player exists, and
## null in the fixed-region and probe modes, which spawn no player.
var _encounter: Encounter = null
## THE HERO'S ANIMATION, which is the difference between a character and a
## statue. Sacred.Rigs picks the clip by bone geometry -- the same instrument
## --creatures uses -- and PlayerView.animate refuses rather than approximating
## when the pick does not bind.
##
## THE SCORE IS PRINTED, not trusted. Rigs.clip_for is a MEASUREMENT (row 609
## found clips that splay the rig they bind to), so the fact line carries the
## agreement fraction and --noanim turns the whole thing off.
## Held past _animate_hero so _process can SWITCH the hero's clip, which is
## the whole difference between a body that animates and a body that acts.
## Null whenever the hero is not animated at all (--noanim, no rig, the modes
## that spawn no player), and _drive_hero_action tests exactly that.
var _anim_models: Sacred.Models = null
var _anim_rigs = null
## Where the hero was last frame, for the only movement test there is: did she
## actually cover ground. `heading` cannot answer it -- world/actor_state.gd's
## own header says click-to-move never writes it -- and `facing` is HELD, so it
## says which way she is turned and never whether she is going.
var _last_player_cell := Vector2.INF
## Below this a frame's movement is float noise, not a step. One thousandth of
## a cell is ~3 orders under Movement.CELLS_PER_SECOND * a 60 Hz frame.
const MOVING_EPSILON := 0.001


func _animate_hero(models: Sacred.Models) -> void:
	if _player_view == null or _player_view.node == null:
		return
	if not _animate_player:
		print("hero_anim\tskipped\treason=--noanim")
		return
	var want := PackedInt32Array([_player_view.model_index])
	var rigs := Sacred.Rigs.new(models, want)
	var ok := _player_view.animate(models, rigs)
	if ok:
		_anim_models = models
		_anim_rigs = rigs
	print("hero_anim\tmodel=%s\tclip=%d\tscore=%.3f\tplaying=%s" % [
		_player_model, rigs.clip_for(_player_view.model_index),
		_player_view.clip_score(rigs), ok])


## Seconds of simulated time between two headless swings. Retail's own
## no-weapon recovery time (`sub_81A8636` returns 20.0 when there is no item),
## used here because the headless fight has no frame clock. It is a stand-in
## for a swing timer the port does not have, not a recovered cadence.
##
## MEASURED CONSEQUENCE, recorded rather than tuned away: 20 s at the Seraphim's
## own rate serves ~24 s of clock, and her starting art is a 15 s one -- so it
## is ready again every swing and the cooldown never bites in this loop. That
## may well be right for a level-1 art, but it means this log does not
## DEMONSTRATE the gate. `checks/regen_check.gd` is what proves it, by refusing
## an art at half its clock.
const FIGHT_SWING_SECONDS := 20.0

## --fight=N resolves the encounter headlessly, N swings at most, and then
## QUITS -- it is a batch flag. Before 2026-08-20 it printed and left the app
## running, so every run ended on an outer timeout's SIGTERM.
##
## --fight=N resolves the encounter headlessly, N swings at most, so the whole
## loop is demonstrable in a run that exits. <= 0 leaves the hostile alone.
var _fight_swings := 0
const FIGHT_SEED := 20260816

var _cam: IsoCamera
var _view: SectorView
var _world: Sacred.World

## Actor world layer (world/actor_registry.gd, world/sim.gd). Constructed
## once in _ready(), never added to the scene tree -- see
## world/actor_registry.gd's header for why (the OpenMW-regret this phase
## exists to avoid).
var _registry: ActorRegistry
var _records: RecordStore
var _sim: Sim
var _tick_hz: int = Sim.TICK_HZ           ## --tickhz=N override, clamped [1,240]
var _probe_ticks := 0                     ## --actor-probe=N; <= 0 disables the probe
var _probe_route := "a"                   ## --probe-route=a|b
var _probe_active := false                ## true while _actor_probe() drives ticks by exact count
const PROBE_FOCUS := Vector2(3232.0, 3232.0)  ## middle of sector 50,50
const VIEW_SETTLE_TIMEOUT_MS := 120000

# Phase 4: record / replay. Nothing below is read unless --record= or
# --replay= is present -- every other mode's behaviour is byte-for-byte
# unchanged from before this phase.
var _record_path := ""                    ## --record=PATH: write intent+tick to this recording file
var _replay_path := ""                    ## --replay=PATH: replay a recording from this file instead of live input
var _dump_path := ""                      ## --dump=PATH: per-tick state-dump destination, record or replay mode
var _autoplay_ticks := 0                  ## --autoplay=N: ticks to record before quitting; <= 0 disables
var _has_spawn_override := false          ## true once --spawn=cx,cy has been parsed
var _spawn_override := Vector2.ZERO       ## --spawn=cx,cy: skip derivation, use this cell exactly
var _falsify_tick := -1                   ## --falsify=TICK: perturb this tick during replay (Task 2); < 0 disables
var _falsify_mode := ""                   ## --falsify-mode=nudge|skip, paired with --falsify=
var _player_id: int = ActorRegistry.INVALID_ID
var _recorder: Replay.Recorder
var _dumper: Replay.Dumper
var _replay_active := false               ## true while replay drives ticks by count -- suppresses _process()'s normal advance call, exactly like _probe_active
const RECORD_FRAME_BUDGET := 20000        ## generous upper bound; --autoplay=600 finishes in a small fraction of this

# Plan 04-02: sliding path window. Nothing below is read unless a record or
# replay run is in progress -- every other mode is untouched.
var _path_window: PathWindow = null
var _goal_cell := PathWindow.NO_GOAL      ## BFS-derived once per record/replay run; NO_GOAL if none could be derived
var _supported_route := false             ## --walk-route=supported-in-out; test-only measured-cell route
var _anim_phase := -1.0
var _art_elements: Array = []         ## the hero's first art's EMPTY/LOAD/FULL element triple, applied once the HUD exists
const GOAL_REQUEST_TICK := 250            ## the one scripted tick that requests a path (well after spawn, well before autoplay ends)
## Measured 06-02 OZELT1 footprint in sector 53,28: the direct-cell route is
## explicitly a deterministic harness fallback because 06-03 measured 0/20
## walkable-into tents under the current FLOOR/DOOR/STEP allowlist.
const SUPPORTED_ROUTE_INTERIOR_TICK := 30
const SUPPORTED_ROUTE_EXTERIOR_TICK := 60
## The route walks a REAL path, both ways, through OZELT3 at region 53,28,0 --
## the tent next door to the OZELT1 one this gate used to use. OZELT1 is a
## CLOSED POCKET under the production navmesh (row 752: 86 reachable cells, all
## inside its own rect, zero walkable neighbours outside it), so no route
## through it could ever be walked in from the outside. A world scan (row 753)
## found the navmesh admits tents per FAMILY rather than not at all -- OZELT3
## 5 of 5, TENT6 6 of 6, TENT2 3 of 3 escape, while OZELT1 0 of 7 and OZELT2
## 0 of 5 do not -- and 53,28,0 is an OZELT3 in the SAME camp and the same
## sector, so the gate keeps its streaming and its scenery and gains a route
## that is walked end to end.
const SUPPORTED_ROUTE_REGION := Vector3i(53, 28, 0)       ## measured OZELT3 key
## Interior floor -> DOOR 3425,1829 -> STEP 3425,1830 -> outside, 20 cells,
## every consecutive pair 4-adjacent and every cell open under Walkable,
## derived by breadth-first search and verified before use. Walked forwards to
## leave and backwards to enter; there is no teleport anywhere in this route.
const SUPPORTED_ROUTE_PATH: Array[Vector2i] = [
	Vector2i(3427, 1818), Vector2i(3427, 1819), Vector2i(3427, 1820),
	Vector2i(3427, 1821), Vector2i(3426, 1821), Vector2i(3426, 1822),
	Vector2i(3425, 1822), Vector2i(3425, 1823), Vector2i(3425, 1824),
	Vector2i(3425, 1825), Vector2i(3425, 1826), Vector2i(3425, 1827),
	Vector2i(3425, 1828), Vector2i(3425, 1829), Vector2i(3425, 1830),
	Vector2i(3426, 1830), Vector2i(3426, 1831), Vector2i(3426, 1832),
	Vector2i(3426, 1833), Vector2i(3426, 1834),
]
## Index 13 is the DOOR: arriving there from outside is what flips INTERIOR.
## Index 14 is the STEP: arriving there from inside is what flips EXTERIOR.
## Both are measured positions in the path above, not tuning knobs -- they are
## what pins the two swaps to SUPPORTED_ROUTE_INTERIOR_TICK and
## SUPPORTED_ROUTE_EXTERIOR_TICK while the legs either side are walked.
const SUPPORTED_ROUTE_DOOR_INDEX := 13
const SUPPORTED_ROUTE_STEP_INDEX := 14
const SUPPORTED_ROUTE_OUTSIDE := Vector2i(3426, 1834)
const SUPPORTED_ROUTE_INTERIOR := Vector2i(3427, 1818)  ## measured interior FLOOR
const SUPPORTED_ROUTE_DOOR := Vector2i(3425, 1829)
const SUPPORTED_ROUTE_STEP := Vector2i(3425, 1830)## WHY THE OUTSIDE LEGS ARE STILL TELEPORTS, measured rather than assumed. A
## BFS over open cells from the interior floor reaches 86 cells, bounded to
## 3413,1833..3423,1845 -- entirely inside the region rect 3410,1829..3425,1847
## -- and the number of walkable cells OUTSIDE that rect adjacent to the
## reachable set is ZERO. The door and the step are both reachable; nothing
## beyond them is. The tent is a closed pocket under the production navmesh,
## which is row 632's "no camp tent is walkable-into" reproduced from the
## inside out. So the in-tent leg below is a real walk and the two outside legs
## cannot be; making them walkable needs a navmesh that admits the tent, not a
## different cell list.
## Door-crossing geometry (retail moveDoorPosition equivalent, generalized).
## The port navmesh cannot walk door cells from either side (06-03: 0/20
## walkable-into), so clicking a footprint DOOR/STEP cell teleports the actor
## across the doorway instead of requesting an unreachable A* goal.
const DOOR_EXTERIOR_STEP := 2   ## cells past the region edge for the exterior side
const DOOR_TRIGGER_RADIUS := 1  ## Chebyshev radius around the doorway within which a click crosses (2026-08-13)

## Task 3's origin perturbation: a plain number, sourced here at the
## composition root, never inside godot-port/world/ -- large enough
## (one whole window edge) to guarantee the shifted window never coincides
## with the true one, regardless of the actor's exact position.
const ORIGIN_PERTURB_OFFSET := Vector2i(PathWindow.WINDOW_EDGE, PathWindow.WINDOW_EDGE)

# Plan 04-03: the player view (the real posed mesh, drawn and depth-sorted in
# the streamed world) and camera follow. Nothing below is read unless the
# default streaming branch runs -- fixed-region, single-model, window-probe
# and record/replay modes are all unaffected.
var _player_view: PlayerView = null
## --creatures: the spawn tables, drawn. One built rig per rolled creature in
## the player's own sector, each playing the clip Sacred.Rigs picked for its
## mesh by bone geometry. Held so _process can keep them placed and so the
## tree frees them on quit exactly like the player's rig.
var _show_creatures := false
## --npcs: the scripted cast from startcode.bin, drawn at its REAL cells rather
## than scattered (row 832). Shares _creature_views so the tree frees these
## rigs exactly like the rolled ones -- the difference is where they stand,
## not how they are owned.
var _show_npcs := false
## --noquests: do NOT run the starting quest's OnEnter hook. Default OFF, i.e.
## the hook DOES run, because running it is what retail does -- `cInterpretSQW`
## fires a quest's hooks as the player arrives, and quest 1 (`Tutorial`) is what
## puts the novice nun beside the Seraphim at the start. Drawing her is fidelity
## rather than a feature, so this is an opt-OUT in the style of --noplayer and
## --noobjects, not an opt-in in the style of --npcs.
##
## She is worth 0.918pp of the world band (row 1105) -- more than the whole hero
## -- so a run that suppresses her is a run whose parity number cannot be
## compared with the gate's. That is why the `quest` fact line reports the flag
## rather than simply going quiet.
var _run_quests := true
var _creature_views: Array[PlayerView] = []
var _scripted_objects_by_sector: Dictionary[int, Array] = {}
var _scripted_models: Sacred.Models = null
var _scripted_object_jobs: Array[Dictionary] = []
var _creature_cells: Array[Vector2] = []
## Scripted-cast rigs keyed by their simulation actor id. Filled by
## _build_quest_cast; _process follows these actors every frame exactly like
## the hero, so a scripted NPC_Goto becomes real movement.
var _scripted_views: Dictionary[int, PlayerView] = {}
var _show_player := true   ## --noplayer: suppress building the player view entirely (Task 3's Gate 1 needs the camera following the player with the player itself not drawn), in the style of --noobjects.
## --hideplayer: build the player view and keep the camera following it
## exactly like the ordinary case, but never make its mesh visible. A
## genuinely different mechanism from --noplayer (Task 2's own fix means
## --noplayer now also stops the camera following, per the commit on
## iso_camera.gd/main.gd) -- Gate 1's A/B/C captures need the camera actively
## chasing the player while nothing player-shaped reaches the frame, which
## only PlayerView.set_shown(false) on an otherwise-normal player gives.
var _hide_player_mesh := false
## --noanim: build the hero but leave it in its rest pose. See the flag parse.
var _animate_player := true
## The hero's dress state. Findings row 1101: a stock retail Seraphim starts
## BARE -- no `equip=` line ships in the balance text -- and carries exactly
## ONE blade. Three settings:
##   default           bare body + the set's one dockable blade (retail match)
##   --nodress         bare rig, wearing and carrying nothing
##   --dress-garments  Uriel's Legacy kit (garments + blades) -- the old
##                      default, kept reachable so the garment path is still
##                      exercised by tests/parity, not dead code.
## (START_SET still selects which set's members are iterated; only the GARMENTS
## are skipped by default now. See research/formats/balance-bin.md.)
var _dress_player_enabled := true   ## --nodress: suppress all dressing
var _wear_garments := false         ## --dress-garments: also wear the kit's garments
## (There is deliberately no `_last_heading` here any more. Holding the last
## non-zero heading in the SCENE SCRIPT could not work: nothing in an ordinary
## run ever writes ActorState.heading -- click-to-move goes through
## Sim._path_delta, which by design never stores its direction back -- so the
## held value never left its seed and the hero faced one fixed direction for a
## whole session. The held facing now lives on ActorState.facing, written by
## Sim._step_actor from the delta the body actually moved. See that field's
## header for the seed and its derivation.)
## --nohud suppresses the taskbar. Every capture runbook that asserts an md5 of
## the world needs the interface out of the frame, and the HUD covers the
## bottom 92 rows of it.
var _show_hud := true
var _hud: Hud = null

## RETAIL'S SECTOR-CHANGE PATH (sub_80DB27C), link 6c of research/engine/
## game-wiring.md. Retail does NOT pick music on sector ENTRY -- sector Enter
## (sub_80DB06C) runs placements and triggers and selects nothing. A separate
## path fires only when the player's current sector CHANGES, reads that
## sector's 256-byte cSectorEnvironment out of world/sectors.keyx, and hands
## music id + climate + region to the sound engine:
##
##     env = world.sectors[id].env
##     if env.music: cMSS::receive_event(mss, 2, 0, env.region, env.music, climate, ...)
##     if env.atmo2: sub_84C9342(mss, env.atmo2)
##
## THIS PORT HAS NO AUDIO LAYER, so the selection half is wired and the
## playback half is not. That is deliberate: Sacred.Sectors had a correct
## reader and a passing gate (sectorenv_check) but ZERO production callers, so
## the recovered environment never reached a running frame and the wiring
## table's "yes" for this link was not true of the game. Selecting and
## reporting it makes the link real and observable now; a sound layer later
## consumes `_sector_env` instead of re-deriving it.
##
## `_sector_now` starts at an impossible sector so the first frame counts as a
## change and the starting sector's environment is reported like any other.
var _sectors = null                                  ## Sacred.Sectors
var _sector_now := Vector2i(-1, -1)
var _sector_env := {}                                ## the current sector's env

# Plan 05-08: crowd benchmark. Opt-in only -- _has_crowd stays false unless
# --crowd= is literally present, so a bare "0" or a negative value still
# reaches the refuse-and-name-it path in _run_crowd() rather than silently
# doing nothing (T-05-44).
var _has_crowd := false
var _crowd_n := 0
var _crowd_arg := ""


func _ready() -> void:
	var install := Sacred.find_install()
	if install == "":
		push_error("OpenHeilig: no retail install found. Pass --install=/path/to/install, "
			+ "or write install_path into user://openheilig.cfg.")
		return

	var tiles_path := install.path_join("pak/tiles.pak")
	var tex_pak := Sacred.Pak.new(install.path_join("pak/texture.pak"))
	_world = Sacred.World.new(install.path_join("world"))
	var world := _world
	if not (FileAccess.file_exists(tiles_path) and tex_pak.is_open() and world.is_open()):
		return
	# Sacred's own pointer, straight from texture.pak. Cosmetic and non-fatal --
	# a failure warns and leaves the platform cursor. Skipped under --headless,
	# where there is no cursor to set and the scan would be pure waste.
	if DisplayServer.get_name() != "headless":
		RetailCursor.apply(tex_pak)

	var tiles := Sacred.Tiles.new(tiles_path)
	var statics: Sacred.Statics
	var static_pak := Sacred.Pak.new(install.path_join("world/static.pak"))
	if static_pak.is_open():
		statics = Sacred.Statics.new(static_pak)
	var mixed: Sacred.Mixed
	var mixed_pak := Sacred.Pak.new(install.path_join("pak/mixed.pak"))
	if mixed_pak.is_open():
		mixed = Sacred.Mixed.new(mixed_pak)
	var items: Sacred.Items
	var items_pak := Sacred.Pak.new(install.path_join("pak/items.pak"))
	if items_pak.is_open():
		items = Sacred.Items.new(items_pak)
	_shadow_items = items
	_shadow_creatures = Sacred.Creatures.new(install.path_join("pak"))
	_shadow_statics = statics
	_records = RecordStore.new(items, mixed)
	# The per-cell OVERLAY TILE layer (row 695). 188 MB, so it is read by
	# handle and never bulk-loaded; a missing or unreadable file just means the
	# terrain draws without its overlays, exactly as it did before.
	var floor_pak := Sacred.Pak.new(install.path_join("world/floor.pak"))
	if not floor_pak.is_open():
		floor_pak = null
	var footprints: Sacred.Footprints = null
	if statics != null and items != null:
		footprints = Sacred.Footprints.new(statics, items)
	var argv := OS.get_cmdline_user_args() + OS.get_cmdline_args()
	var stats := "--stats" in argv
	var markers := "--markers" in argv
	var objects := not ("--noobjects" in argv)
	_show_player = not ("--noplayer" in argv)
	_hide_player_mesh = "--hideplayer" in argv
	# --noanim builds the identical hero rig and SKIPS the clip, so a capture
	# pair differs in exactly one variable. Same shape as --creatures-noanim,
	# and it exists because the clip-to-rig binding is MEASURED rather than
	# certain (row 609): a body whose clip splays it must still be drawable.
	_animate_player = not ("--noanim" in argv)
	_dress_player_enabled = not ("--nodress" in argv)
	_wear_garments = "--dress-garments" in argv
	_show_hud = not ("--nohud" in argv)
	for a in argv:
		if a.begins_with("--walk-route="):
			var route_name := a.trim_prefix("--walk-route=")
			if route_name == "supported-in-out":
				_supported_route = true
			else:
				printerr("walk-route\tunsupported=%s" % route_name)
				get_tree().quit(1)
				return
	var show_regions := "--regions" in argv
	# --flags1e: paint WldxEntry +0x1e as an overlay (row 708). Debug only.
	var show_flags1e := "--flags1e" in argv
	var show_classhi := "--classhi" in argv
	# --spawns: tint each sector by what its script spawn tables roll there
	# (rows 728-737). Built here rather than in SectorView so the view keeps
	# taking plain data and never opens a file of its own.
	var show_spawns := "--spawns" in argv
	_show_creatures = "--creatures" in argv
	# --npcs: the scripted cast at its real cells (rows 831-833). Independent of
	# --creatures on purpose -- one is retail placement, the other a seeded
	# stand-in, and mixing them in one flag would blur exactly that distinction.
	_show_npcs = "--npcs" in argv
	_run_quests = not ("--noquests" in argv)
	var exterior := "--exterior" in argv
	var hide_levels := 0
	for a in argv:
		if a.begins_with("--hidelevel="):
			for d in a.trim_prefix("--hidelevel=").split(","):
				hide_levels |= 1 << int(d)
	var only_flag := -1
	for a in argv:
		if a.begins_with("--onlyflag="):
			only_flag = int(a.trim_prefix("--onlyflag="))
	var sortcube := Vector2i(-1, -1)
	for a in argv:
		if a.begins_with("--sortcube="):
			var p := a.trim_prefix("--sortcube=").split(",")
			if p.size() == 2:
				sortcube = Vector2i(int(p[0]), int(p[1]))
	# Single-model mode. NAME is only ever looked up in the pak's own name
	# table by Models.index_of -- it is never joined into a path, and never
	# opened as a file.
	var grn_name := ""
	for a in argv:
		if a.begins_with("--grn="):
			grn_name = a.trim_prefix("--grn=")
	# --figure=NAME [--stage=skeleton|mesh|textured|equipped] -- the STAGED model
	# viewer. One model, no world, no streamer, and one layer added at a time, so
	# a fault is attributed to the layer that introduced it instead of being
	# guessed at from a 60-pixel character in a camp. --grn= renders geometry only
	# and never passes texture.pak; this route is where the skin and the equipment
	# are looked at.
	var figure_name := ""
	var figure_stage := "equipped"
	var figure_yaw := 270.0
	var figure_surface := -1
	for a in argv:
		if a.begins_with("--figure="):
			figure_name = a.trim_prefix("--figure=")
		elif a.begins_with("--stage="):
			figure_stage = a.trim_prefix("--stage=")
		elif a.begins_with("--surface="):
			figure_surface = int(a.trim_prefix("--surface="))
		elif a.begins_with("--figure-yaw="):
			figure_yaw = float(a.trim_prefix("--figure-yaw="))
	# Single-clip mode. NAME is only ever looked up in the pak's own name
	# table by Models.clip_index_of -- kind-scoped, never joined into a path.
	var clip_name := ""
	for a in argv:
		if a.begins_with("--clip="):
			clip_name = a.trim_prefix("--clip=")
	# Task 2 counterfactual, the Godot-side twin of grn_tagwalk.py's
	# --falsify=N applied to the clip path: displaces the clip record's
	# base offset by N bytes before its count fields are read, so a real
	# desync can be shown to collapse the decode on this side too.
	var clip_falsify := 0
	for a in argv:
		if a.begins_with("--clip-falsify="):
			clip_falsify = int(a.trim_prefix("--clip-falsify="))
	# 05-12 Task 1: --anim=NAME, valid only alongside --grn=NAME -- it
	# plays NAME on the single-mesh rig --grn= already builds. NAME is
	# resolved through Models.clip_index_of, the identical kind-scoped
	# lookup --clip= uses, so it can never silently land on a mesh entry.
	var anim_name := ""
	for a in argv:
		if a.begins_with("--anim="):
			anim_name = a.trim_prefix("--anim=")
	var native_motion := -1
	for a in argv:
		if a.begins_with("--motion="):
			var value := a.trim_prefix("--motion=")
			if not value.is_valid_int() or int(value) < 0 or int(value) >= 256:
				printerr("motion\t--motion requires an integer enum in 0..255")
				get_tree().quit(1)
				return
			native_motion = int(value)
	if native_motion >= 0 and (grn_name.is_empty() or not anim_name.is_empty()):
		printerr("motion\tuse --motion with --grn, without --anim")
		get_tree().quit(1)
		return
	# 05-12 Task 2 counterfactual: deliberately breaks the clip-bone-name to
	# model-bone-name join build_animation() performs, to show that join is
	# load-bearing. "offset" resolves to find_bone(name) PLUS ONE; "drop"
	# skips the name lookup and binds every track to skeleton bone 0. Empty
	# is the normal, correct join and is what --anim= uses by default.
	var anim_falsify := ""
	for a in argv:
		if a.begins_with("--anim-falsify="):
			anim_falsify = a.trim_prefix("--anim-falsify=")
	# --anim-phase=F (0..1): the hero's IDLE phase as a fraction of the clip.
	# The fit against retail's own idle frames lands as a constant; negative
	# (the default) keeps the engine's phase-0 start.
	for a in argv:
		if a.begins_with("--anim-phase="):
			_anim_phase = clampf(float(a.trim_prefix("--anim-phase=")), 0.0, 1.0)
	# 05-12 Task 2: settles, in GDScript, which within-file mapping (directory
	for a in argv:
		if a.begins_with("--export-sera="):
			_export_sera = true
			_export_sera_path = a.trim_prefix("--export-sera=")
	# rather than cited from planning, against the bone's own stored rest
	# translation (decoded by different code from a different structure).
	var anim_key_report := ""
	for a in argv:
		if a.begins_with("--anim-key-report="):
			anim_key_report = a.trim_prefix("--anim-key-report=")
	# 05-12 Task 2: measures whether a clip's skeleton and the model's
	# skeleton are the SAME rig -- matched by exact bone NAME only, never by
	# index, never by parent_effective shape, never by the record's id.
	# --equip=PREFIX[,PREFIX...] draws every mesh whose name begins with any of
	# the prefixes on ONE shared pose -- the R1.4 demonstration (row 741). The
	# set is explicit rather than inferred: "GLAD" alone names 80 meshes, every
	# armour variant the Gladiator has, and overlaying all of them at once is
	# not an outfit. `--equip=GLADIATOR.GRN,GLAD_SA5` is a body plus one set.
	var equip_spec := ""
	for a in argv:
		if a.begins_with("--equip="):
			equip_spec = a.trim_prefix("--equip=")

	var anim_rigcheck := ""
	for a in argv:
		if a.begins_with("--anim-rigcheck="):
			anim_rigcheck = a.trim_prefix("--anim-rigcheck=")
	# --anim-riganchor=NAME runs the SAME measurement re-anchored at ANIM_ANCHOR.
	# It does not revise --anim-rigcheck=, whose REFUTED verdict (row 609) stands
	# as measured for file-root anchoring; it tests row 609's own named structural
	# explanation for that refutation -- an extra coordinate-alignment bone above
	# Bip01 present in the mesh file and absent from the clip file -- by removing
	# the differing root chain from both sides instead of the threshold from the
	# test. Same epsilon, same control, same verdict rule.
	for a in argv:
		if a.begins_with("--anim-riganchor="):
			anim_rigcheck = a.trim_prefix("--anim-riganchor=")
			_anim_rig_anchor = ANIM_ANCHOR
	for a in argv:
		if a.begins_with("--tickhz="):
			_tick_hz = clampi(int(a.trim_prefix("--tickhz=")), 1, 240)
		elif a.begins_with("--actor-probe="):
			_probe_ticks = int(a.trim_prefix("--actor-probe="))
		elif a.begins_with("--probe-route="):
			_probe_route = a.trim_prefix("--probe-route=")
		elif a.begins_with("--record="):
			_record_path = a.trim_prefix("--record=")
		elif a.begins_with("--replay="):
			_replay_path = a.trim_prefix("--replay=")
		elif a.begins_with("--dump="):
			_dump_path = a.trim_prefix("--dump=")
		elif a.begins_with("--autoplay="):
			_autoplay_ticks = int(a.trim_prefix("--autoplay="))
		elif a.begins_with("--spawn="):
			var p := a.trim_prefix("--spawn=").split(",")
			if p.size() == 2:
				_spawn_override = Vector2(float(p[0]), float(p[1]))
				_has_spawn_override = true
		elif a.begins_with("--falsify-mode="):
			_falsify_mode = a.trim_prefix("--falsify-mode=")
		elif a.begins_with("--falsify="):
			_falsify_tick = int(a.trim_prefix("--falsify="))
		elif a.begins_with("--scenario="):
			_scenario_name = a.trim_prefix("--scenario=")
		elif a.begins_with("--checkpoint-out="):
			_checkpoint_path = a.trim_prefix("--checkpoint-out=")
		elif a.begins_with("--checkpoint-ref="):
			_checkpoint_ref = a.trim_prefix("--checkpoint-ref=")
		elif a.begins_with("--save="):
			_save_path = a.trim_prefix("--save=")
		elif a.begins_with("--load="):
			_load_path = a.trim_prefix("--load=")
		elif a.begins_with("--crowd="):
			_has_crowd = true
			_crowd_arg = a.trim_prefix("--crowd=")
			_crowd_n = int(_crowd_arg)

	_registry = ActorRegistry.new()
	_sim = Sim.new(_tick_hz)
	if statics != null:
		_sim.interior = Interior.new(world, statics,
			Sacred.Triggers.new(install.path_join("world/triggers.pak")))

	# E1: resolve the scenario from the manifest BEFORE any mode dispatch, so
	# an ill-formed scenario name or a missing sidecar destination fails the
	# run at parse time rather than after minutes of streaming.
	if _scenario_name != "":
		if _checkpoint_path == "":
			push_error("scenario: --scenario=%s without --checkpoint-out= is refused -- "
				+ "a pixel-only scenario run is the failure mode this harness exists to prevent"
				% _scenario_name)
			get_tree().quit(1)
			return
		var manifest := _load_scenario_manifest("res://tools/scenarios.json")
		if manifest.is_empty():
			get_tree().quit(1)
			return
		var found := false
		for s: Dictionary in manifest.get("scenarios", []):
			if str(s.get("name", "")) == _scenario_name:
				_scenario_route = str(s.get("route", "default"))
				_scenario_checkpoint = _scenario_name
				_scenario_expect = s.get("checkpoint", {})
				_scenario_steps = s.get("steps", [])
				for m in s.get("shots_ms", []):
					_scenario_shots.append(int(m))
				if s.has("freeze_anim"):
					_scenario_freeze_at = float(s["freeze_anim"])
				found = true
				break
		if not found:
			push_error("scenario: '%s' is not in tools/scenarios.json" % _scenario_name)
			get_tree().quit(1)
			return
		print("scenario\tname=%s\troute=%s\tsteps=%d\tshots=%d\tout=%s" % [
			_scenario_name, _scenario_route, _scenario_steps.size(),
			_scenario_shots.size(), _checkpoint_path])

	# Streaming mode otherwise prints nothing at all, so a successful run and a
	# silently-failed one look identical from the terminal.
	print("OpenHeilig\t%s" % install)
	# R0: the profile is DECLARED at startup, gaps included -- a Windows tree
	# whose UI tables cannot be read announces that here, not as a mid-render
	# missing-table error.
	if Sacred.last_profile != null:
		print(Sacred.last_profile.summary_line())
		for gap in Sacred.last_profile.capability_gaps:
			push_warning("install capability gap: %s" % gap)
	print("  world\t%d of %d sectors present, %dx%d grid" % [
		world.count(), world.size.x * world.size.y, world.size.x, world.size.y])
	print("  tiles\t%d records -> %d textures" % [tiles.count(), tex_pak.count()])
	print("  statics\t%s\titems\t%s\trecords\t%s" % [
		"%d" % statics.count() if statics else "unavailable",
		"%d interior, %d levelled" % [items.count(), items.level_count()] if items else "unavailable",
		"%d" % _records.count() if _records.is_open() else "unavailable"])
	print("  sim\ttick %d Hz\tr_sim %.0f\tr_render %.0f\tr_load %.0f\tordered %s" % [
		_tick_hz, Sim.R_SIM, Sim.R_RENDER, Sim.R_LOAD,
		Sim.R_SIM < Sim.R_RENDER and Sim.R_RENDER < Sim.R_LOAD])

	# Before every mode branch below, because the record/replay and crowd paths
	# each return without reaching the streaming block and each read start_cell.
	for a in argv:
		if a.begins_with("--fight="):
			_fight_swings = maxi(0, a.trim_prefix("--fight=").to_int())
	_apply_retail_start(install)
	_player_type = _resolve_player_type()

	if figure_name != "":
		await _show_figure(install, figure_name, figure_stage, anim_name, figure_yaw, figure_surface)
		return

	if equip_spec != "":
		await _show_equip(install, equip_spec, anim_name)
		return

	if grn_name != "":
		await _show_model(install, grn_name, anim_name, anim_falsify, anim_key_report, anim_rigcheck, native_motion)
		return

	if clip_name != "":
		_show_clip(install, clip_name, clip_falsify)
		return

	if "--window-probe" in argv:
		_window_probe(world)
		return

	if "--interior-probe" in argv:
		_interior_probe(world, statics, items)
		return

	if "--follow-probe" in argv:
		_follow_probe()
		return

	if "--level-census" in argv:
		_level_census(items)
		return

	var family_scan := ""
	for a in argv:
		if a.begins_with("--family-scan="):
			family_scan = a.trim_prefix("--family-scan=")
	if family_scan != "":
		_family_scan(world, statics, items, family_scan.split(",", false))
		return


	if _has_crowd:
		await _run_crowd(install, world, tex_pak, tiles, statics, mixed, items)
		return

	if _record_path != "" or _replay_path != "":
		await _run_record_or_replay(world, install, tex_pak, tiles, statics, mixed, items, footprints)
		return

	_cam = IsoCamera.new()
	_cam.cell_limit = Vector2(world.size) * SECT
	add_child(_cam)

	_view = SectorView.new()
	_view.name = "SectorView"
	_view.setup(_cam, tex_pak, tiles, world, statics, mixed, items, {
		"stats": stats, "markers": markers, "objects": objects,
		"interior": _sim.interior, "regions": show_regions, "flags1e": show_flags1e, "classhi": show_classhi, "exterior": exterior, "hide_levels": hide_levels,
		"spawns": _spawn_tiers(install) if show_spawns else {},
		"only_flag": only_flag, "sortcube": sortcube,
		"floor_pak": floor_pak,
	})
	_view.sector_built.connect(_draw_scripted_objects.bind(_view, install))
	add_child(_view)

	# F3 overlay. Hidden until pressed, so captures and gates see the frame
	# they saw before it existed. Preloaded rather than named as a global
	# class -- see the script header.
	var overlay: CanvasLayer = DebugOverlayScript.new()
	overlay.setup(_cam, _view, _sim, _registry)
	# --overlay starts it shown, which is the only way a --shot=/--drive
	# capture can carry it: those runs never see a keystroke.
	overlay.visible = "--overlay" in argv
	add_child(overlay)

	# Experimental DLSS5 depth feed (see dlssnr_depth.gd). Off unless the flag
	# is present; the basic port path never loads it.
	if "--dlssnr-depth" in argv:
		var DepthFeed := load("res://dlssnr_depth.gd")
		if DepthFeed != null:
			add_child(DepthFeed.new(_cam))

	var region := _region_arg()

	# Plan 04-03: the player, spawned on real walkable ground exactly like
	# _run_record_or_replay's own Walkable/_resolve_spawn/_registry.spawn/
	# _sim.walk= sequence -- never a second implementation of spawn
	# derivation. Non-fatal on failure, matching RetailCursor.apply's degrade:
	# streaming mode drew nothing extra before this plan and keeps doing so
	# rather than aborting a run that has no walkable ground to stand on.
	#
	# Gated to the true default-streaming case only (no fixed region, no
	# --actor-probe=) -- both of those modes are pre-existing, self-contained
	# regression harnesses (28672-quad/63-texture region count; --actor-probe='s
	# id1..id19 fixed set and its PROBE_FOCUS-relative order/bands lines) that
	# assume nothing else occupies the registry or the frame. Spawning the
	# player there would not just shift ids, it would put an extra actor at
	# PROBE_FOCUS's own sector and change _actor_probe's band COUNTS, which
	# are geometric (in_radius().size()), not id-keyed. "The fixed region
	# mode, the single-model mode, the probe -- the camera keeps behaving
	# exactly as it does today" (plan 04-03 Task 2) states this as the
	# intended shape for those modes.
	if region == Vector3i.ZERO and _probe_ticks <= 0:
		var walk := Walkable.new(world)
		var spawn := _resolve_spawn(walk)
		if spawn.is_empty():
			push_warning("player: no walkable spawn cell found -- drawing nothing")
		else:
			var player_cell: Vector2 = spawn["cell"]
			# S0: the session OWNS the authoritative state. The hero's HP is
			# derived inside new_game() from the template's (STK, REPHY) pair
			# -- the same derivation the renderless check exercises, so both
			# paths produce identical state by construction. _registry/
			# _quest_log/_player_id remain as aliases for the many call sites
			# that predate the session; they are the same objects.
			_session = GameSession.new_game(install, player_cell)
			_registry = _session.registry
			_quest_log = _session.quest_log
			_sim = _session.sim
			_player_id = _session.player_id
			print("player\thp=%d\tderived=session new_game (%s)" % [
				_session.player_hp, _session.start_template])
			_sim.walk = walk
			_sim.focus_actor_id = _player_id
			_path_window = PathWindow.new(walk)
			_sim.path_window = _path_window
			_cam.move_click.connect(_on_move_click)
			if _sim.interior != null:
				_sim.interior.place_focus(player_cell, _player_type, _retail_start_layer)
			# World layer, so it is built here rather than beside the rigs: the
			# hostile is an actor whether or not anything is drawn.
			#
			# RETAIL'S NEW GAME RUNS QUEST 74's OnEnter: its console line
			# ("The Soul of the Demon.") is visible in the retained start
			# frame, and its hostile stands offscreen at monster107. The
			# encounter IS new-game state; only --fight resolves it headlessly.
			_begin_encounter(install, items)
			print("spawn\tcell=%.6f,%.6f\tclass=%d\tcomponent=%d\tsectors=%d" % [
				player_cell.x, player_cell.y, spawn["class"], spawn["component"], spawn["sectors"]])
			# The models pak is opened whenever ANY rig is wanted, not only when
			# the player is drawn. --noplayer is what every capture runbook passes
			# (row 616's settle race), so hanging the NPC and creature builds off
			# _show_player would make them silently absent from exactly the runs
			# that photograph them.
			var models_pak := Sacred.Pak.new(install.path_join("pak/models.pak"))
			if _show_player:
				if models_pak.is_open():
					# texture.pak, exactly as the creature and NPC builds below
					# pass it. Without it PlayerView documents its own result as
					# "clay", and clay is what the hero was: measured on the same
					# model, 0 coloured pixels in the world against 1364 once the
					# pak is passed. Every other rig in the world already got it;
					# the player was the one rig that did not.
					_player_view = PlayerView.new(Sacred.Models.new(models_pak), _player_model,
						tex_pak, PackedStringArray(BASE_HIDE), items.texture_of(_player_type) if items != null else -1)
					if _player_view.node != null:
						add_child(_player_view.node)
						_player_view.configure_actor(_player_type, items, _shadow_creatures)
						_player_shadow_heading = _player_view.initial_shadow_heading
						_player_shadow_last_facing = _registry.get_actor(_player_id).facing
						if _hide_player_mesh:
							_player_view.set_shown(false)
						print("player\tmodel=%s\tindex=%d\tverts=%d\ttris=%d" % [
							_player_model, _player_view.model_index,
							_player_view.vertex_count, _player_view.triangle_count])
						_dress_player(install, Sacred.Models.new(models_pak), items)
						_animate_hero(Sacred.Models.new(models_pak))
			_build_hud(tex_pak)
			if _hud != null and not _art_elements.is_empty():
				_hud.set_art_slot(_hud.ui_elements(install, tex_pak),
					_art_elements, 1.0)
			_build_sector_env(install)
			# _run_quests is in this list because the quest cast is rigs like any
			# other: without the light they build and render as black cut-outs,
			# which reads as a placement bug rather than a lighting one.
			if _show_player or _show_creatures or _show_npcs or _run_quests:
				_ensure_rig_light()
			if _show_creatures and models_pak.is_open():
				_build_creatures(install, Sacred.Models.new(models_pak), player_cell)
			if _show_npcs and models_pak.is_open():
				_build_npcs(install, Sacred.Models.new(models_pak), player_cell)
			if models_pak.is_open():
				_build_quest_cast(install, Sacred.Models.new(models_pak), items, tex_pak)
			# E1: everything the spawn-settled checkpoint reads now exists --
			# player, quest log, cast. A scenario run may checkpoint from here.
			_checkpoint_made = true
			if _export_sera:
				_export_pending = true

	if region != Vector3i.ZERO:
		await _view.load_region(region.x, region.y, region.z)
	else:
		_cam.set_zoom_index(1)   # middle of Sacred's three steps
		_cam.look_at_cell(start_cell)
	for arg in argv:
		if arg.begins_with("--zoom="):
			_cam.set_zoom_index(int(arg.trim_prefix("--zoom=")))
		elif arg.begins_with("--at="):
			var p := arg.trim_prefix("--at=").split(",")
			if p.size() == 2:
				_cam.look_at_cell(Vector2(float(p[0]), float(p[1])))
		elif arg.begins_with("--sector="):
			var p := arg.trim_prefix("--sector=").split(",")
			if p.size() == 2:
				_cam.look_at_cell((Vector2(float(p[0]), float(p[1])) + Vector2(0.5, 0.5)) * SECT)
	var at := _cam.world_to_cell(Vector2(_cam.position.x, _cam.position.y))
	print("  view\tcell %d,%d (sector %d,%d)\tzoom %d\t%s%s" % [
		at.x, at.y, at.x / SECT, at.y / SECT, _cam.size,
		"fixed region" if region != Vector3i.ZERO else "streaming",
		"\tmarkers on" if markers else ""])
	if _probe_ticks > 0:
		await _actor_probe(_probe_ticks, _probe_route)
	elif _scenario_name != "":
		# E1: scenario dispatch is BEFORE Drive.wanted() because a scenario
		# run passes --shots= for its own captures, and Drive.wanted() would
		# otherwise claim the run and bypass the checkpoint entirely --
		# exactly what the first verification run showed.
		await _run_scenario()
	elif _save_path != "" or _load_path != "":
		await _run_save_or_load()
	elif Drive.wanted(OS.get_cmdline_user_args() + OS.get_cmdline_args()):
		# --drive=/--shots= hand the streamed world to drive.gd, which owns the
		# timeline, the captures and the quit. Without this branch those flags
		# are parsed by nobody, _maybe_screenshot() sees no --shot= and returns
		# at once, and the process streams forever at 99% CPU until an outer
		# timeout kills it with no PNG written -- which is exactly how this
		# harness broke.
		await Drive.run(self, OS.get_cmdline_user_args() + OS.get_cmdline_args())
	elif _scenario_name != "":
		await _run_scenario()
	else:
		await _maybe_screenshot()


## --- E1: the scenario runner. Parses the manifest ONCE, refuses an
## ill-formed scenario before any capture, settles production readiness,
## drives the manifest's steps through the SAME Drive grammar, then writes
## the checkpoint sidecar and compares it against the reference when one was
## given. A scenario without --checkpoint-out= never reaches here: parse
## refused it, so a pixel-only run cannot masquerade as a scenario run.
func _load_scenario_manifest(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("scenario: cannot open manifest %s (%s)" % [
			path, error_string(FileAccess.get_open_error())])
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("scenario: %s is not a JSON object" % path)
		return {}
	if int(parsed.get("schema", -1)) != 1:
		push_error("scenario: manifest schema %s is not 1 -- refusing to guess the format" % str(parsed.get("schema")))
		return {}
	return parsed


## P1: the plain --save=/--load= route (no --scenario=). Save captures a
## session snapshot at the settle boundary and quits; load restores one
## over the fresh new-game world before the first capture, so a restart
## continues the saved state. Both refuse loudly rather than pretending.
func _run_save_or_load() -> void:
	if _player_id == ActorRegistry.INVALID_ID or _quest_log == null:
		push_error("save/load: no new-game state (player_id=%d, quest_log=%s)"
			% [_player_id, _quest_log != null])
		get_tree().quit(1)
		return
	if _save_path != "":
		var session := _session_dict()
		var snap := SaveState.snapshot(session)
		var err: String = SaveStore.save(_save_path, snap)
		if err != "":
			push_error("save: %s" % err)
			get_tree().quit(1)
			return
		print("save\twritten=%s\tactors=%d\tquests=%d\ttick=%d" % [
			_save_path, snap["actors"].size(), snap["quest_states"].size(),
			snap["tick"]])
		await _maybe_screenshot()
		return
	# LOAD: restore over the fresh world, then report the restored hero.
	var snap := SaveStore.load(_load_path)
	if snap.is_empty():
		push_error("load: %s has no usable save" % _load_path)
		get_tree().quit(1)
		return
	var err: String = SaveState.restore(snap, _session_dict())
	if err != "":
		push_error("load: %s" % err)
		get_tree().quit(1)
		return
	var p := _registry.get_actor(_player_id)
	print("load\trestored=%s\tcell=%.6f,%.6f\thp=%d\tquests=%d" % [
		_load_path, p.cell.x, p.cell.y, p.hp, _quest_log.vars().size()])
	await _maybe_screenshot()


## The authoritative-state dictionary SaveState consumes: the session's own
## objects when one exists (default streaming path), else the raw members
## (modes that predate the session -- probe, record/replay, fixed region).
func _session_dict() -> Dictionary:
	if _session != null:
		return {"registry": _session.registry, "quest_log": _session.quest_log,
			"player_id": _session.player_id, "tick": _session.tick,
			"tick_hz": _tick_hz}
	return {"registry": _registry, "quest_log": _quest_log,
		"player_id": _player_id, "tick": _sim.tick, "tick_hz": _tick_hz}


func _run_scenario() -> void:
	# THE PRECONDITION: the new-game state must actually exist. A scenario
	# whose world never spawned (no player, no quest log, no cast) has no
	# semantic content to checkpoint, and capturing that run's pixels would
	# be exactly the empty-frame comparison E1 exists to prevent.
	if _player_id == ActorRegistry.INVALID_ID or _quest_log == null:
		push_error("scenario: no new-game state to checkpoint (player_id=%d, quest_log=%s)"
			% [_player_id, _quest_log != null])
		get_tree().quit(1)
		return
	# POSE ALIGNMENT. A looping clip's phase depends on how many wall-clock
	# frames progressive loading consumed before the settle -- the exact
	# mechanism that made the old benchmark refuse its own repeats. When the
	# manifest names a freeze time, every animated rig is parked there BEFORE
	# the checkpoint and the shots, so `anim_clip_time` is exactly that time
	# in both runs and the pixel channel compares the same pose.
	var freeze := _scenario_freeze_at
	if not is_nan(freeze):
		var pmv: ModelView = null
		if _player_view != null:
			pmv = _player_view.node as ModelView
		if pmv != null:
			pmv.freeze_anim(freeze)
		for id: int in _scripted_views:
			var svm: ModelView = _scripted_views[id].node as ModelView
			if svm != null:
				svm.freeze_anim(freeze)
	var c: ScenarioCheckpoint = ScenarioCheckpoint.new()
	c.capture(self)
	if not _checkpoint_made:
		push_error("scenario: checkpoint captured but world_moved() never ran -- refusing")
		get_tree().quit(1)
		return
	var err: String = c.save(_checkpoint_path)
	if err != "":
		push_error("scenario: checkpoint write failed: %s" % err)
		get_tree().quit(1)
		return
	print("scenario\tcheckpoint=%s\tsim_tick=%d\tcell=%.6f,%.6f\thp=%d\tcast=%d\tquests=%d"
		% [_checkpoint_path, c.sim_tick, c.player_cell.x, c.player_cell.y,
		c.player_hp, c.cast_handles.size(), c.quest_states.size()])
	if _checkpoint_ref != "":
		var ref: ScenarioCheckpoint = ScenarioCheckpoint.from_dict(_read_json(_checkpoint_ref))
		var why: String = c.compare_against(ref)
		if why != "":
			push_error("scenario: REFUSED -- %s" % why)
			get_tree().quit(1)
			return
		print("scenario\tstate_match\tcheckpoint=%s" % _checkpoint_ref)
	# Pixel capture rides AFTER the state gate, so a state mismatch never
	# produces a PNG that could be mistaken for the reference.
	if not _scenario_shots.is_empty():
		var dir := _checkpoint_path.get_base_dir()
		var script := ""
		for s: Dictionary in _scenario_steps:
			script += "%d %s %s; " % [int(s["ms"]), s["verb"], " ".join(
				PackedStringArray(s["args"].map(func(x) -> String: return str(x))))]
		await Drive.run(self, ["--drive=" + script, "--shots=" + ",".join(
			_scenario_shots.map(func(m: int) -> String: return str(m))),
			"--drive-out=" + dir, "--drive-clock=frames"])
	else:
		await _maybe_screenshot()


func _read_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


## Releases the retail cursor texture before RenderingServer teardown. Without
## this, Input holds the ImageTexture past shutdown and its RID leaks -- see
## RetailCursor.clear() for the measurement.
func _exit_tree() -> void:
	RetailCursor.clear()


func _process(delta: float) -> void:
	if _export_pending:
		_export_frame += 1
		if _export_frame >= 3:
			_export_pending = false
			_export_hero_obj(_export_sera_path)
			return
	if _view != null:
		_view.stream(delta)
	if not _probe_active and not _replay_active:
		_advance_sim(delta, _focus_cell())
	# Arrival pickups consume after the tick that moved the hero, so the
	# same frame's view sees the item already in inventory.
	if _session != null:
		_session.after_tick()
	# Plan 04-03 Task 2: --noplayer means no player at all, not just an
	# invisible one -- the camera must keep behaving exactly as it does today
	# (Task 2's own reference-capture regression: --sector=50,50 with the
	# player suppressed, unchanged md5) when --noplayer is passed, which it
	# only would if follow is gated on _show_player too, not on _player_id
	# alone. Fixed-region mode, the probe and --grn= never reach here with a
	# valid _player_id at all (Task 1's fix gates player-spawn to the true
	# default-streaming case only), so those modes are unaffected either way.
	if _show_player and _player_id != ActorRegistry.INVALID_ID:
		var p := _registry.get_actor(_player_id)
		if p != null:
			_sync_hud_health(p)
			if _player_view != null:
				_player_view.update(p.cell)
				_face_player(p)
				_drive_hero_action(p)
			if _cam != null:
				_cam.follow_cell(p.cell)
			# Retail's sector-change path keys off the PLAYER's sector, not the
			# camera's -- panning the view does not change the music.
			_update_sector_env(p.cell)
	# Scripted-cast actors are simulation state. Their rigs follow the same
	# actor records the hero does, so an NPC_Goto walks rather than teleporting.
	for id: int in _scripted_views:
		var view: PlayerView = _scripted_views[id]
		var actor: ActorState = _registry.get_actor(id)
		if view == null or actor == null:
			continue
		view.update(actor.cell)
		if _sim.interior != null:
			_update_native_actor(view, actor.cell, view.initial_shadow_heading,
				_sim.interior.support_ref_at(Vector2i(actor.cell), 0))


## The composition boundary between simulation state and HUD pixels. ActorState
## remains scene-tree-free; Hud remains simulation-free. Unknown/zero maximum
## HP renders full rather than dividing by zero -- spawn already defaults full,
## so incomplete records do not invent damage.
func _sync_hud_health(actor: ActorState) -> void:
	if _hud == null or actor == null:
		return
	var fraction := 1.0 if actor.hp_max <= 0 else float(actor.hp) / float(actor.hp_max)
	_hud.set_health(fraction)
	if _encounter != null and not _encounter.hero_arts.is_empty():
		var a: Dictionary = _encounter.hero_arts[0]
		_hud.set_art_fraction(Regen.fraction(a["remaining"], a["total"]))


## The ONLY Sim per-frame advance call site outside godot-port/world/ -- a
## hard constraint, not a style preference: it is what makes "one tick loop"
## a greppable fact rather than a claim. Every caller of the sim goes
## through this one function -- including the record run below, which never
## drives ticks any other way, so recording stays on the real input path
## rather than a parallel one.
##
## When recording, the player's intent for the WHOLE frame is set once,
## before the one real call below, from _scripted_intent(pre_tick) -- a
## pure function of the tick count at the start of this frame -- and every
## tick that call runs is written to the recorder afterwards carrying that
## same intent (D-01, D-06).
func _advance_sim(dt: float, focus: Vector2) -> int:
	if _sim == null:
		return 0
	var pre_tick := _sim.tick
	var pre_dropped := _sim.dropped
	var intent := Vector2.ZERO
	var recording := _recorder != null and _recorder.is_open()
	var route_cell := PathWindow.NO_GOAL
	if recording and _player_id != ActorRegistry.INVALID_ID:
		intent = Vector2.ZERO if _supported_route else _scripted_intent(pre_tick)
		var p := _registry.get_actor(_player_id)
		if p != null:
			p.heading = intent
			if _supported_route:
				route_cell = _supported_route_cell(pre_tick + 1)
				p.cell = Vector2(route_cell) + Vector2(0.5, 0.5)
	# Plan 04-02: the one scripted goal request, threaded into the LIVE sim
	# exactly like a real caller would. The request names the TICK it is for and
	# Sim fires it when its own counter reaches that number.
	#
	# It used to be gated on `pre_tick + 1 == GOAL_REQUEST_TICK` -- "is the tick
	# about to run the goal tick?" -- with a comment claiming a catch-up burst
	# would merely delay it by one tick. That comment was wrong, and the gate
	# was a latent divergence (04-REVIEW CR-01): advance() runs up to
	# MAX_CATCHUP_TICKS ticks per call, so if GOAL_REQUEST_TICK landed second or
	# later in a burst the test failed, the goal was applied ZERO times (`tick`
	# only moves forward, so the edge could never fire again), and yet the
	# recorder's write loop below -- which range-tests every tick actually run --
	# still wrote the goal line. Replay then applied a goal the live run never
	# did. Setting the tick number instead makes the two agree by construction:
	# both now key off the same counter rather than off frame timing.
	if recording and _goal_cell != PathWindow.NO_GOAL and _sim.pending_goal_tick < 0 \
			and pre_tick < GOAL_REQUEST_TICK:
		_sim.pending_goal_actor_id = _player_id
		_sim.pending_goal = _goal_cell
		_sim.pending_goal_tick = GOAL_REQUEST_TICK
	var ran := _sim.advance(dt, _registry, focus)
	if recording:
		# The route cell the live run ACTUALLY applied for this whole advance --
		# chosen once from pre_tick + 1 above and held for every tick the burst
		# runs, because the actor cell is set before advance(), not per tick.
		# Recording _supported_route_cell(t) per tick instead would describe an
		# idealised schedule the live run never followed, and replay would then
		# diverge whenever a leg boundary landed mid-burst: measured, at tick 33
		# the recorder said INTERIOR while the live run was still on the DOOR.
		# The two-value schedule this route used before never straddled a burst,
		# which is the only reason the divergence had not surfaced.
		var applied_route_cell := _supported_route_cell(pre_tick + 1) if _supported_route else PathWindow.NO_GOAL
		for t in range(pre_tick + 1, pre_tick + ran + 1):
			var goal := _goal_cell if t == GOAL_REQUEST_TICK else PathWindow.NO_GOAL
			_recorder.write_input(t, intent, goal, applied_route_cell)
		if _sim.dropped > pre_dropped:
			_recorder.write_gap(_sim.tick, _sim.dropped - pre_dropped)
	return ran


func _on_move_click(goal: Vector2i) -> void:
	if _player_id == ActorRegistry.INVALID_ID or _sim == null or _sim.path_window == null:
		return
	if goal.x < 0 or goal.y < 0 or goal.x >= int(_cam.cell_limit.x) or goal.y >= int(_cam.cell_limit.y):
		return
	if _door_transition(goal):
		return
	# S0: commands enter through the session. When no session exists (probe/
	# record-replay/fixed-region modes), the direct sim write remains -- those
	# modes are self-contained harnesses, not the production path.
	if _session != null:
		_session.move_command(goal)
	else:
		_sim.pending_goal_actor_id = _player_id
		_sim.pending_goal = goal
		_sim.pending_goal_tick = -1
	print("click_goal\tcell=%d,%d\tactor=%d" % [goal.x, goal.y, _player_id])


## Door-object transition (retail moveDoorPosition equivalent, generalized).
## Returns true if `goal` is a DOOR/STEP cell inside a footprint region and
## the actor was moved across the doorway; false leaves the normal A* goal in
## place. The interior destination is the nearest FLOOR cell inside the
## region; the exterior destination is `DOOR_EXTERIOR_STEP` cells past the
## region edge on the door's outward side. The swap state follows from the
## existing Interior derive on the actor's new cell.
func _door_transition(goal: Vector2i) -> bool:
	if _sim.interior == null:
		return false
	var actor := _registry.get_actor(_player_id)
	if actor == null:
		return false
	var hit := _footprint_containing(goal)
	if hit.is_empty():
		return false
	var footprint: Dictionary = hit["footprint"]
	var region_key: int = hit["key"]
	var door := _nearest_door_cell(footprint, goal)
	if door == Vector2i(-1, -1):
		return false
	# Gate: only clicks ON or immediately beside the doorway may cross. A click
	# anywhere else in the footprint rect is the player walking around inside
	# the building -- before this gate, every interior click teleported the
	# actor across the door (in/out/in/out flip-flop, observed 2026-08-13).
	if maxi(absi(goal.x - door.x), absi(goal.y - door.y)) > DOOR_TRIGGER_RADIUS:
		return false
	var inside := _interior_current(region_key)
	var destination := _interior_destination(footprint, door) if not inside \
		else _exterior_destination(footprint, door, region_key)
	if destination == Vector2i(-1, -1):
		return false
	if not inside and not _sim.interior.enter_at(door):
		return false
	actor.cell = Vector2(destination) + Vector2(0.5, 0.5)
	if inside:
		# The teleport skips the authored STEP cell a walking exit would
		# tick; restore the left building to EXTERIOR explicitly, or its
		# roof stays off while the hero stands outside (measured,
		# drive-swapfix: derive never sees the STEP edge through the jump).
		_sim.interior.restore_remembered()
	print("door_transition\tcell=%d,%d\tfrom=%s\tto=%d,%d" % [
		goal.x, goal.y, Interior.state_name(Interior.State.INTERIOR if inside else Interior.State.EXTERIOR),
		destination.x, destination.y])
	return true


## Authored child region belonging to this cell's parent building.
## Its rectangle is used only for door destination selection, never art admission.
func _footprint_containing(cell: Vector2i) -> Dictionary:
	if _world == null or _sim.interior == null:
		return {}
	var parent := _sim.interior.parent_for_cell(cell)
	if parent.is_empty():
		return {}
	var child_id := _sim.interior.substate(parent["id"], 1)
	var region := _sim.interior.support_region(child_id)
	if region.is_empty() or not Rect2i(region["cell"], region["size"]).has_point(cell):
		return {}
	var child := _shadow_statics.get_object(child_id)
	var coordinates := _world.coordinates_for_id(child["sector"])
	return {
		"footprint": {"anchor": region["cell"], "size": region["size"], "region": region},
		"key": coordinates.x * 1000000 + coordinates.y * 1000 + region["index"],
	}


## Nearest DOOR/STEP cell in the footprint region to `cell`, or (-1,-1).
func _nearest_door_cell(fp: Dictionary, cell: Vector2i) -> Vector2i:
	var source: Dictionary = fp["region"]
	var anchor: Vector2i = fp["anchor"]
	var size: Vector2i = fp["size"]
	var best := Vector2i(-1, -1)
	var best_dist := 1 << 30
	for y in size.y:
		for x in size.x:
			var cls := Sacred.Regions.cell_class(source, x, y)
			if cls != Sacred.Regions.DOOR and cls != Sacred.Regions.STEP:
				continue
			var d := Vector2i(x + anchor.x, y + anchor.y).distance_squared_to(cell)
			if d < best_dist:
				best_dist = d
				best = Vector2i(x + anchor.x, y + anchor.y)
	return best


## True if the interior sim currently holds this packed region key INTERIOR.
func _interior_current(region_key: int) -> bool:
	if _sim.interior == null:
		return false
	return _sim.interior.current().get(region_key, Interior.State.EXTERIOR) == Interior.State.INTERIOR


## Nearest FLOOR cell inside the footprint region to `door`, or (-1,-1).
func _interior_destination(fp: Dictionary, door: Vector2i) -> Vector2i:
	var source: Dictionary = fp["region"]
	var anchor: Vector2i = fp["anchor"]
	var size: Vector2i = fp["size"]
	var best := Vector2i(-1, -1)
	var best_dist := 1 << 30
	for y in size.y:
		for x in size.x:
			var cls := Sacred.Regions.cell_class(source, x, y)
			if cls != Sacred.Regions.FLOOR:
				continue
			var c := Vector2i(x + anchor.x, y + anchor.y)
			var d := c.distance_squared_to(door)
			if d < best_dist:
				best_dist = d
				best = c
	return best


## Find the first cell outside the footprint and past the measured trigger
## approach corridor along the door's outward ray.
func _exterior_destination(fp: Dictionary, door: Vector2i, region_key: int) -> Vector2i:
	var anchor: Vector2i = fp["anchor"]
	var size: Vector2i = fp["size"]
	var centre := Vector2(anchor) + Vector2(size) * 0.5
	var outward := (Vector2(door) + Vector2(0.5, 0.5) - centre)
	if outward == Vector2.ZERO:
		return Vector2i(-1, -1)
	outward = outward.normalized()
	var max_distance := maxi(size.x, size.y) + DOOR_EXTERIOR_STEP + Interior.APPROACH_CELLS
	var best := Vector2i(-1, -1)
	var best_distance := 1 << 30
	for dy in range(-max_distance, max_distance + 1):
		for dx in range(-max_distance, max_distance + 1):
			var candidate := door + Vector2i(dx, dy)
			if Rect2i(anchor, size).has_point(candidate):
				continue
			var delta := Vector2(candidate - door)
			if delta.dot(outward) <= 0.0:
				continue
			if _sim.interior._triggered(candidate, region_key, fp):
				continue
			var distance := dx * dx + dy * dy
			if distance < best_distance:
				best_distance = distance
				best = candidate
	return best


func _focus_cell() -> Vector2:
	if _player_id != ActorRegistry.INVALID_ID:
		var p := _registry.get_actor(_player_id)
		if p != null:
			return p.cell
	if _cam == null:
		return start_cell
	return _cam.world_to_cell(Vector2(_cam.position.x, _cam.position.y))


## A fixed, deterministic schedule of movement directions, a pure function
## of the tick count alone -- positive x, then positive y, then a diagonal,
## then back -- chosen so all four axis-separated collision outcomes (x
## blocked / y free, y blocked / x free, both free, both blocked) are
## exercised against real walls over one recording run. Routed through the
## same `heading` field a keyboard would eventually set (world/actor_state.gd),
## so --record= records the real input path rather than a parallel one.
func _scripted_intent(tick: int) -> Vector2:
	var phase := (tick / 150) % 4
	if phase == 0:
		return Vector2(1.0, 0.0)
	elif phase == 1:
		return Vector2(0.0, 1.0)
	elif phase == 2:
		return Vector2(1.0, 1.0).normalized()
	return Vector2(-1.0, -1.0).normalized()


func _region_arg() -> Vector3i:
	for arg in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if not arg.begins_with("--region="):
			continue
		var p := arg.trim_prefix("--region=").split(",")
		if p.size() == 3:
			return Vector3i(int(p[0]), int(p[1]), int(p[2]))
	return Vector3i.ZERO


## Dresses the hero in the MEASURED new-game appearance (retail, user
## confirmed 2026-08-30): the base body's own painted outfit and its own
## shoes batch, one blade, nothing else equipped. The class template's item
## list (hero01.ptx) is the starting INVENTORY -- potions, a torch, the
## SeraHair01 headgear and one blade record that does not resolve in
## items.pak -- and of those only the headwear surfaces on the body; the
## drawn blade is the set's own weapon member, which matches retail's pixels
## (the template's blade record sits in the ~15% of save-item ids
## pax-saves.md could not map). --dress-garments wears the set's garments
## through the resolver as composition test coverage.
##
## The resolver is the slot model (items.gd): category byte -> slot -> worn
## vs bone-attached. Wings (25) land in no slot and skip with no special
## case -- the picker-screen-only rule the census measured. Garments worn
## through the resolver hide the base-body surfaces their slot displaces
## (ModelView.set_materials_hidden_by_token), so a worn boot no longer
## stacks on the body's own shoes -- and with nothing worn, nothing hides,
## which is exactly the state whose broken static version left the hero
## without feet.
func _dress_player(install: String, models: Sacred.Models, items: Sacred.Items) -> void:
	if _player_view == null or items == null:
		return
	# The guard lives HERE and not at the call sites, so a third caller
	# cannot be added that quietly ignores the flag.
	if not _dress_player_enabled:
		print("dress\tset=none\tmembers=0\tworn=0\tarmed=0\tworn_refused=0\tarm_refused=0\tunresolved=0\tskipped=0")
		return
	var sets := Sacred.Sets.new(install)
	if not sets.found:
		push_warning("dress: bin/sets.bin did not decode -- drawing the bare rig")
		return
	var members := sets.members_of(START_SET)
	var unresolved := 0
	var skipped := 0
	var worn := 0
	var hand := 1
	for rec in members:
		var nm: String = items.name_of(rec)
		var e := models.index_of(nm)
		if nm == "" or e < 0:
			unresolved += 1
			continue
		if items.is_worn(rec):
			# WORN garments stay off at the start scene (row 1101); the
			# resolver classifies them without a name table.
			if _wear_garments:
				if _player_view.wear(models, nm, items.texture_of(rec)):
					worn += 1
					_hide_worn_slot(items, rec)
			else:
				skipped += 1
		elif items.is_bone_attached(rec):
			# Rigid piece (blade): dock on the next free hand socket. The
			# second Wind blade is refused (no off-hand socket on SERAPHIM),
			# leaving exactly one blade docked.
			_player_view.equip(models, nm, hand, items.texture_of(rec))
			hand += 1
		else:
			# No slot: wings and every non-equipment category. The census
			# measured 25 (wings) as picker-screen display only.
			skipped += 1
	# Headwear from the class template: the one inventory item that
	# surfaces on the body at the start scene.
	var hero := Sacred.Hero.new(install.path_join("templates/" + START_TEMPLATE))
	if hero.found:
		for rec in hero.items():
			if items.is_worn(rec) and items.slot_of(rec) == Sacred.Items.Slot.HELMET \
					and _player_view.wear(models, items.name_of(rec), items.texture_of(rec)):
				worn += 1
				_hide_worn_slot(items, rec)
	print("dress\tset=%d\tmembers=%d\tworn=%d\tarmed=%d\tworn_refused=%d\tarm_refused=%d\tunresolved=%d\tskipped=%d" % [
		START_SET, members.size(), _player_view.worn(), _player_view.equipped(),
		_player_view.worn_refused(), _player_view.equipped_refused(), unresolved, skipped])


## Hide the base-body surfaces a successfully-worn record's slot displaces.
func _hide_worn_slot(items: Sacred.Items, rec: int) -> void:
	var tokens: Array = Sacred.Items.SLOT_HIDE_TOKENS.get(items.slot_of(rec), [])
	if not tokens.is_empty():
		_player_view.hide_base_surfaces(PackedStringArray(tokens))


func _begin_encounter(install: String, items) -> void:
	if _registry == null:
		return
	var creatures := Sacred.Creatures.new(install.path_join("pak"))
	var factions := Sacred.Factions.new(install)
	_encounter = Encounter.new(install, _registry, items, creatures, factions)
	if not _encounter.found:
		push_warning("encounter: '%s' is not in this tree -- no hostile spawned" % Encounter.FOE_PLACE)
		_encounter = null
		return
	_encounter.begin()
	print(_encounter.status_line())
	# E1: the encounter's quest log IS the scenario's quest state. Held once,
	# here, so ScenarioCheckpoint.capture reads the same object the VM wrote
	# rather than a copy.
	_quest_log = _encounter.log
	# The hero's first assigned art draws its slot from the art's own element
	# triple (row 1043 / sub_85E676A) -- NOT from the loose icon texture. The
	# element names route it to the skill or spell column; an art with no
	# triple (art 18) draws no slot at all. The HUD is built AFTER the
	# encounter begins (line order in _ready), so the triple is held and
	# applied by _build_hud.
	if not _encounter.hero_arts.is_empty():
		var arts := CombatArts.new(install)
		_art_elements = arts.elements(int(_encounter.hero_arts[0]["id"]))
		print("articon\tart=%d\telements=%s" % [
			int(_encounter.hero_arts[0]["id"]), _art_elements])
	# --fight=N runs the loop to its end so a headless run can show the whole
	# thing. Seeded, so two runs of the same command produce the same fight.
	# Starting a NEW game must show retail's new-game state. The quest-74
	# demonstration is opt-in (its own --fight= flag already drives it); without
	# that flag nothing spawns a hostile and the HUD carries no encounter art.
	if _fight_swings > 0:
		var rng := RandomNumberGenerator.new()
		rng.seed = FIGHT_SEED
		var n := 0
		while n < _fight_swings and not _encounter.is_complete():
			# USE AN ART WHEN ONE IS READY, otherwise swing plain. The headless
			# fight has no clock of its own, so the seconds between swings are
			# retail's own default recovery time -- `sub_81A8636` returns 20.0
			# for a creature with no weapon, which is exactly this hero. A
			# transcribed number rather than an invented cadence, but it is
			# still a stand-in for a real swing timer: see FIGHT_SWING_SECONDS.
			var pick := 0
			for id in _encounter.art_ids():
				if _encounter.art_ready(id):
					pick = id
					break
			var r: Dictionary = _encounter.strike(rng, pick)
			# BOTH SIDES OF THE CLOCK. `spent` is read before any time passes,
			# so a used art shows 0.0 there -- printing only the post-recovery
			# figure hid the mechanic entirely, because at this rate a level-1
			# art refills inside one swing.
			var spent := _encounter.art_fractions()
			_encounter.regenerate(FIGHT_SWING_SECONDS)
			n += 1
			print("swing\t%d\thit=%s\troll=%.3f\tchance=%.4f\thp=%d\tart=%d\tspent=%s\tafter=%s" % [
				n, r["hit"], r["roll"], r["chance"], _encounter.foe_hp(),
				int(r["art"]), spent, _encounter.art_fractions()])
		print(_encounter.status_line())
		for l in _encounter.log.lines:
			print("questbook\tquest=%d\tkind=%d\tkey=%s" % [
				int(l["quest"]), int(l["kind"]), str(l["key"])])
		# AND EXIT. Without this the fight resolves, prints, and the app then
		# carries on being the game forever -- every headless `--fight` run had
		# to be killed by an outer timeout, which reports SIGTERM and hides
		# whether the run actually finished. `--fight` is a batch flag; batch
		# flags terminate.
		#
		# quit() is DEFERRED to the end of the frame, so the rest of this
		# start-up path still runs. That is deliberate: it keeps the exit on
		# the same code path as a normal launch instead of tearing down a
		# half-built tree.
		get_tree().quit(0)


## --- E1 scenario accessors. Read-only views over authoritative state; no
## caller may mutate through them. ScenarioCheckpoint.capture is the only
## consumer.

## The scripted cast as handle -> creature id, in creation order. Read from
## the live QuestCast the hook ran, not from _scripted_views (which is
## renderer ownership and loses entries whose rig failed to build).
func _cast_snapshot() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _quest_cast != null:
		for e: Dictionary in _quest_cast.cast:
			out.append({"handle": e["handle"], "creature": e["creature"]})
	return out


## The hero's current animation identity and live clip time, or not-animated.
## NAN time means "no clip playing" and is its own deterministic channel.
func _anim_clip_state() -> Dictionary:
	var mv: ModelView = null
	if _player_view != null:
		mv = _player_view.node as ModelView
	if mv == null or not mv.is_playing():
		return {"name": "", "time": NAN}
	return {"name": _player_view.action, "time": mv.anim_time()}


func _apply_retail_start(install: String) -> void:
	if CLASS_MODEL.has(START_CLASS):
		_player_model = CLASS_MODEL[START_CLASS]
	else:
		push_warning("start: no body mesh mapped for %s -- drawing %s" % [START_CLASS, _player_model])
	var sc := Sacred.Startcode.new(install.path_join("bin").path_join(START_CLASS))
	_scripted_objects_by_sector.clear()
	for object: Dictionary in sc.objects:
		var cell: Vector2i = object["cell"]
		if cell == Sacred.Startcode.NO_CELL:
			continue
		var key := (cell.y / SECT) * 100 + cell.x / SECT
		if not _scripted_objects_by_sector.has(key):
			_scripted_objects_by_sector[key] = []
		_scripted_objects_by_sector[key].append(object)
	if sc.start_cell == Sacred.Startcode.NO_CELL:
		push_warning("start: %s declares no StartPosition -- keeping %s" % [START_CLASS, start_cell])
		return
	start_cell = Vector2(sc.start_cell)
	_retail_start = sc.start_cell
	_retail_start_layer = sc.start_layer
	print("start\tclass=%s\tmodel=%s\tcell=%d,%d\tlayer=%d\tsector=%d,%d" % [
		START_CLASS, _player_model, sc.start_cell.x, sc.start_cell.y, sc.start_layer,
		sc.start_cell.x / SECT, sc.start_cell.y / SECT])


## Opcode-8 authored objects are not the static.pak sprite list. Their model
## nodes belong to the sector, so unloading and revisiting cannot duplicate
## them or leave offscreen objects alive.
func _draw_scripted_objects(key: int, sector: Node3D, view: SectorView, install: String) -> void:
	if not view._objects or not _scripted_objects_by_sector.has(key) or view._interior == null:
		return
	var staging := Node3D.new()
	staging.name = "ScriptedObjects"
	staging.hide()
	sector.add_child(staging)
	_scripted_object_jobs.append({"sector": sector, "view": view, "install": install,
		"records": _scripted_objects_by_sector[key], "cursor": 0,
		"staging": staging})
	view.pending_scripted_objects += 1
	if not get_tree().process_frame.is_connected(_advance_scripted_objects):
		get_tree().process_frame.connect(_advance_scripted_objects)


## One shared allowance, not one independent coroutine allowance per sector.
## A single model construction is atomic; sector-sized groups are not.
func _advance_scripted_objects() -> void:
	var deadline := Time.get_ticks_usec() + 3000
	var detached_jobs := 0
	while not _scripted_object_jobs.is_empty() and Time.get_ticks_usec() < deadline:
		var job: Dictionary = _scripted_object_jobs[0]
		var view = job["view"]
		var sector = job["sector"]
		if not is_instance_valid(view) or not is_instance_valid(sector) \
				or sector.is_queued_for_deletion():
			if is_instance_valid(view):
				view.pending_scripted_objects -= 1
			_scripted_object_jobs.pop_front()
			continue
		# Temporary tree removal is not destruction. Resume this sector after
		# re-entry rather than permanently losing its unfinished objects.
		if not sector.is_inside_tree():
			_scripted_object_jobs.pop_front()
			_scripted_object_jobs.append(job)
			detached_jobs += 1
			if detached_jobs >= _scripted_object_jobs.size():
				break
			continue
		detached_jobs = 0
		if _scripted_models == null:
			var pak := Sacred.Pak.new(String(job["install"]).path_join("pak/models.pak"))
			if not pak.is_open():
				push_error("scripted objects: models.pak is unavailable")
				view.pending_scripted_objects -= 1
				job["staging"].queue_free()
				_scripted_object_jobs.pop_front()
				continue
			_scripted_models = Sacred.Models.new(pak)
		var records: Array = job["records"]
		if job["cursor"] < records.size():
			var record: Dictionary = records[job["cursor"]]
			job["cursor"] += 1
			var built := _build_scripted_object(record, job["staging"], view)
			if not built.is_empty():
				# Prepare its capture under the hidden staging root. Showing
				# the completed group must not allocate every capture at once.
				view.place_actor(built["model"], built["type"], built["cell"],
					built["support"], built["layer"])
		if job["cursor"] == records.size():
			job["staging"].show()
			view.pending_scripted_objects -= 1
			_scripted_object_jobs.pop_front()
	if _scripted_object_jobs.is_empty():
		get_tree().process_frame.disconnect(_advance_scripted_objects)


func _build_scripted_object(record: Dictionary, sector: Node3D, view: SectorView) -> Dictionary:
	var type_id: int = record["model"]
	var name := view._items.name_of(type_id)
	if name.is_empty():
		push_warning("scripted objects: unresolved model for type %d" % type_id)
		return {}
	var cell := Vector2(record["cell"]) + Vector2(0.5, 0.5)
	var support_ref := view._interior.initial_support_ref(record["cell"], type_id, record["layer"])
	var base_height := 0.0
	if support_ref != 0:
		var support := view._statics.blob(support_ref)
		if support.size() <= 51:
			push_error("scripted objects: unresolved support %d" % support_ref)
			return {}
		base_height = float(support[51]) * 28.0
	var data := view._interior.cell_data(record["cell"], support_ref)
	var height := PlayerView.NativeActorShadow.support_height(cell, data, 0, base_height)
	var heading := PlayerView.NativeActorShadow.heading_from_degrees(
		view._items.initial_heading_degrees(type_id))
	var object := PlayerView.new(_scripted_models, name, view._tex_pak,
		PackedStringArray(), view._items.texture_of(type_id))
	if object.node == null:
		return {}
	if not object.place_object(cell, heading, height, view._items.category_of(type_id)):
		push_error("scripted objects: unresolved native placement for type %d" % type_id)
		object.node.free()
		return {}
	object.node.name = "ScriptedObject_%s" % record["trigger"]
	sector.add_child(object.node)
	return {"model": object.node, "type": type_id, "cell": cell,
		"support": support_ref, "layer": record["layer"]}


## The chosen spawn cell as a fact line, its class, the component size and how
## many sectors were scanned. `--spawn=cx,cy` (a debugging override, not part
## of the falsifiable path) and the retail StartPosition below both skip the
## scan, so component/sectors read 0 in those cases rather than reporting a
## measurement that never ran.
func _resolve_spawn(walk: Walkable) -> Dictionary:
	if _has_spawn_override:
		var cls := walk.class_at(floori(_spawn_override.x), floori(_spawn_override.y))
		return {"cell": _spawn_override, "class": cls, "component": 0, "sectors": 0, "bbox": Rect2i()}
	# Retail's own StartPosition, used AS the spawn rather than as a search
	# seed. derive_spawn exists because nothing said where a character begins;
	# now something does, and "the largest walkable component within 121
	# sectors" is a worse answer than the cell the shipped game uses. Guarded
	# on walkability, because a cell retail accepts is not automatically open
	# under this port's navmesh -- if it is closed the derivation below still
	# runs and the run still produces a player.
	if _retail_start != Vector2i(-1, -1) and walk.is_open(_retail_start.x, _retail_start.y):
		var rc := Vector2(_retail_start) + Vector2(0.5, 0.5)
		return {"cell": rc, "class": walk.class_at(_retail_start.x, _retail_start.y),
			"component": 0, "sectors": 0, "bbox": Rect2i()}
	var centre := Vector2i(int(start_cell.x) / SECT, int(start_cell.y) / SECT)
	var best := walk.derive_spawn(centre)
	if best.is_empty():
		return {}
	var seed: Vector2i = best["seed"]
	var cell := Vector2(seed) + Vector2(0.5, 0.5)   # the cell's centre, not its lower corner
	var cls := walk.class_at(seed.x, seed.y)
	return {"cell": cell, "class": cls, "component": int(best["count"]), "sectors": int(best["sectors_scanned"]),
		"bbox": best.get("bbox", Rect2i())}


## BFS over open cells reachable from `spawn_cell`, bounded to `bbox` when
## non-empty, returning the farthest-by-cell-distance reachable cell found --
## i.e. a cell get_id_path() is GUARANTEED able to reach, since it is
## discovered by literally walking the same connectivity a path search
## would. Deliberately NOT a bbox-corner scan: a bbox corner can be open
## while belonging to a different, disconnected pocket of the same
## rectangular bbox (Walkable's own storey-ambiguity ponytail note,
## world/walkable.gd:70-74, is exactly this kind of surprise), which
## get_id_path() could never actually reach. Capped at MAX_VISITED so an
## unbounded bbox (the --spawn= override path, whose bbox is always empty)
## cannot turn one BFS into an unbounded scan.
func _goal_from_component(walk: Walkable, spawn_cell: Vector2, bbox: Rect2i) -> Vector2i:
	const MAX_VISITED := 20000
	const NEIGHBOURS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var start := Vector2i(floori(spawn_cell.x), floori(spawn_cell.y))
	if not walk.is_open(start.x, start.y):
		return PathWindow.NO_GOAL
	var bounded := bbox.size != Vector2i.ZERO
	var visited := {start: true}
	var queue: Array[Vector2i] = [start]
	var farthest := start
	var farthest_d2 := 0
	var qi := 0
	while qi < queue.size() and visited.size() < MAX_VISITED:
		var cur: Vector2i = queue[qi]
		qi += 1
		var d2 := (cur - start).length_squared()
		if d2 > farthest_d2:
			farthest_d2 = d2
			farthest = cur
		for d: Vector2i in NEIGHBOURS:
			var n := cur + d
			if bounded and not bbox.has_point(n):
				continue
			if visited.has(n) or not walk.is_open(n.x, n.y):
				continue
			visited[n] = true
			queue.append(n)
	return farthest


## --window-probe: a no-session self-check of PathWindow's pure geometry --
## no camera, no view, no registry, no Sim tick loop, only the static origin
## function and the two static geometry helpers. Task 2's acceptance gate
## parses this function's own stdout, so every printed line follows the
## house fact-line convention and every assertion prints a PASS/MISMATCH
## verdict token rather than merely trusting silence -- `grep -q MISMATCH`
## on the whole output is the gate's one failure check.
func _window_probe(world: Sacred.World) -> void:
	var stride := PathWindow.STRIDE
	# Cells spanning several stride buckets on both sides of zero -- negative
	# cells included, since origin_for() must floor-divide correctly there
	# too, matching Movement.sweep's own negative-coordinate precedent.
	var cells: Array[Vector2i] = [
		Vector2i(0, 0), Vector2i(stride - 1, 0), Vector2i(stride, 0),
		Vector2i(2 * stride, 0), Vector2i(2 * stride + 3, 3),
		Vector2i(-1, -1), Vector2i(-stride, -stride), Vector2i(-stride - 1, -stride - 1),
		Vector2i(-2 * stride, 5),
	]
	var mismatch := false
	var prev_origin := Vector2i.ZERO
	var prev_bucket := Vector2i.ZERO
	var has_prev := false
	for cell: Vector2i in cells:
		var origin := PathWindow.origin_for(cell)
		print("window\tcell=%d,%d\torigin=%d,%d" % [cell.x, cell.y, origin.x, origin.y])
		var bucket := Vector2i(floori(float(cell.x) / float(stride)), floori(float(cell.y) / float(stride)))
		if has_prev:
			if bucket == prev_bucket:
				var verdict := "PASS" if origin == prev_origin else "MISMATCH"
				if verdict == "MISMATCH":
					mismatch = true
				print("window\tcheck=same_bucket_same_origin\t%s" % verdict)
			else:
				var expect := prev_origin + (bucket - prev_bucket) * stride
				var verdict := "PASS" if origin == expect else "MISMATCH"
				if verdict == "MISMATCH":
					mismatch = true
				print("window\tcheck=adjacent_bucket_one_stride\t%s" % verdict)
		prev_origin = origin
		prev_bucket = bucket
		has_prev = true

	# Same cell twice, unrelated work between -- origin_for() is `static` and
	# reads nothing but its argument, so repeating it must reproduce exactly.
	var repeat_cell := Vector2i(37, -91)
	var first := PathWindow.origin_for(repeat_cell)
	var _unrelated := PathWindow.point_count() + int(PathWindow.max_corner_distance())
	var second := PathWindow.origin_for(repeat_cell)
	var det_verdict := "PASS" if first == second else "MISMATCH"
	if det_verdict == "MISMATCH":
		mismatch = true
	print("window\tcheck=repeat_call_determinism\t%s" % det_verdict)

	var point_count := PathWindow.point_count()
	var world_cells := int(world.size.x) * int(world.size.y) * SECT * SECT
	var ratio := float(point_count) / float(world_cells)
	print("window\tpoint_count=%d\tworld_cells=%d\tratio=%.6f" % [point_count, world_cells, ratio])

	var max_dist := PathWindow.max_corner_distance()
	print("window\tmax_corner_dist=%.6f\tr_load=%.6f\tbelow_r_load=%s" % [
		max_dist, Sim.R_LOAD, max_dist < Sim.R_LOAD])

	print("window\tresult=%s" % ("MISMATCH" if mismatch else "PASS"))
	get_tree().quit(1 if mismatch else 0)


## --level-census (06-01 Task 1): re-runs the research pass's strings-level
## family census through the real pipeline -- Sacred.Items' own `_name`
## table, the same one the swap reads, never a second parse of the pak.
## Regexes, re-stated here as named constants so a future regex edit cannot
## silently change what each arm meant in THIS measurement:
##   current         -- the exact pattern Items._init uses today.
##   trailing-letter -- current with one optional trailing ASCII letter after
##                      the final part number (the `_0_00A` / `_0_BODEN`
##                      shape), so the price and coverage of the parser-
##                      extension question are measured, not guessed.
##   control         -- deliberately wrong: requires a THREE-digit part
##                      number. It MUST differ from current on at least one
##                      named family; a census whose control cannot disagree
##                      certifies nothing -- printed as control_check.
##                      (06-01 executor note: the plan's literal two-digit
##                      variant was measured first and produced IDENTICAL
##                      counts on all six families -- their parseable parts
##                      are all already two-digit -- so it certified nothing
##                      at family level and was replaced by this stricter
##                      variant, satisfying the contract the plan itself
##                      states: the control must be able to disagree.)
## --interior-probe (06-03 Task 1): a scripted-cell tracer through the REAL
## Sim.tick_once -> Interior.derive -> output_hook -> Replay.Dumper path. Direct
## cell assignment is probe scaffolding only; Task 2 separately proves movement.
## Site is 06-02 row 625's measured OZELT1 tent: sector 53,28, region anchor
## 3410,1829 size 16x19, door 3422,1844, interior floor 3420,1840.
func _interior_probe(world: Sacred.World, statics: Sacred.Statics, items: Sacred.Items) -> void:
	if statics == null or items == null or _dump_path == "":
		printerr("interior_probe\trequires static.pak, items.pak and --dump=PATH")
		get_tree().quit(1)
		return
	var walk := Walkable.new(world)
	var footprints := Sacred.Footprints.new(statics, items)
	var resolved := footprints.resolve(world.sector(53, 28), 53, 28)
	var target_index := -1
	for index: int in resolved:
		var fp: Dictionary = resolved[index]
		if String(fp["family"]).begins_with("OZELT1"):
			target_index = index
			break
	if target_index < 0:
		printerr("interior_probe\tno OZELT1 footprint in measured sector 53,28")
		get_tree().quit(1)
		return
	var target_key := 53 * 1000000 + 28 * 1000 + target_index
	var interior := _sim.interior
	var sim := Sim.new(_tick_hz)
	var reg := ActorRegistry.new()
	var outside := Vector2(3420.5, 1826.5)  # north wall-negative side, row 625
	var actor_id := reg.spawn(_first_real_record_id(), outside, 100, 100)
	reg.get_actor(actor_id).heading = Vector2.ZERO
	sim.focus_actor_id = actor_id
	sim.interior = interior
	var dumper := Replay.Dumper.new(_dump_path)
	if not dumper.is_open():
		get_tree().quit(1)
		return
	sim.output_hook = func(tick: int, dropped: int, astar_event: Dictionary) -> void:
		dumper.write_tick(tick, dropped, reg)
		dumper.write_astar(tick, astar_event)
		dumper.write_swap(tick, interior.last_changes())
		for change: Dictionary in interior.last_changes():
			print("interior_probe\ttick=%d\tregion=%d\tfrom=%s\tstate=%s\tfamily=%s" % [
				tick, change["key"], Interior.state_name(change["from"]),
				Interior.state_name(change["to"]), change["family"]])
	var sequence: Array[Vector2] = [
		outside, Vector2(3422.5, 1844.5), Vector2(3420.5, 1840.5), outside,
	]
	for position: Vector2 in sequence:
		reg.get_actor(actor_id).cell = position
		sim.tick_once(reg, position)
	dumper.close()
	var states := interior.current()
	print("interior_probe\tresult=%s\tregion=%d\tmixed=%d" % [
		"PASS" if states.get(target_key, Interior.State.EXTERIOR) == Interior.State.EXTERIOR else "FAIL",
		target_key, footprints.mixed])
	get_tree().quit(0)


const CENSUS_RX := {
	"current": "_(\\d)(?:U(\\d))?_\\d+$",
	"trailing-letter": "_(\\d)(?:U(\\d))?_\\d+[A-Za-z]?$",
	"control": "_(\\d)(?:U(\\d))?_\\d\\d\\d+$",
}
const CENSUS_FAMILIES := [
	"OZELT1", "BLACKSMITH", "KLOSTER_KAPELLE01",
	"ARENA_V", "ARENA_DUNGEON", "KELLER_PENTA",
]
const CENSUS_RX_ORDER := ["current", "trailing-letter", "control"]

func _level_census(items: Sacred.Items) -> void:
	if items == null:
		push_error("OpenHeilig: --level-census needs items.pak")
		return
	var results := {}
	for rxname in CENSUS_RX_ORDER:
		var rx := RegEx.create_from_string(CENSUS_RX[rxname])
		results[rxname] = items.census(CENSUS_FAMILIES, rx)
		for r in results[rxname]:
			print("census\t%s\t%s\tnamed=%d\tparseable=%d" % [
				r["prefix"], rxname, r["named"], r["parseable"]])
		var t := items.census_totals(rx)
		print("census_total\t%s\tnamed=%d\tparseable=%d" % [
			rxname, t["named"], t["parseable"]])
	var differing: Array[String] = []
	for i in CENSUS_FAMILIES.size():
		var cur: Dictionary = results["current"][i]
		var ctl: Dictionary = results["control"][i]
		if ctl["parseable"] != cur["parseable"]:
			differing.append(cur["prefix"])
	print("control_check=%s\tdiffering=%s" % [
		"PASS" if differing.size() > 0 else "FAIL", ",".join(differing)])


## --family-scan=PREFIX[,PREFIX...] (06-01 Task 2): world-wide sector
## localisation by sprite-name prefix. Walks the whole sector grid in
## ascending gy*100+gx order (two runs print byte-identical output), decodes
## each cell's object handle exactly the way SectorView._build_objects does
## (the `i * Sacred.CELL + 4` offset), resolves it through
## Statics.get_object -> mixed.pak sprite id -> Items.name_of, and counts
## names beginning with each prefix. Prints one `scan` fact line per
## (prefix, sector) with a non-zero count, a `scan_progress` line every 500
## populated sectors (a stuck run is distinguishable from a slow one), one
## `arena_site` summary per prefix, a `coverage` line per hit sector (region
## records at the site -- zero records means the player cannot path there),
## and, when the run carries ARENA_V plus a cellar prefix, the
## cellar_position verdict. A full grid pass is allowed to take minutes.
func _family_scan(world: Sacred.World, statics: Sacred.Statics,
		items: Sacred.Items, prefixes: PackedStringArray) -> void:
	if statics == null or items == null:
		push_error("OpenHeilig: --family-scan needs static.pak and items.pak")
		return
	var by_sector := {}   # prefix -> {Vector2i: count}
	for p in prefixes:
		by_sector[p] = {}
	var populated := 0
	for gy in world.size.y:
		for gx in world.size.x:
			if not world.has_sector(gx, gy):
				continue
			populated += 1
			if populated % 500 == 0:
				print("scan_progress\tpopulated=%d" % populated)
			var cells := world.entries(gx, gy)
			if cells.is_empty():
				continue
			var here := {}   # prefix -> count, this sector only
			for i in Sacred.SECT * Sacred.SECT:
				var o := statics.get_object(cells.decode_u32(i * Sacred.CELL + 4))
				if o.is_empty():
					continue
				var nm := items.name_of(o["type"])
				for p in prefixes:
					if nm.begins_with(p):
						here[p] = here.get(p, 0) + 1
			for p in prefixes:
				if here.get(p, 0) > 0:
					by_sector[p][Vector2i(gx, gy)] = here[p]
					print("scan\tprefix=%s\tsector=%d,%d\tcount=%d" % [
						p, gx, gy, here[p]])
	# Per-prefix site summary: hit sectors ascending plus total sprites.
	var hit_union := {}   # Vector2i -> true
	for p in prefixes:
		var sectors: Array = by_sector[p].keys()
		sectors.sort_custom(func(a, b): return a.y * 100 + a.x < b.y * 100 + b.x)
		var total := 0
		var names: Array[String] = []
		for s in sectors:
			total += by_sector[p][s]
			names.append("%d,%d" % [s.x, s.y])
			hit_union[s] = true
		print("arena_site\tprefix=%s\tsprites=%d\tsectors=[%s]" % [
			p, total, ";".join(names)])
	print("scan_summary\tprefixes=%s\thits=%d" % [",".join(prefixes), hit_union.size()])
	# The disposition datum: does the cellar art stand at the arena, or
	# somewhere disjoint? Only computable when the run carries both sides.
	if "ARENA_V" in by_sector \
			and ("ARENA_DUNGEON" in by_sector or "KELLER_PENTA" in by_sector):
		var arena: Array = by_sector["ARENA_V"].keys()
		var cellar: Array = []
		for cp in ["ARENA_DUNGEON", "KELLER_PENTA"]:
			if cp in by_sector:
				cellar.append_array(by_sector[cp].keys())
		cellar.sort_custom(func(a, b): return a.y * 100 + a.x < b.y * 100 + b.x)
		var verdict := "absent"
		if cellar.size() > 0:
			verdict = "co-located"
			for c in cellar:
				var near := false
				for a in arena:
					if maxi(absi(c.x - a.x), absi(c.y - a.y)) <= 1:
						near = true
						break
				if not near:
					verdict = "disjoint"
					break
		var arena_names: Array[String] = []
		arena.sort_custom(func(a, b): return a.y * 100 + a.x < b.y * 100 + b.x)
		for s in arena:
			arena_names.append("%d,%d" % [s.x, s.y])
		var cellar_names: Array[String] = []
		for s in cellar:
			cellar_names.append("%d,%d" % [s.x, s.y])
		print("cellar_position=%s\tarena_sectors=[%s]\tcellar_sectors=[%s]" % [
			verdict, ";".join(arena_names), ";".join(cellar_names)])
	# Region-record coverage at every hit sector: no records, no path.
	var cov: Array = hit_union.keys()
	cov.sort_custom(func(a, b): return a.y * 100 + a.x < b.y * 100 + b.x)
	for s in cov:
		var regions := Sacred.Regions.new(world.sector(s.x, s.y), s.x, s.y)
		var recs: Array[String] = []
		for r in regions.list:
			recs.append("%d,%d %dx%d" % [
				r["cell"].x, r["cell"].y, r["size"].x, r["size"].y])
		print("coverage\tsector=%d,%d\tregions=%d\trecs=[%s]" % [
			s.x, s.y, regions.list.size(), ";".join(recs)])


## --follow-probe: IsoCamera.follow_cell() fed a fixed cell carrying a
## deliberate sub-cell fraction, at each of the three measured ZOOM_SCALES
## steps in turn. No session, no player, no streaming -- pure geometry,
## mirroring --window-probe's shape (R3.4: the three measured steps, proven
## by a printed check rather than asserted). A real IsoCamera is built and
## added to the tree (never a hand-rolled stand-in) because follow_cell's
## own odd-viewport-height guard reads get_viewport(), which needs a node
## actually in the scene tree to answer.
func _follow_probe() -> void:
	# 3232.37,3232.61: fractional in both cell axes, so cell_to_world's
	# (x-y)/(x+y) combination keeps a non-trivial fraction on both projected
	# world axes too -- verified by hand to differ from its snapped target
	# at all three zoom steps, not just a coincidental one.
	var probe_cell := Vector2(3232.37, 3232.61)
	var cam := IsoCamera.new()
	add_child(cam)
	var mismatch := false
	for i in IsoCamera.ZOOM_SCALES.size():
		cam.set_zoom_index(i)
		var scale: float = IsoCamera.ZOOM_SCALES[i]
		var unsnapped := IsoCamera.cell_to_world(probe_cell)
		cam.follow_cell(probe_cell)
		var snapped := Vector2(cam.position.x, cam.position.y)
		# Independent of follow_cell's own arithmetic: "on the pixel grid at
		# scale s" means snapped*s is a whole number, checked here rather
		# than trusted from how the value was produced.
		var on_grid := is_equal_approx(snapped.x * scale, roundf(snapped.x * scale)) \
			and is_equal_approx(snapped.y * scale, roundf(snapped.y * scale))
		if not on_grid:
			mismatch = true
		print("follow\tstep=%d\tscale=%.6f\tunsnapped=%.6f,%.6f\tsnapped=%.6f,%.6f\tverdict=%s" % [
			i, scale, unsnapped.x, unsnapped.y, snapped.x, snapped.y,
			"MISMATCH" if not on_grid else "PASS"])
	cam.queue_free()
	get_tree().quit(1 if mismatch else 0)




## Builds the Walkable navmesh, derives (or takes the override for) the
## spawn cell, spawns the player, and dispatches into a record run or a
## replay run. Normally builds no camera or SectorView at all --
## _focus_cell() resolves through the player once one exists (above), so
## neither mode depends on anything drawn, matching _show_model's no-view
## shape.
##
## --liveview (Task 3 Gate 2 only) is the one exception: paired with
## --record=, it builds the camera, the streamer and the player mesh exactly
## like the default streaming branch does, so the recording run has the
## whole view layer switched on -- camera following, sectors streaming,
## player drawn -- while --replay= (no --liveview passed) stays exactly the
## no-view path it always was. D-14 says camera/streaming state must never
## reach the dump; the only way to prove that is to make the two runs differ
## in nearly everything BUT the simulation, which is what this gives Gate 2.
func _run_record_or_replay(world: Sacred.World, install: String, tex_pak: Sacred.Pak,
		tiles: Sacred.Tiles, statics: Sacred.Statics, mixed: Sacred.Mixed, items: Sacred.Items,
		footprints: Sacred.Footprints) -> void:
	var argv := OS.get_cmdline_user_args() + OS.get_cmdline_args()
	var live_view := "--liveview" in argv
	var walk := Walkable.new(world)
	var spawn := _resolve_spawn(walk)
	if spawn.is_empty():
		printerr("record/replay\tno walkable spawn cell found")
		get_tree().quit(1)
		return
	var cell: Vector2 = spawn["cell"]
	print("spawn\tcell=%.6f,%.6f\tclass=%d\tcomponent=%d\tsectors=%d" % [
		cell.x, cell.y, spawn["class"], spawn["component"], spawn["sectors"]])

	var rec_id := _first_real_record_id()
	_player_id = _registry.spawn(rec_id, cell, 100, 100)
	_sim.walk = walk
	_sim.focus_actor_id = _player_id
	var interior := _sim.interior
	if interior != null:
		interior.place_focus(cell, _player_type, _retail_start_layer)
	# The record/replay route replays the recorded state, including any
	# --fight run that spawned the encounter; it keeps the direct call.
	_begin_encounter(install, items)

	if live_view and _record_path != "":
		_cam = IsoCamera.new()
		_cam.cell_limit = Vector2(world.size) * SECT
		add_child(_cam)
		_view = SectorView.new()
		_view.name = "SectorView"
		_view.setup(_cam, tex_pak, tiles, world, statics, mixed, items,
			{"interior": interior})
		_view.sector_built.connect(_draw_scripted_objects.bind(_view, install))
		add_child(_view)
		_cam.set_zoom_index(1)
		_cam.look_at_cell(cell)
		var models_pak := Sacred.Pak.new(install.path_join("pak/models.pak"))
		if models_pak.is_open():
			_player_view = PlayerView.new(Sacred.Models.new(models_pak), _player_model,
				tex_pak, PackedStringArray(BASE_HIDE), items.texture_of(_player_type) if items != null else -1)
			if _player_view.node != null:
				add_child(_player_view.node)
				_player_view.configure_actor(_player_type, items, _shadow_creatures)
				_player_shadow_heading = _player_view.initial_shadow_heading
				_player_shadow_last_facing = _registry.get_actor(_player_id).facing
				print("player\tmodel=%s\tindex=%d\tverts=%d\ttris=%d" % [
					_player_model, _player_view.model_index,
					_player_view.vertex_count, _player_view.triangle_count])
				_dress_player(install, Sacred.Models.new(models_pak), items)
				_animate_hero(Sacred.Models.new(models_pak))

	# Plan 04-02: the sliding path window and its one scripted goal request,
	# derived from the ACTUAL spawn component -- never a hardcoded cell, so
	# it stays a real goal against whatever install is loaded.
	_path_window = PathWindow.new(walk)
	_sim.path_window = _path_window
	var bbox: Rect2i = spawn.get("bbox", Rect2i())
	_goal_cell = _goal_from_component(walk, cell, bbox)
	if _supported_route:
		_goal_cell = PathWindow.NO_GOAL
		print("supported-route\tname=supported-in-out\toutside=%d,%d\tdoor=%d,%d\tinterior=%d,%d\tstep=%d,%d\tregion=%d,%d,%d\tinterior_tick=%d\texterior_tick=%d\twalked_cells=%d\tcontrol=default-zero-swap" % [
			SUPPORTED_ROUTE_OUTSIDE.x, SUPPORTED_ROUTE_OUTSIDE.y,
			SUPPORTED_ROUTE_DOOR.x, SUPPORTED_ROUTE_DOOR.y,
			SUPPORTED_ROUTE_INTERIOR.x, SUPPORTED_ROUTE_INTERIOR.y,
			SUPPORTED_ROUTE_STEP.x, SUPPORTED_ROUTE_STEP.y,
			SUPPORTED_ROUTE_REGION.x, SUPPORTED_ROUTE_REGION.y, SUPPORTED_ROUTE_REGION.z,
			SUPPORTED_ROUTE_INTERIOR_TICK, SUPPORTED_ROUTE_EXTERIOR_TICK, SUPPORTED_ROUTE_PATH.size()])
	else:
		print("goal\tcell=%d,%d" % [_goal_cell.x, _goal_cell.y])

	if _dump_path != "":
		_dumper = Replay.Dumper.new(_dump_path)
		if _dumper.is_open():
			# ponytail-adjacent bugfix, not a placeholder: the closure takes
			# tick/dropped/astar_event as call() arguments rather than
			# capturing `sim` (which IS _sim, the object this closure is
			# stored ON as output_hook) -- capturing it would make Sim hold
			# a Callable that holds a strong ref back to Sim itself, a
			# self-cycle RefCounted's plain refcounting can never collect,
			# which is exactly what leaked ~120 objects (Sim + its reg +
			# walk + walk's whole _region_cache) at process exit until this
			# fix. `path_window` is safe to capture -- it holds no reference
			# back to Sim.
			var dumper := _dumper
			var reg := _registry
			# `interior` is another non-Sim RefCounted capture, like path_window:
			# it holds no reference back to Sim, so no self-cycle is introduced.
			_sim.output_hook = func(tick: int, dropped: int, astar_event: Dictionary) -> void:
				dumper.write_tick(tick, dropped, reg)
				dumper.write_astar(tick, astar_event)
				dumper.write_swap(tick, interior.last_changes())

	if _record_path != "":
		await _run_record()
	else:
		await _run_replay()


## Drives the normal per-frame loop (via _process -> _advance_sim, the one
## real advance call site) until _autoplay_ticks ticks have run, writing
## input/gap lines the whole way, then closes the recording and the dump
## and quits.
func _run_record() -> void:
	_recorder = Replay.Recorder.new(_record_path, _sim.tick_hz, _registry.get_actor(_player_id).cell, _player_id)
	if not _recorder.is_open():
		get_tree().quit(1)
		return
	for _i in RECORD_FRAME_BUDGET:
		await get_tree().process_frame
		if not is_instance_valid(self):
			return
		if _sim.tick >= _autoplay_ticks:
			break
	_recorder.close()
	if _dumper != null:
		_dumper.close()
	get_tree().quit(0)


## Suppresses _process()'s normal advance call (_replay_active, mirroring
## _probe_active) and hands the whole drive loop to Replay.replay(), which
## drives one tick per recorded line straight through Sim's per-tick entry
## point and never touches the accumulator (D-04).
func _run_replay() -> void:
	_replay_active = true
	# Task 3: the third perturbation mode. Off unless --falsify-mode=origin
	# is passed alongside --falsify=TICK -- the offset itself is a plain
	# number sourced here at the composition root (ORIGIN_PERTURB_OFFSET),
	# never anything camera-derived and never anything inside world/.
	var origin_perturb := ORIGIN_PERTURB_OFFSET if _falsify_mode == "origin" else Vector2i.ZERO
	var err := Replay.replay(_replay_path, _sim, _registry, _player_id,
		_falsify_tick, _falsify_mode, origin_perturb)
	if _dumper != null:
		_dumper.close()
	get_tree().quit(0 if err == OK else 1)


## Pumps the same progressive streamer used during play. A frame-count limit
## is invalid once construction deliberately spans many inexpensive frames.
## Timeout is an error, never permission to measure a partially built scene.
func _pump_until_settled() -> bool:
	var deadline := Time.get_ticks_msec() + VIEW_SETTLE_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		if not is_instance_valid(self):
			return false
		if _view.is_settled():
			return true
	push_error("View did not settle before the readiness deadline")
	get_tree().quit(1)
	return false


## Plan 05-08: --crowd=N. Opt-in only, never runs without the flag.
##
## CURRENT SCOPE (05-14; set by reading the FIRST PARAGRAPHS of
## the 05-11 write-up, the 05-12 write-up and the 05-13 write-up before touching
## this code, per plan 05-14's halt_contract -- the one-landed/
## one-halted branch, so this route measures exactly what exists and every
## printed line names what is absent):
##
##   composition=ABSENT. 05-11 HALTED: "There is NO composed multi-piece
##     rig anywhere in godot-port/" (the 05-11 write-up first paragraph,
##     findings row 607); the one-shared-skeleton design is REFUTED by
##     measurement, twice, by two independent tests (05-10, rows 605/606).
##     ModelView.setup_composed()/swap_slot() and a PlayerView equipment
##     list do not exist anywhere.
##   animation=PRESENT at the ModelView/reader level ONLY. 05-12 Task 1
##     landed ModelView.build_animation()/play_clip() (commit 5c3ddbc),
##     checkpoint-verified playing a named clip on the single-mesh base
##     rig. The PlayerView/live-game-world wiring (05-12 Task 3) did NOT
##     run -- 05-12 Task 2's clip-vs-model rig-agreement measurement came
##     back REFUTED (row 609) -- so PlayerView has no play_clip() and no
##     animation plays during normal streaming. 05-13 then halted as well:
##     no anim_check.gd sequence gate exists.
##
## This route therefore builds N SINGLE-MESH PlayerView rigs -- still the
## only rig-construction code path that exists, the same one the real
## player uses -- and drives playback on each rig's ModelView through the
## identical play_clip() call main.gd's --anim= route makes. Every number
## it prints EXCLUDES composition cost (none exists) and EXCLUDES any
## live-world animation wiring (none exists): it is the cost of N
## single-mesh rigs each playing one named clip at the reader level, on
## top of a world that keeps streaming. It is NOT a full phase-5
## crowd-budget figure and must never be read as one.
##
## Existing load to read every number against (D-13 / STATE.md's carried
## defect): object build is already measured at ~54 ms mean / ~186 ms worst
## per sector, against a 33 ms per-frame budget at 30 Hz. This benchmark
## does not idle the streamer to get a flattering number -- the camera pans
## for the whole per-frame measurement window, so sectors keep streaming
## under real load exactly as D-13's own figures were taken.
const CROWD_MAX := 200              ## ponytail: T-05-44's stated ceiling -- no
	## retail capture has measured a real crowd size or formation; refuse
	## anything larger rather than let an operator-supplied N size an
	## unbounded spawn loop.
const CROWD_SPACING := 3.0          ## ponytail: synthetic grid spacing (world
	## cells) between adjacent rigs -- not a retail-measured crowd formation.
const CROWD_FRAMES := 90            ## measured frames, well past a 30-frame floor
const CROWD_PAN_STEP := Vector2(0.4, 0.25)  ## per measured frame, keeps sectors
	## streaming under load for the whole window instead of measuring an
	## idle, fully-settled scene.
const CROWD_CLIP := "GLAD_ATTACK_1H_A.GRN"  ## 05-14: the one clip
	## checkpoint-verified to bind BY NAME and play on this exact rig (05-12
	## Task 1, commit 5c3ddbc). Resolved through Models.clip_index_of (the
	## kind-scoped name lookup), never a hardcoded entry number; an
	## unresolved name degrades the run to animation=absent, labelled as
	## such on the crowd-scope line, never silently retried under another
	## name.


## Builds the streaming world exactly like the default branch above (camera +
## SectorView), spawns n PlayerView rigs in a grid around start_cell, starts
## CROWD_CLIP playing on each rig's ModelView through the same play_clip()
## call the --anim= route uses, measures build cost (clip bind included --
## that is what an animated rig costs to spawn) and per-frame cost
## separately while the camera pans, and prints exactly one `crowd` fact
## line plus an unconditional `crowd-scope` line naming what the
## measurement includes. Never asserts pass/fail -- this route measures, it
## does not gate.
func _run_crowd(install: String, world: Sacred.World, tex_pak: Sacred.Pak,
		tiles: Sacred.Tiles, statics: Sacred.Statics, mixed: Sacred.Mixed,
		items: Sacred.Items) -> void:
	if _crowd_n <= 0:
		printerr("crowd\trefused: --crowd=%s must be a positive integer" % _crowd_arg)
		get_tree().quit(1)
		return
	if _crowd_n > CROWD_MAX:
		printerr("crowd\trefused: --crowd=%d exceeds the stated ceiling of %d (T-05-44)" % [
			_crowd_n, CROWD_MAX])
		get_tree().quit(1)
		return

	var models_pak := Sacred.Pak.new(install.path_join("pak/models.pak"))
	if not models_pak.is_open():
		printerr("crowd\trefused: cannot open pak/models.pak under %s" % install)
		get_tree().quit(1)
		return
	var models := Sacred.Models.new(models_pak)
	var clip_idx := models.clip_index_of(CROWD_CLIP)

	_cam = IsoCamera.new()
	_cam.cell_limit = Vector2(world.size) * SECT
	add_child(_cam)
	_view = SectorView.new()
	_view.name = "SectorView"
	_view.setup(_cam, tex_pak, tiles, world, statics, mixed, items,
		{"interior": _sim.interior})
	_view.sector_built.connect(_draw_scripted_objects.bind(_view, install))
	add_child(_view)
	_cam.set_zoom_index(1)
	_cam.look_at_cell(start_cell)
	if not await _pump_until_settled():
		return

	# Grid centred on start_cell, CROWD_SPACING cells apart, so distinct rigs
	# occupy distinct cells rather than stacking on one point (which the
	# depth-sort would then have to fight over).
	var side := ceili(sqrt(float(_crowd_n)))
	var half := float(side - 1) * 0.5
	var rigs: Array[PlayerView] = []
	var build_times_ms: PackedFloat64Array = PackedFloat64Array()
	var verts := 0
	var tris := 0
	var rig_bones := 0
	var rig_tracks := 0
	var anim_rigs := 0
	var build_t0 := Time.get_ticks_usec()
	for i in _crowd_n:
		var gx := i % side
		var gy := i / side
		var cell := start_cell + Vector2(float(gx) - half, float(gy) - half) * CROWD_SPACING
		var t0 := Time.get_ticks_usec()
		var pv := PlayerView.new(models, _player_model, tex_pak,
			PackedStringArray(), items.texture_of(_player_type) if items != null else -1)
		if pv.node == null:
			build_times_ms.append((Time.get_ticks_usec() - t0) / 1000.0)
			continue
		add_child(pv.node)
		pv.update(cell)
		pv.configure_actor(_player_type, items, _shadow_creatures)
		if _view != null and _view._interior != null:
			var support_ref := _view._interior.initial_support_ref(Vector2i(cell), _player_type, 0)
			_update_native_actor(pv, cell, pv.initial_shadow_heading, support_ref)
		# 05-14: playback through the SAME ModelView.play_clip() main.gd's
		# --anim= route calls (05-12's landed reader-level path) -- no
		# benchmark-only animation path, and no new rig builder: the rig is
		# PlayerView's, parented into the tree so the tree frees it on
		# quit exactly like the single-player path. The clip's bind/decode
		# cost belongs to the per-rig build cost of an animated rig, so
		# this call sits inside the timed region.
		var mv := pv.node as ModelView
		if mv != null and clip_idx >= 0 and mv.play_clip(models, clip_idx):
			anim_rigs += 1
		build_times_ms.append((Time.get_ticks_usec() - t0) / 1000.0)
		verts = pv.vertex_count
		tris = pv.triangle_count
		rig_bones = mv.bone_count if mv != null else 0
		rig_tracks = mv.anim_tracks if mv != null else 0
		rigs.append(pv)
	var build_total_ms := (Time.get_ticks_usec() - build_t0) / 1000.0
	var build_mean_ms := 0.0
	for bt in build_times_ms:
		build_mean_ms += bt
	if build_times_ms.size() > 0:
		build_mean_ms /= build_times_ms.size()

	if rigs.is_empty():
		printerr("crowd\tn=%d\tno rig built -- %s failed to resolve or build" % [
			_crowd_n, _player_model])
		get_tree().quit(1)
		return

	if not await _pump_until_settled():
		return

	# Per-frame cost, measured while the camera pans -- process_frame, not
	# RenderingServer.frame_post_draw: under plain --headless there is no
	# draw pass, so frame_post_draw never fires and this loop would park
	# forever (same reasoning as _pump_until_settled above). Each rig whose
	# clip resolved has its AnimationPlayer ticking on these frames through
	# the engine's own playback (D-04) -- that per-frame animation cost is
	# exactly what this window is here to measure, on top of the streaming
	# load the pan keeps alive. PlayerView.update() still runs only once
	# per rig (static grid placement baked into the root-bone pose); D-06
	# keeps the clip's root-bone tracks out of the Animation, so playback
	# and placement never fight over the same bone.
	var frame_times_ms: PackedFloat64Array = PackedFloat64Array()
	var pan := start_cell
	var draw_calls := 0
	for _f in CROWD_FRAMES:
		var ft0 := Time.get_ticks_usec()
		pan += CROWD_PAN_STEP
		_cam.look_at_cell(pan)
		await get_tree().process_frame
		if not is_instance_valid(self):
			return
		frame_times_ms.append((Time.get_ticks_usec() - ft0) / 1000.0)
		draw_calls = RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)

	frame_times_ms.sort()
	var frame_mean_ms := 0.0
	for ft in frame_times_ms:
		frame_mean_ms += ft
	if frame_times_ms.size() > 0:
		frame_mean_ms /= frame_times_ms.size()
	var p95_idx := clampi(
		int(ceil(float(frame_times_ms.size()) * 0.95)) - 1, 0, frame_times_ms.size() - 1)
	var frame_p95_ms: float = frame_times_ms[p95_idx] if frame_times_ms.size() > 0 else 0.0
	var frame_worst_ms: float = (
		frame_times_ms[frame_times_ms.size() - 1] if frame_times_ms.size() > 0 else 0.0)

	print(("crowd\tn=%d\tframes=%d\tframe_mean_ms=%.6f\tframe_p95_ms=%.6f\t"
		+ "frame_worst_ms=%.6f\tbuild_mean_ms=%.6f\tbuild_total_ms=%.6f\t"
		+ "verts=%d\ttris=%d\tdrawcalls=%d\trigverts=%d\trigtris=%d\t"
		+ "rigbones=%d\trigtracks=%d") % [
		rigs.size(), frame_times_ms.size(), frame_mean_ms, frame_p95_ms, frame_worst_ms,
		build_mean_ms, build_total_ms, verts * rigs.size(), tris * rigs.size(), draw_calls,
		verts, tris, rig_bones, rig_tracks])
	if draw_calls == 0:
		print("crowd-note\tdrawcalls=0 -- plain --headless never submits a draw call "
			+ "(RenderingServer never presents a frame there); this reading is not a "
			+ "rendering-cost measurement, only frame_mean_ms/build_mean_ms are")
	# 05-14: unconditional, on EVERY run -- this line is what stops a number
	# being read as a fuller answer than it is. pieces=1: every crowd rig is
	# the single-mesh base rig; composition does not exist (05-11 halted).
	var anim_word := "present" if anim_rigs == rigs.size() else "absent"
	var scope_reason := ""
	if anim_word == "present":
		scope_reason = ("composition absent per the 05-11 write-up (no composed "
			+ "multi-piece rig exists anywhere in godot-port/; bind-agreement REFUTED "
			+ "twice, rows 605-607); animation present at the reader level only, via "
			+ "ModelView.play_clip (05-12 Task 1, commit 5c3ddbc) -- the PlayerView/"
			+ "live-game-world wiring does not exist per the 05-12 write-up (Task 3 did "
			+ "not run; rig-agreement REFUTED, row 609) -- this measures N single-mesh "
			+ "rigs each playing one named clip at the reader level while the world "
			+ "streams, excluding composition cost and any live-world animation "
			+ "wiring; it is not a full phase-5 crowd-budget number")
	else:
		scope_reason = ("composition absent per the 05-11 write-up; animation ALSO "
			+ "absent this run -- %s resolved to clip index %d and playback started "
			+ "on %d of %d rigs (expected all, via ModelView.play_clip, 05-12 Task 1) "
			+ "-- investigate before quoting any number from this run"
			% [CROWD_CLIP, clip_idx, anim_rigs, rigs.size()])
	print("crowd-scope\tcomposition=absent\tanimation=%s\tpieces=%d\tclip=%d\treason=%s" % [
		anim_word, 1, clip_idx if anim_word == "present" else -1, scope_reason])
	get_tree().quit()


## Scans mixed.pak source indices upward from 1 for the first record that
## resolves to REAL art (def() non-empty and tiles > 0) -- 15840 of 32096
## mixed.pak entries have zero tiles, so picking blindly would land on one
## roughly half the time. Falls back to record_id 0 (an out-of-range kind,
## always resolving to the shared empty def) if none is found, which should
## not happen against any real install.
func _first_real_record_id() -> int:
	var source := 1
	while source < _records.count():
		var id := RecordStore.make_id(RecordStore.KIND_STATIC_ART, source)
		var d := _records.def(id)
		if not d.is_empty() and int(d.get("tiles", 0)) > 0:
			return id
		source += 1
	push_error("_first_real_record_id: no mixed.pak entry with tiles > 0 found")
	return 0


## --actor-probe=N end-to-end demonstration: spawns a fixed, deterministic
## actor set, ticks it by exact count through the real Sim.advance, then
## walks a real streaming route that queue_free's and rebuilds sector 50,50
## -- printing facts that let the survival and route-independence checks in
## plan 01-01's acceptance criteria be asserted with plain grep/diff.
## "Exactly n ticks" holds at ANY --tickhz=: the loop below drives advance()
## with _sim.tick_dt() (the instance's own configured delta), not the class
## constant, so tick=n regardless of the tick rate in effect.
func _actor_probe(n: int, route: String) -> void:
	# Set before anything else, so no frame pumped below can inject a
	# wall-clock tick via _process's normal _advance_sim call.
	_probe_active = true

	# 1. Settle on the probe's home sector before spawning or ticking.
	_cam.set_zoom_index(1)
	_cam.look_at_cell(PROBE_FOCUS)
	if not await _pump_until_settled():
		return

	# 2. A fixed, deterministic actor set. Actor 1 is stationary and wounded
	# -- its hp is the survival witness, untouched by Sim._step_actor by
	# construction. Every probe actor carries a REAL record_id, resolved
	# through RecordStore (plan 02) -- never a bare placeholder index.
	#
	# Offsets (task 3, R10.3) are chosen so id1/id3/id4/id2 land at strictly
	# increasing d^2 (0, 4, 36, 64) while ids 5..16 form a twelve-actor ring
	# whose d^2 is EXACTLY 25 for every member -- small-integer offsets whose
	# squares sum to 25 exactly, so the primary sort key is exactly, not
	# approximately, tied. An approximate tie would not exercise
	# Array.sort_custom's heapsort instability (R10.3, order_by_distance).
	var rec_id := _first_real_record_id()
	var id1 := _registry.spawn(rec_id, PROBE_FOCUS, 7, 149)
	_registry.get_actor(id1).heading = Vector2.ZERO
	var id2 := _registry.spawn(rec_id, PROBE_FOCUS + Vector2(0.0, 8.0), 149, 149)
	_registry.get_actor(id2).heading = Vector2(1.0, 0.0)
	var id3 := _registry.spawn(rec_id, PROBE_FOCUS + Vector2(2.0, 0.0), 149, 149)
	_registry.get_actor(id3).heading = Vector2(0.0, 1.0)
	var id4 := _registry.spawn(rec_id, PROBE_FOCUS + Vector2(0.0, 6.0), 149, 149)
	_registry.get_actor(id4).heading = Vector2(1.0, 1.0).normalized()

	# ids 5..16: the tie ring, stationary (heading=ZERO) so it cannot drift
	# and the order printed below stays exact for the whole run, not just
	# before the first tick. Spawned in exactly this order -- the order line
	# asserts the ids came out in SPAWN order among themselves, which is what
	# distinguishes "comparator broke the tie by id" from "comparator left
	# heapsort's internal order showing through".
	var tie_ring: Array[Vector2] = [
		Vector2(5.0, 0.0), Vector2(-5.0, 0.0), Vector2(0.0, 5.0), Vector2(0.0, -5.0),
		Vector2(3.0, 4.0), Vector2(4.0, 3.0), Vector2(-3.0, 4.0), Vector2(-4.0, 3.0),
		Vector2(3.0, -4.0), Vector2(4.0, -3.0), Vector2(-3.0, -4.0), Vector2(-4.0, -3.0),
	]
	for offset: Vector2 in tie_ring:
		var tid := _registry.spawn(rec_id, PROBE_FOCUS + offset, 149, 149)
		_registry.get_actor(tid).heading = Vector2.ZERO

	# ids 17..19: the three-radius boundary set (task 4, R10.2/R10.4), all
	# stationary. 17 sits at EXACTLY R_SIM -- in_radius's <= means it must
	# still tick. 18 is one cell further out -- outside R_SIM, inside
	# R_RENDER, must NOT tick. 19 sits inside R_LOAD, outside R_RENDER.
	var id17 := _registry.spawn(rec_id, PROBE_FOCUS + Vector2(Sim.R_SIM, 0.0), 149, 149)
	_registry.get_actor(id17).heading = Vector2.ZERO
	var id18 := _registry.spawn(rec_id, PROBE_FOCUS + Vector2(Sim.R_SIM + 1.0, 0.0), 149, 149)
	_registry.get_actor(id18).heading = Vector2.ZERO
	var id19 := _registry.spawn(rec_id, PROBE_FOCUS + Vector2(150.0, 0.0), 149, 149)
	_registry.get_actor(id19).heading = Vector2.ZERO

	# record\t... -- before any tick runs. Placed immediately before the
	# order (task 3) and bands (task 4) lines that land in this same slot.
	var rd := _records.def(rec_id)
	print("record\tid=%d\tkind=%d\tsprite=%d\tname=%s\ttiles=%d\treadonly=%s\tshared=%s" % [
		rec_id, RecordStore.kind_of(rec_id), RecordStore.source_of(rec_id),
		rd.get("name", ""), rd.get("tiles", 0), rd.is_read_only(),
		is_same(_records.def(rec_id), _records.def(rec_id))])

	# order\t... -- order_by_distance's composite key (dist_sq, then id) over
	# the whole registry, printed BEFORE any tick has moved actors 2/3/4 off
	# their spawn offsets -- printing after even one tick would make the
	# assertion approximate rather than exact (R10.3).
	var order := _sim.order_by_distance(_registry, PROBE_FOCUS)
	var order_strs: Array[String] = []
	for id: int in order:
		order_strs.append(str(id))
	print("order\t%s" % ",".join(order_strs))

	# bands\t... -- in_radius(PROBE_FOCUS, r) counts at each of the three
	# radii, before any tick (task 4, R10.2/R10.4). With the layout above,
	# 17 is exactly the sim boundary (inclusive), 18 the render boundary,
	# 19 the load boundary, so each band's count equals the id of the actor
	# that boundary is named after.
	print("bands\tsim=%d\trender=%d\tload=%d" % [
		_registry.in_radius(PROBE_FOCUS, Sim.R_SIM).size(),
		_registry.in_radius(PROBE_FOCUS, Sim.R_RENDER).size(),
		_registry.in_radius(PROBE_FOCUS, Sim.R_LOAD).size()])

	# 3. Exactly n ticks, driven by count, through the one real accumulator --
	# never by frame-delta, which would make the tick count route-dependent.
	# Uses _sim.tick_dt(), the INSTANCE's own configured delta (honors
	# --tickhz=), not the class constant Sim.TICK_DT -- the latter is sized
	# for the 30 Hz default only, so feeding it in here would silently drift
	# the tick count away from n whenever --tickhz differs from 30.
	for _i in n:
		_advance_sim(_sim.tick_dt(), PROBE_FOCUS)

	# 4. Walk the streaming route far enough that sector 50,50 leaves the
	# wanted set and is queue_free'd, then re-enters it. No ticks run during
	# the walk -- _probe_active is still true.
	_view.probe_unloaded = 0
	_view.probe_reloaded = 0
	var route_a: Array[Vector2] = [
		Vector2(3232.0, 3232.0), Vector2(3232.0, 3600.0), Vector2(3232.0, 3232.0)]
	var route_b: Array[Vector2] = [
		Vector2(3232.0, 3232.0), Vector2(3600.0, 3232.0),
		Vector2(3600.0, 3600.0), Vector2(3232.0, 3232.0)]
	var waypoints: Array[Vector2] = route_a if route == "a" else route_b
	for wp: Vector2 in waypoints:
		_cam.look_at_cell(wp)
		if not await _pump_until_settled():
			return

	# 5. Print, in this exact order: every registry dump line, the sim
	# summary, then one probe-diag line carrying every route-varying fact.
	# Nothing route-varying appears on any other line, so the non-diag
	# stdout is byte-identical between routes.
	var lines: Array[String] = []
	_registry.dump(lines)
	for line: String in lines:
		print(line)
	print("sim\ttick=%d\tdropped=%d" % [_sim.tick, _sim.dropped])
	print("probe-diag\troute=%s\tunloaded=%d\treloaded=%d\twaypoints=%d" % [
		route, _view.probe_unloaded, _view.probe_reloaded, waypoints.size()])

	# 6. The probe writes no files -- stdout only, then exit.
	get_tree().quit()


## --grn=NAME renders one Granny model from pak/models.pak instead of the
## sector streamer, so a single command turns retail bytes into a picture.
## Builds no SectorView at all, which is what _await_settled's no-view guard
## below exists to accommodate.
##
## NAME is resolved through Models.index_of against the pak's own 64-byte
## name fields. It never reaches the filesystem: no path_join, no
## FileAccess.open, no use of the trimmed argument as a path. An unresolvable
## name is fatal and loud -- rendering nothing while exiting 0 is the failure
## mode that makes a broken capture look like a working one.
func _show_model(install: String, name: String, anim_name: String = "", anim_falsify: String = "",
		anim_key_report: String = "", anim_rigcheck: String = "", native_motion: int = -1) -> void:
	var pak := Sacred.Pak.new(install.path_join("pak/models.pak"))
	if not pak.is_open():
		printerr("grn\tcannot open pak/models.pak under %s" % install)
		get_tree().quit(1)
		return
	var models := Sacred.Models.new(pak)
	var idx := models.index_of(name)
	if idx < 0:
		printerr("grn\tno model named %s in pak/models.pak (%d entries)" % [name, models.count()])
		get_tree().quit(1)
		return
	var view := ModelView.new()
	view.name = "ModelView"
	if not view.setup(models, idx):
		printerr("grn\t%s (index %d) has no decodable mesh" % [models.entry_name(idx), idx])
		# Never add_child'd, so nothing else frees it. quit() masks this on the
		# CLI path, but this function is the one a corpus sweep would call in a
		# loop, and there the orphans would accumulate.
		view.free()
		get_tree().quit(1)
		return
	add_child(view)
	print("grn\tindex %d\tname %s\tverts %d\ttris %d\tbasis %s" % [
		idx, models.entry_name(idx), view.vertex_count, view.triangle_count,
		"located" if view.basis_located else "unlocated"])
	# binds < count is normal, not a defect: a bone nothing is weighted to gets
	# no bind-array slot. sanitised counts bones whose stored name could not be
	# used verbatim -- currently all of them, because this format's bone record
	# stores no name.
	print("bones\tcount=%d\troots=%d\tbinds=%d\tsanitised=%d" % [
		view.bone_count, view.bone_roots, view.bind_count, view.bone_sanitised])
	# No rest-equals-bind verdict is printed any more. The assertion behind it
	# was circular -- both operands composed the same stored local rests -- so
	# it reported true unconditionally, including on a render a human rejected.
	# It is removed rather than replaced: the skeleton and skin layer is
	# unvalidated until an oracle independent of our own decode exists.
	if anim_key_report != "":
		_anim_key_report(models, anim_key_report)
	if anim_rigcheck != "":
		if not _anim_rigcheck(models, idx, anim_rigcheck):
			get_tree().quit(1)
			return
	if anim_name != "" or native_motion >= 0:
		var anim_idx := models.native_motion_entry(idx, native_motion) if native_motion >= 0 \
			else models.clip_index_of(anim_name)
		if native_motion >= 0:
			if anim_idx < 0:
				printerr("motion\tmodel %s has no motion enum %d in this archive" % [name, native_motion])
				get_tree().quit(1)
				return
			print("motion\tmodel=%s\tenum=%d\tclip=%d\tname=%s" % [
				name, native_motion, anim_idx, models.entry_name(anim_idx)])
		if anim_idx < 0:
			printerr("anim\tno motion-kind entry named %s in pak/models.pak (%d entries)" % [anim_name, models.count()])
			get_tree().quit(1)
			return
		if not view.play_clip(models, anim_idx, anim_falsify):
			printerr("anim\t%s (index %d) bound no animation tracks to %s (index %d)" % [
				models.entry_name(anim_idx), anim_idx, models.entry_name(idx), idx])
			get_tree().quit(1)
			return
		var total := view.anim_bound + view.anim_unbound_names.size()
		print("anim\tclip=%d\tname=%s\tmodel=%d\ttracks=%d\tbound=%d/%d\tlength=%.6f\tloop=%s" % [
			anim_idx, models.entry_name(anim_idx), idx, view.anim_tracks,
			view.anim_bound, total, view.anim_length, "linear"])
		if not view.anim_unbound_names.is_empty():
			print("anim-unbound\tclip=%d\tnames=%s" % [anim_idx, ",".join(view.anim_unbound_names)])
		if anim_falsify != "":
			# 05-12 Task 2 counterfactual proof: sample a fixed bone at a fixed
			# advance time under the broken join and print it verbatim. A
			# correct run's --anim= (no --anim-falsify=) sampled the same bone
			# at the same time earlier in this task's verification -- the two
			# outputs are compared by the human/task record, not by this
			# process, since each is a separate headless invocation.
			var probe_bone := "Bip01"
			var t := view.anim_length * 0.5
			view.seek_anim(t)
			var pose := view.sample_bone_pose(probe_bone)
			print("anim-falsify\tmode=%s\tbone=%s\tt=%.6f\torigin=%s\tbasis=%s" % [
				anim_falsify, probe_bone, t, pose.origin, pose.basis])
	await _maybe_screenshot()


## 05-12 Task 2: settles, in GDScript, which within-file mapping (directory
## position, id-1, id) a clip record's bone actually is -- re-derived here
## rather than cited from planning, against the bone's own stored local rest
## translation (Sacred.Models.clip_bones()), a quantity decoded by different
## code from a different structure than the record's own first translation
## keyframe -- not the circular comparison findings row 496 refuted. Prints
## one `animkey` line per rival mapping, then a corpus census line over every
## kind=65 clip in the pak. Adds no tolerance constant to sacred.gd; the
## verdict is the raw SEPARATION between mappings' means.
func _anim_key_report(models: Sacred.Models, name: String) -> void:
	var clip_idx := models.clip_index_of(name)
	if clip_idx < 0:
		printerr("animkey\tno motion-kind entry named %s in pak/models.pak (%d entries)" % [name, models.count()])
		return
	var c := models.clip(clip_idx)
	var bones := models.clip_bones(clip_idx)
	if c.is_empty() or bones.is_empty():
		printerr("animkey\tentry %d has no decodable clip/bone data" % clip_idx)
		return
	var records: Array = c["records"]
	var n_bones := bones.size()
	for mapping in ["dirpos", "id-1", "id"]:
		var sum := 0.0
		var mx := 0.0
		var n := 0
		for ri in records.size():
			var r: Dictionary = records[ri]
			var positions: PackedVector3Array = r["positions"]
			if positions.is_empty():
				continue
			var bi := -1
			match mapping:
				"dirpos": bi = ri
				"id-1": bi = int(r["id"]) - 1
				"id": bi = int(r["id"])
			if bi < 0 or bi >= n_bones:
				continue
			var rest: Vector3 = bones[bi]["position"]
			var d := positions[0].distance_to(rest)
			sum += d
			mx = maxf(mx, d)
			n += 1
		var mean := (sum / n) if n > 0 else 0.0
		print("animkey\tclip=%d\tmapping=%s\tmean=%.6f\tmax=%.6f\tn=%d" % [clip_idx, mapping, mean, mx, n])

	# Corpus census over every kind=65 entry that IS a clip (is_animation()
	# discriminates a clip from a motion-model such as GLADIATOR.GRN's own
	# entry 2845, which carries no per-bone track records at all).
	var decodable := 0
	var undecodable := 0
	var perm1 := 0
	var perm0 := 0
	var other := 0
	var countmismatch := 0
	var other_names := PackedStringArray()
	for i in models.count():
		if models.kind_of(i) != Sacred.Models.KIND_MOTION or not models.is_animation(i):
			continue
		var cc := models.clip(i)
		var bb := models.clip_bones(i)
		if cc.is_empty() or bb.is_empty():
			undecodable += 1
			continue
		decodable += 1
		var recs: Array = cc["records"]
		var nb := bb.size()
		if recs.size() != nb:
			countmismatch += 1
		var ids := PackedInt32Array()
		for r2 in recs:
			ids.append(int(r2["id"]))
		if _is_permutation(ids, 1, nb):
			perm1 += 1
		elif _is_permutation(ids, 0, nb):
			perm0 += 1
		else:
			other += 1
			other_names.append(models.entry_name(i))
	print("animkey\tcorpus=kind65\tdecodable=%d\tperm1=%d\tperm0=%d\tother=%d\tcountmismatch=%d" % [
		decodable, perm1, perm0, other, countmismatch])
	# Not part of the plan's fixed corpus-line format, printed as an honest
	# extra fact: entries clip() itself refuses outright (a decode-level
	# failure, before an id-pattern classification is even possible) are
	# NEITHER decodable nor classifiable as perm1/perm0/other under this
	# census. See the findings row and the 05-12 write-up for which entries
	# these are and why -- Task 1 already surfaced the same refusal on this
	# corpus's two named exceptions.
	if undecodable > 0:
		print("animkey\tcorpus=kind65\tundecodable=%d" % undecodable)
	if not other_names.is_empty():
		print("animkey\tcorpus=kind65\tother_names=%s" % ",".join(other_names))


## True iff every value of `ids` falls in `base..base+n-1` and each value in
## that range appears EXACTLY once -- an exact permutation, not merely a
## count match. `ids.size() != n` is an immediate false (a record/bone count
## mismatch is a different finding, counted separately as `countmismatch`).
func _is_permutation(ids: PackedInt32Array, base: int, n: int) -> bool:
	if ids.size() != n or n <= 0:
		return false
	var seen := PackedByteArray()
	seen.resize(n)
	for v in ids:
		var i := v - base
		if i < 0 or i >= n or seen[i] != 0:
			return false
		seen[i] = 1
	return true


## Composes world-space bind transforms parent-first from a stored local bone
## chain, in the SAME shape and with the SAME cycle-safety step budget
## Sacred.Models.bind_poses() already implements for kind=64 model entries.
## bind_poses() itself is hardcoded to bones() (kind=64 only, by its own doc
## comment's design), so this is the IDENTICAL algorithm applied here to
## clip_bones()'s kind=65 shape, which returns the same per-bone Dictionary
## (parent_effective, rest). Duplicated rather than added to sacred.gd
## because Task 2's own file list does not include sacred.gd -- bind_poses()
## itself already forbids a rival spelling of an EXISTING rule, and this is
## a NEW one, generic over either bone-list shape, that belongs in the file
## that consumes it.
func _compose_world(bl: Array[Dictionary]) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	if bl.is_empty():
		return out
	var n := bl.size()
	var world: Array[Transform3D] = []
	var done := PackedByteArray()
	world.resize(n)
	done.resize(n)
	for i in n:
		if done[i] != 0:
			continue
		var chain: Array[int] = []
		var c := i
		var steps := 0
		while done[c] == 0:
			if steps > n:
				push_error("main._compose_world: bone %d sits on a parent cycle" % i)
				return []
			chain.append(c)
			var p: int = bl[c]["parent_effective"]
			if p == -1:
				break
			if chain.has(p):
				push_error("main._compose_world: bone %d sits on a parent cycle" % i)
				return []
			c = p
			steps += 1
		chain.reverse()
		for b in chain:
			var p2: int = bl[b]["parent_effective"]
			if p2 == -1:
				world[b] = bl[b]["rest"]
			else:
				world[b] = world[p2] * bl[b]["rest"]
			done[b] = 1
	for i in n:
		out.append(world[i])
	return out


## The wrong-character control arm (planning_measurements section 4):
## BATX_ATTACK_BH_A.GRN matches 26 bone names by generic 3ds Max Biped
## naming, so a check that only counted matches would not discriminate --
## what must discriminate is whether the matched bones AGREE in world bind
## transform. 0.01 is the same tight discriminator planning's own probe used
## on this corpus; it is not tuned here to pass, it is the value stated
## before this task ran.
const ANIM_RIGCHECK_CONTROL := "BATX_ATTACK_BH_A.GRN"
const ANIM_RIGCHECK_WITHIN := 0.01
## The real skeleton root of the Biped rig, below the file-structural __Root
## and below model 589's extra alignment bone. Anchoring here is the whole of
## what --anim-riganchor= changes.
const ANIM_ANCHOR := "Bip01"
var _anim_rig_anchor := ""

## One rig-agreement measurement, matching bones by exact NAME only (never
## index, never parent_effective shape, never the record's dword id) between
## `clip_idx`'s composed world bind transforms and `model_idx`'s. Empty
## Dictionary on an undecodable side.
func _anchor_label() -> String:
	return _anim_rig_anchor if _anim_rig_anchor != "" else "file-root"


func _rigcheck_one(models: Sacred.Models, model_idx: int, clip_idx: int) -> Dictionary:
	var model_bones := models.bones(model_idx)
	var model_world := models.bind_poses(model_idx)
	if model_bones.is_empty() or model_world.is_empty():
		printerr("animrig\tmodel entry %d has no decodable bones" % model_idx)
		return {}
	var model_by_name := {}
	for i in model_bones.size():
		var nm: String = (model_bones[i]["name"] as PackedByteArray).get_string_from_utf8()
		if nm != "" and not model_by_name.has(nm):
			model_by_name[nm] = model_world[i]

	var clip_names := models.clip_bone_names(clip_idx)
	var clip_bones := models.clip_bones(clip_idx)
	var clip_world := _compose_world(clip_bones)
	if clip_names.is_empty() or clip_world.is_empty():
		printerr("animrig\tclip entry %d has no decodable bones" % clip_idx)
		return {}

	# Re-anchor BOTH sides at their own copy of _anim_rig_anchor, so the chain
	# above it -- the only place the two files are known to differ structurally
	# -- stops contributing. A side missing the anchor is a hard failure, not a
	# silent fall back to file-root anchoring: that would report an anchored
	# verdict for an unanchored measurement.
	var clip_index_by_name := {}
	for i in clip_names.size():
		if clip_names[i] != "" and not clip_index_by_name.has(clip_names[i]):
			clip_index_by_name[clip_names[i]] = i
	if _anim_rig_anchor != "":
		if not model_by_name.has(_anim_rig_anchor) or not clip_index_by_name.has(_anim_rig_anchor):
			printerr("animrig\tanchor %s is missing from model %d or clip %d" % [
				_anim_rig_anchor, model_idx, clip_idx])
			return {}
		var minv: Transform3D = (model_by_name[_anim_rig_anchor] as Transform3D).affine_inverse()
		for nm2: String in model_by_name:
			model_by_name[nm2] = minv * (model_by_name[nm2] as Transform3D)
		var cinv := clip_world[clip_index_by_name[_anim_rig_anchor]].affine_inverse()
		for i in clip_world.size():
			clip_world[i] = cinv * clip_world[i]

	var matched := 0
	var maxorigin := 0.0
	var maxbasis := 0.0
	var within := 0
	var worstbone := ""
	for i in clip_names.size():
		var nm: String = clip_names[i]
		if nm == "" or not model_by_name.has(nm):
			continue
		matched += 1
		var a: Transform3D = clip_world[i]
		var b: Transform3D = model_by_name[nm]
		var od := a.origin.distance_to(b.origin)
		var bd := 0.0
		for axis in 3:
			bd = maxf(bd, (a.basis[axis] - b.basis[axis]).length())
		if od > maxorigin:
			maxorigin = od
			worstbone = nm
		maxbasis = maxf(maxbasis, bd)
		if od <= ANIM_RIGCHECK_WITHIN:
			within += 1
	# TEST 2 (topology) and TEST 3 (local rest), both pre-specified before this
	# ran. They ask a different question from the bind-pose agreement above: a
	# clip's stored rest need NOT equal the mesh's bind pose for the clip to be
	# correct for that rig, but its bone TOPOLOGY must match, and a local-only
	# comparison separates "wrong chain" from "genuinely different pose".
	var model_parent_name := {}
	for i in model_bones.size():
		var nm3: String = (model_bones[i]["name"] as PackedByteArray).get_string_from_utf8()
		var pe: int = model_bones[i]["parent_effective"]
		var pn := ""
		if pe >= 0 and pe < model_bones.size():
			pn = (model_bones[pe]["name"] as PackedByteArray).get_string_from_utf8()
		if nm3 != "" and not model_parent_name.has(nm3):
			model_parent_name[nm3] = pn
	var model_local := {}
	for i in model_bones.size():
		var nm4: String = (model_bones[i]["name"] as PackedByteArray).get_string_from_utf8()
		if nm4 != "" and not model_local.has(nm4):
			model_local[nm4] = model_bones[i]["rest"]
	var topo_ok := 0
	var topo_n := 0
	var local_within := 0
	var local_max := 0.0
	for i in clip_names.size():
		var nm5: String = clip_names[i]
		if nm5 == "" or not model_parent_name.has(nm5):
			continue
		topo_n += 1
		var cpe: int = clip_bones[i]["parent_effective"]
		var cpn := ""
		if cpe >= 0 and cpe < clip_names.size():
			cpn = clip_names[cpe]
		if cpn == model_parent_name[nm5]:
			topo_ok += 1
		var la: Transform3D = clip_bones[i]["rest"]
		var lb: Transform3D = model_local[nm5]
		var ld := la.origin.distance_to(lb.origin)
		local_max = maxf(local_max, ld)
		if ld <= ANIM_RIGCHECK_WITHIN:
			local_within += 1
	return {
		"matched": matched, "total": clip_names.size(), "unmatched": clip_names.size() - matched,
		"maxorigin": maxorigin, "maxbasis": maxbasis, "within": within, "worstbone": worstbone,
		"topo_ok": topo_ok, "topo_n": topo_n, "local_within": local_within, "local_max": local_max,
	}


## 05-12 Task 2 halt: whether a clip's skeleton and the model's skeleton are
## the same rig, measured by name, with the wrong-character control run
## alongside it in the SAME invocation whenever `clip_name` is not itself the
## control. Prints one `animrig` line for `clip_name` and, unless it IS the
## control, a second `animrig` line for the control -- so "two animrig lines
## exist" is true of a single `--anim-rigcheck=` run naming the real clip.
## Discriminates by AGREEMENT (maxorigin, within), never by match count --
## the control MATCHES 26 names and must still be told apart by disagreeing.
## Returns false (having printed `verdict=REFUTED`) when it does not
## separate; the caller must not proceed to Task 3 in that case. Adds no
## epsilon or tolerance constant to sacred.gd.
func _anim_rigcheck(models: Sacred.Models, model_idx: int, clip_name: String) -> bool:
	var clip_idx := models.clip_index_of(clip_name)
	if clip_idx < 0:
		printerr("animrig\tno motion-kind entry named %s in pak/models.pak (%d entries)" % [clip_name, models.count()])
		return false
	var r := _rigcheck_one(models, model_idx, clip_idx)
	if r.is_empty():
		return false
	print("animrig\tanchor=%s\tclip=%d\tmodel=%d\tmatched=%d/%d\tunmatched=%d\tmaxorigin=%.6f\tmaxbasis=%.6f\twithin=%d\tworstbone=%s\ttopo=%d/%d\tlocalwithin=%d\tlocalmax=%.6f" % [
		_anchor_label(), clip_idx, model_idx, r.matched, r.total, r.unmatched, r.maxorigin, r.maxbasis, r.within, r.worstbone, r.topo_ok, r.topo_n, r.local_within, r.local_max])

	var control_idx := models.clip_index_of(ANIM_RIGCHECK_CONTROL)
	if control_idx < 0 or control_idx == clip_idx:
		return true
	var cr := _rigcheck_one(models, model_idx, control_idx)
	if cr.is_empty():
		printerr("animrig\tcontrol entry %s unavailable for comparison" % ANIM_RIGCHECK_CONTROL)
		return true
	print("animrig\tanchor=%s\tclip=%d\tmodel=%d\tmatched=%d/%d\tunmatched=%d\tmaxorigin=%.6f\tmaxbasis=%.6f\twithin=%d\tworstbone=%s\ttopo=%d/%d\tlocalwithin=%d\tlocalmax=%.6f\tcontrol=true" % [
		_anchor_label(), control_idx, model_idx, cr.matched, cr.total, cr.unmatched, cr.maxorigin, cr.maxbasis, cr.within, cr.worstbone, cr.topo_ok, cr.topo_n, cr.local_within, cr.local_max])

	# TEST 2's own verdict, stated before running and independent of the
	# bind-pose verdict below: CONFIRMED iff the clip's parent-name agreement
	# beats the control's AND clears 0.9.
	var topo_clip := float(r.topo_ok) / maxf(1.0, float(r.topo_n))
	var topo_ctrl := float(cr.topo_ok) / maxf(1.0, float(cr.topo_n))
	if topo_clip > topo_ctrl and topo_clip >= 0.9:
		print("animrig\ttopology_verdict=CONFIRMED\tclip=%.4f\tcontrol=%.4f" % [topo_clip, topo_ctrl])
	else:
		print("animrig\ttopology_verdict=REFUTED\tclip=%.4f\tcontrol=%.4f" % [topo_clip, topo_ctrl])

	var clip_agreement := float(r.within) / maxf(1.0, float(r.total))
	var control_agreement := float(cr.within) / maxf(1.0, float(cr.total))
	if r.maxorigin >= cr.maxorigin or clip_agreement <= control_agreement:
		print("animrig\tverdict=REFUTED\treason=control-agrees-as-well-as-clip")
		return false
	var ratio: float = (cr.maxorigin / r.maxorigin) if r.maxorigin > 0.0 else INF
	print("animrig\tverdict=CONFIRMED\tseparation_ratio=%.6f" % ratio)
	return true


## --clip=NAME decodes one animation clip from pak/models.pak, mirroring
## _show_model()'s resolve-then-fail-loud shape: an unresolvable name is fatal
## and loud, because exiting 0 having decoded nothing is the failure mode that
## makes a broken run look like a working one.
##
## NAME is resolved through Models.clip_index_of, kind-scoped so the
## GLADIATOR.GRN name collision (589 mesh, 2845 motion-but-not-clip) cannot
## silently resolve to the wrong entry. Renders nothing and builds no view --
## a reader-level probe only -- so it quits itself explicitly rather than
## relying on _maybe_screenshot's settle-and-quit path, which only fires when
## --shot=/--drawcalls is also given.
func _show_clip(install: String, name: String, desync: int = 0) -> void:
	var pak := Sacred.Pak.new(install.path_join("pak/models.pak"))
	if not pak.is_open():
		printerr("clip\tcannot open pak/models.pak under %s" % install)
		get_tree().quit(1)
		return
	var models := Sacred.Models.new(pak)
	var idx := models.clip_index_of(name)
	if idx < 0:
		printerr("clip\tno motion-kind entry named %s in pak/models.pak (%d entries)" % [name, models.count()])
		get_tree().quit(1)
		return
	var decoded := models.clip(idx, desync)
	if decoded.is_empty():
		printerr("clip\t%s (index %d) carries no decodable per-bone animation records" % [models.entry_name(idx), idx])
		get_tree().quit(1)
		return
	var records: Array = decoded["records"]
	var keys := 0
	for r in records:
		keys += r["times_pos"].size() + r["times_rot"].size() + r["times_other"].size()
	var suffix := "\tfalsify=%d" % desync if desync != 0 else ""
	print("clip\tindex %d\tname %s\tbones %d\trecords %d\tlength %.6f\tkeys %d%s" % [
		idx, models.entry_name(idx), int(decoded["bones"]), records.size(), float(decoded["length"]), keys, suffix])
	get_tree().quit()


## Waits for the streamer to settle, so a measurement/screenshot reflects a
## finished view rather than whatever one frame of loading happened to
## produce. Shared by every --shot=/--drawcalls consumer below -- a second,
## differently-timed wait is the mistake this factoring exists to prevent.
## Returns false if this node was freed while the coroutine was parked on an
## await (the caller must not touch `self`/`_view` after that), true
## otherwise.
func _await_settled() -> bool:
	# --grn= builds no SectorView, so there is nothing to poll; two presented
	# frames are enough for the capture. The streaming path below is reached
	# unchanged whenever a view exists, so its behaviour and timing are
	# untouched by this guard.
	if _view == null:
		await RenderingServer.frame_post_draw
		if not is_instance_valid(self):
			return false
		await RenderingServer.frame_post_draw
		return is_instance_valid(self)
	if not await _pump_until_settled():
		return false
	# The staged command root is complete; wait for its presented image too.
	await RenderingServer.frame_post_draw
	return is_instance_valid(self)


## --shot=FILE renders one frame, writes it, and exits. --drawcalls prints the
## per-frame RenderingServer draw-call count, read only after the same
## settle-await --shot= uses, so the value is guaranteed populated (plain
## --headless never submits a draw call and always reads 0 here). Either or
## both flags may be present in one invocation -- both share _await_settled()
## and the process quits once, after whichever branches ran. Neither flag
## present -> return immediately, preserving streaming mode's existing
## behaviour (never quits).
func _maybe_screenshot() -> void:
	var argv := OS.get_cmdline_user_args() + OS.get_cmdline_args()
	var want_drawcalls := "--drawcalls" in argv
	var shot_path := ""
	for arg in argv:
		if arg.begins_with("--shot="):
			shot_path = arg.trim_prefix("--shot=")
			break
	if not want_drawcalls and shot_path == "":
		return
	if not await _await_settled():
		return
	# --shot-delay=SECONDS holds the settled scene for a while before capturing,
	# so two runs at different delays differ only by whatever MOVED between
	# them. Without it every capture lands on the same settled frame and an
	# animation is indistinguishable from a static pose.
	var delay := 0.0
	for arg2 in argv:
		if arg2.begins_with("--shot-delay="):
			delay = clampf(float(arg2.trim_prefix("--shot-delay=")), 0.0, 30.0)
	if delay > 0.0:
		await get_tree().create_timer(delay).timeout
		if not is_instance_valid(self):
			return
	if want_drawcalls:
		var draw_calls := RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
		print("drawcalls\t%d" % draw_calls)
	if shot_path != "":
		var err := get_viewport().get_texture().get_image().save_png(shot_path)
		print("shot\t%s\t%s" % [shot_path, error_string(err)])
	get_tree().quit()


## --spawns support: sector -> tier, where the tier is what the sector's own
## opcode-51 rolls would put on the map.
##
##   1  wildlife only            green
##   2  a hostile roll, but nothing in it the hero fights   amber
##   3  a hostile roll the hero fights                      red
##
## A sector with spawn records but no rolls at all (only the group and
## per-sector opcodes) is left out, so "no tint" means "nothing rolls here".
## The join is the one from spawn_factions_check.gd: Funk says what a sector
## rolls, Creatures turns each id into a class, Factions says whether the hero
## fights that class.
func _spawn_tiers(install: String) -> Dictionary:
	const HELD := 1
	var funk := Sacred.Funk.new(install.path_join("bin/type_npc_seraphim"))
	var creatures := Sacred.Creatures.new(install.path_join("pak"))
	var factions := Sacred.Factions.new(install)
	var out: Dictionary[Vector2i, int] = {}
	for s: Vector2i in funk.by_sector:
		var tier := 0
		for roll in funk.rolls_for(s.x, s.y):
			if roll["kind"] == Sacred.Funk.WILDLIFE:
				tier = maxi(tier, 1)
				continue
			tier = maxi(tier, 2)
			for e: Vector3i in roll["entries"]:
				if factions.hostile(HELD, creatures.class_of(e.x)):
					tier = 3
					break
		if tier > 0:
			out[s] = tier
	print("spawns\tsectors=%d\tmatrix=%s" % [out.size(), factions.source])
	return out


## --creatures: draws what the spawn tables say lives in the player's own
## sector, animated. Every step is an existing decoded reader, joined:
##
##   Sacred.Funk       which creatures this sector rolls, and how often
##   Sacred.Items      creature id -> its Granny mesh name (row 693: the id IS
##                     the model, via the items.pak record's +0x37 name)
##   Sacred.Rigs       mesh -> the clip whose bones agree with it
##   PlayerView        build, scale, place and depth-sort the rig
##   ModelView         play the clip
##
## The roll is honoured rather than flattened: a creature is drawn once per
## weighted entry it wins, so a sector whose table is 70% wolf shows mostly
## wolves. Placement is a deterministic scatter inside the sector, NOT retail
## placement -- retail rolls spawn points at runtime from data this port does
## not read yet, so a fixed seed is the honest stand-in and the ceiling is
## named here rather than implied by the picture.
## ponytail: no wandering, no AI, no despawn -- they stand and animate. Add
## movement when the sim owns creature actors, which it does not yet.
const CREATURE_SEED := 20260814
const CREATURE_MAX := 24
const CREATURE_SPREAD := 4.0


func _build_creatures(install: String, models: Sacred.Models, player_cell: Vector2) -> void:
	var tex_pak := Sacred.Pak.new(install.path_join("pak/texture.pak"))
	var funk := Sacred.Funk.new(install.path_join("bin/type_npc_seraphim"))
	var items := Sacred.Items.new(Sacred.Pak.new(install.path_join("pak/items.pak")))
	var gx := int(player_cell.x) / SECT
	var gy := int(player_cell.y) / SECT
	# --creatures-only=PREFIX keeps only the rolled creatures whose mesh name
	# starts with PREFIX, and spawns that mesh even where the sector rolls
	# nothing at all. WHY IT EXISTS (row 765): the residual streak is a per-MESH
	# question, and a sector roll is a lottery -- a capture pair that does not
	# reliably contain the suspect cannot answer it. The rig, placement, clip
	# choice and seeding are otherwise untouched, so --creatures-only composes
	# with --creatures-noanim to give a one-variable pair on a chosen creature.
	# Parsed BEFORE the empty-sector return on purpose: the flag names a mesh to
	# draw, and a town sector must not silently answer "nothing here".
	var only := ""
	var forced_yaw := false
	var yaw_forced := 0.0
	for a in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if a.begins_with("--creatures-only="):
			only = a.substr("--creatures-only=".length()).to_upper()
		elif a.begins_with("--creature-yaw="):
			forced_yaw = true
			yaw_forced = float(a.substr("--creature-yaw=".length()))
	var rolls := funk.rolls_for(gx, gy)
	if rolls.is_empty() and only == "":
		print("creatures\tsector=%d,%d\trolls=0\t(a town or interior sector spawns nothing)" % [gx, gy])
		return

	var rng := RandomNumberGenerator.new()
	rng.seed = CREATURE_SEED
	# Resolve the meshes first, so Rigs decodes the clip corpus ONCE for all of
	# them (its whole cost is that pass; asking per creature would pay it N
	# times on a cold cache).
	var picks: Array[Dictionary] = []
	var wanted := PackedInt32Array()
	for roll in rolls:
		if picks.size() >= CREATURE_MAX:
			break
		var id := funk.pick(roll, rng)
		var nm := items.name_of(id)
		if nm == "":
			continue
		if only != "" and not nm.to_upper().begins_with(only):
			continue
		var mi := models.index_of(nm)
		if mi < 0:
			continue
		picks.append({"id": id, "name": nm, "mesh": mi, "kind": roll["kind"]})
		if not wanted.has(mi):
			wanted.append(mi)
	if only != "" and picks.is_empty():
		# Diagnostic spawn still needs a real definition: model-only type -1
		# bypassed support admission and rendered outside the shared compositor.
		# Select the first matching creature definition, and print that choice.
		for type_id in _shadow_creatures.ids():
			var nm := items.name_of(type_id)
			if not nm.to_upper().begins_with(only):
				continue
			var mi := models.index_of(nm)
			if mi < 0:
				continue
			picks.append({"id": type_id, "name": nm, "mesh": mi, "kind": 0})
			wanted.append(mi)
			print("creatures\tforced_type=%d\tmodel=%s" % [type_id, nm])
			break
	if picks.is_empty():
		print("creatures\tsector=%d,%d\trolls=%d\tresolved=0" % [gx, gy, rolls.size()])
		return

	var t0 := Time.get_ticks_msec()
	var rigs := Sacred.Rigs.new(models, wanted)
	var rig_ms := Time.get_ticks_msec() - t0

	var built := 0
	var animated := 0
	var kinds := {}
	for pick in picks:
		var pv := PlayerView.new(models, pick["name"], tex_pak,
			PackedStringArray(), items.texture_of(int(pick["id"])))
		if pv.node == null:
			continue
		add_child(pv.node)
		# Scatter around the player, deterministic under CREATURE_SEED.
		var cell := player_cell + Vector2(
			rng.randf_range(-CREATURE_SPREAD, CREATURE_SPREAD),
			rng.randf_range(-CREATURE_SPREAD, CREATURE_SPREAD))
		pv.update(cell)
		# Initial heading comes from the definition. The diagnostic override
		# uses the same native angle conversion, never a second root-bone yaw.
		if int(pick["id"]) > 0:
			pv.configure_actor(int(pick["id"]), items, _shadow_creatures)
			var heading := PlayerView.NativeActorShadow.heading_from_degrees(yaw_forced) \
				if forced_yaw else pv.initial_shadow_heading
			_update_native_actor(pv, cell, heading,
				_sim.interior.initial_support_ref(Vector2i(cell), pv.actor_type, 0))
		_creature_views.append(pv)
		_creature_cells.append(cell)
		built += 1
		# --creatures-noanim builds the identical rig and SKIPS play_clip, so a
		# capture pair differs in exactly one variable: whether an animation is
		# driving the skeleton PlayerView also poses for placement (row 757's
		# open suspect).
		# rest_clip(), NOT clip_for(). clip_for is the best GEOMETRIC score and
		# for a standing character that is routinely wrong: it gives NOVIZIN02 a
		# WALK, THIEF2_MAL another character's WALK, and the Seraphim herself
		# SERA_SPECIAL_MULTI_2WAFFEN -- a two-weapon special attack. rest_clip
		# prefers IDLE, then FIDLE, then WALK, and falls back to clip_for, which
		# is why view/player_view.gd has used it for the hero all along. These
		# builders did not, and that was the whole of the "wrong pose" defect.
		var ci: int = -1 if "--creatures-noanim" in OS.get_cmdline_user_args() + OS.get_cmdline_args() \
			else rigs.rest_clip(pick["mesh"])
		var mv := pv.node as ModelView
		if mv != null and ci >= 0 and mv.play_clip(models, ci):
			animated += 1
			# Desynchronise the loops, or every wolf in the sector breathes in
			# lockstep -- which reads as one animation on many meshes.
			mv.seek_anim(rng.randf() * maxf(0.001, mv.anim_length))
		kinds[pick["name"]] = int(kinds.get(pick["name"], 0)) + 1
	print("creatures\tsector=%d,%d\trolls=%d\tbuilt=%d\tanimated=%d\tmeshes=%d\trigs=%d ms" % [
		gx, gy, rolls.size(), built, animated, wanted.size(), rig_ms])
	var listed := PackedStringArray()
	for k: String in kinds:
		listed.append("%s x%d" % [k, kinds[k]])
	print("creatures\t%s" % ", ".join(listed))


## --npcs: the world's FIXED cast, drawn where retail puts it.
##
## The difference from --creatures is PLACEMENT, and it is the whole point.
## --creatures scatters rolled creatures around the player under a fixed seed
## because retail rolls spawn POINTS at runtime and this port cannot reproduce
## that yet. startcode.bin needs no such stand-in: every opcode-1 record
## carries its own literal cell, or the name of an opcode-23 position declared
## in the same file, and placement there is CLOSED -- 18,586 of 18,586 across
## the eight classes (autoresearch row 832). So these NPCs stand exactly where
## the retail script puts them, and a disagreement with the running game is a
## bug rather than an expected difference.
##
## The join, every step an already-decoded reader (rows 831-833, 837):
##   Sacred.Startcode  which NPCs exist, their body/hand item ids, their cells
##   Sacred.Items      items.pak record -> its Granny mesh name
##   Sacred.Rigs       mesh -> the clip whose bones agree with it
##   PlayerView        build, scale, place and depth-sort the rig
##
## BODIES AND HANDS since 2026-08-15. The two questions this comment used to
## park -- does a weapon share the body's skeleton, and which bone would it hang
## from otherwise -- are both measured now, and the first answer is no:
##
##   A WEAPON IS A RIGID PROP. It carries 3..16 bones of its own and shares only
##   __Root and the socket names with a body, and 199 of the 221 entries with a
##   weapon-side grip declare no vertex weights at all. Re-using equip_check's
##   armour instrument on hands returned own == cross == 1.0000 -- the control
##   scoring as well as the subject, i.e. the instrument measuring nothing.
##
##   THE SOCKET IS NAMED ON BOTH SIDES. Bone_weapon_01/_02 appear on wearers as
##   children of Bip01 R/L Hand (235/192 entries) and on weapons as children of
##   __Root (206/176), with zero crossings. Docking is aligning one to the other.
##
## checks/compose_check.gd holds the census, the control that decides which
## socket is which hand, and the geometric test that the dock moves the mesh.
## ARMOUR is still bodies-only: nothing read so far says which armour pieces an
## NPC wears, and --equip's demonstration takes its set from the caller.
##
## ponytail: no AI, no wandering, no schedule -- they stand and animate, like
## --creatures. Facing is 0 for the same reason it is 0 there: no field in any
## record has been shown to carry it, and scattering yaw would be invention
## dressed as behaviour.
const NPC_MAX := 64
## Cells, not sectors: an NPC two sectors away is invisible but still costs a
## rig build. Sized to cover a town square at the middle zoom step.
const NPC_RADIUS := 48.0


func _build_npcs(install: String, models: Sacred.Models, player_cell: Vector2) -> void:
	var tex_pak := Sacred.Pak.new(install.path_join("pak/texture.pak"))
	var start := Time.get_ticks_msec()
	var sc := Sacred.Startcode.new(install.path_join("bin/type_npc_seraphim"))
	if sc.npcs.is_empty():
		printerr("npcs\tstartcode.bin decoded no NPC records under %s" % install)
		return
	var items := Sacred.Items.new(Sacred.Pak.new(install.path_join("pak/items.pak")))

	# Nearest first, so a cap truncates the far edge of the crowd rather than an
	# arbitrary slice of it -- and so whatever gets dropped is reportable rather
	# than silent. A silent cap reads as "this is everything there is".
	var near: Array[Dictionary] = []
	for n in sc.npcs:
		var c: Vector2i = n["cell"]
		if c == Sacred.Startcode.NO_CELL:
			continue
		var cell := Vector2(c)
		var d := cell.distance_to(player_cell)
		if d <= NPC_RADIUS:
			near.append({"rec": n, "cell": cell, "d": d})
	near.sort_custom(func(a, b): return a["d"] < b["d"])
	var dropped := maxi(0, near.size() - NPC_MAX)
	var in_radius := near.size()
	if dropped > 0:
		near.resize(NPC_MAX)
	if near.is_empty():
		print("npcs\tcell=%d,%d\tin_radius=0\t(no scripted NPC stands within %d cells)" % [
			int(player_cell.x), int(player_cell.y), int(NPC_RADIUS)])
		return

	# Resolve every mesh BEFORE building any rig, so Sacred.Rigs decodes the
	# clip corpus once for the whole crowd -- the same reason _build_creatures
	# does it, and that one pass is its whole cost.
	var picks: Array[Dictionary] = []
	var wanted := PackedInt32Array()
	var unresolved := 0
	var armed := 0
	for e in near:
		var rec: Dictionary = e["rec"]
		var nm := items.name_of(rec["body"])
		var mi := models.index_of(nm) if nm != "" else -1
		if mi < 0:
			unresolved += 1
			continue
		if rec["main"] != 0:
			armed += 1
		# The hand items travel as their SKINS too, not just their names: an
		# item's +0x08 is a texture.pak entry and retail prefers it over the
		# mesh's own texture name, which for a shield is the only right picture.
		picks.append({"type": int(rec["body"]), "layer": int(rec["layer"]),
			"name": nm, "mesh": mi, "cell": e["cell"],
			"hands": [items.name_of(rec["main"]), items.name_of(rec["off"])],
			"skins": [items.texture_of(rec["main"]), items.texture_of(rec["off"])]})
		if not wanted.has(mi):
			wanted.append(mi)
	if picks.is_empty():
		print("npcs\tcell=%d,%d\tin_radius=%d\tresolved=0" % [
			int(player_cell.x), int(player_cell.y), in_radius])
		return

	var rigs := Sacred.Rigs.new(models, wanted)
	var built := 0
	var animated := 0
	var drawn_hands := 0
	var refused_hands := 0
	var no_socket_hands := 0
	var kinds := {}
	for pick in picks:
		var pv := PlayerView.new(models, pick["name"], tex_pak,
			PackedStringArray(), items.texture_of(int(pick["type"])))
		if pv.node == null:
			continue
		add_child(pv.node)
		pv.update(pick["cell"])
		pv.configure_actor(int(pick["type"]), items, _shadow_creatures)
		_update_native_actor(pv, pick["cell"], pv.initial_shadow_heading,
			_sim.interior.initial_support_ref(Vector2i(pick["cell"]), pv.actor_type, int(pick["layer"])))
		_creature_views.append(pv)
		_creature_cells.append(pick["cell"])
		built += 1
		# THE HANDS. startcode's tag-0x02 occurrences 1 and 2, docked onto the
		# body's own named sockets -- see checks/compose_check.gd for the census
		# that fixes which socket is which hand and the control that separates
		# them. equip() refuses rather than guesses, so an item the body cannot
		# carry leaves the hand empty and is counted here instead.
		for slot in [1, 2]:
			var held: String = pick["hands"][slot - 1]
			if held == "":
				continue
			if pv.equip(models, held, slot, int(pick["skins"][slot - 1])):
				drawn_hands += 1
			else:
				refused_hands += 1
		no_socket_hands += pv.equipped_refused()
		# --npcs-noanim mirrors --creatures-noanim, and exists for the same
		# reason it does: MANY CLIPS SPLAY THE RIG THEY ARE BOUND TO. WOLF.GRN
		# under WOLF_ATTACK_BH_A comes out as a flattened ribbon with a detached
		# head -- in `--grn=` isolation, with no placement, no equipment and no
		# world, so it is the clip-to-skeleton binding and nothing downstream of
		# it. SOLDIER under SOLD_WALK_BH is fine, so it is per-clip rather than
		# universal. That is rows 609 and 739 (the clip and the mesh do not share
		# the bone chain above Bip01), still open. Without this flag a splayed
		# rig is indistinguishable from a missing one, which is exactly how it
		# was first reported.
		# rest_clip(), NOT clip_for(). clip_for is the best GEOMETRIC score and
		# for a standing character that is routinely wrong: it gives NOVIZIN02 a
		# WALK, THIEF2_MAL another character's WALK, and the Seraphim herself
		# SERA_SPECIAL_MULTI_2WAFFEN -- a two-weapon special attack. rest_clip
		# prefers IDLE, then FIDLE, then WALK, and falls back to clip_for, which
		# is why view/player_view.gd has used it for the hero all along. These
		# builders did not, and that was the whole of the "wrong pose" defect.
		var ci: int = -1 if "--npcs-noanim" in OS.get_cmdline_user_args() + OS.get_cmdline_args() \
			else rigs.rest_clip(pick["mesh"])
		var mv := pv.node as ModelView
		if mv != null and ci >= 0 and mv.play_clip(models, ci):
			animated += 1
			# Desynchronise by CELL, not by rng: these are FIXED placements, so
			# the same NPC has to look the same in every capture or a
			# screenshot pair stops being comparable.
			var c: Vector2 = pick["cell"]
			mv.seek_anim(fmod(absf(c.x * 7.0 + c.y * 13.0), maxf(0.001, mv.anim_length)))
		kinds[pick["name"]] = int(kinds.get(pick["name"], 0)) + 1
	print("npcs\tcell=%d,%d\tin_radius=%d\tbuilt=%d\tanimated=%d\tarmed=%d\thands=%d\trefused=%d\tno_socket=%d\tunresolved=%d\tdropped=%d\tmeshes=%d\t%d ms" % [
		int(player_cell.x), int(player_cell.y), in_radius, built, animated,
		armed, drawn_hands, refused_hands, no_socket_hands, unresolved, dropped,
		wanted.size(), Time.get_ticks_msec() - start])
	var listed := PackedStringArray()
	for k: String in kinds:
		listed.append("%s x%d" % [k, kinds[k]])
	print("npcs\t%s" % ", ".join(listed))


## The starting quest, run. Retail's `cInterpretSQW` fires a quest's OnEnter as
## the player arrives; quest 1 (`Tutorial`) is the one that stands a novice nun
## beside the Seraphim at the start, and until 2026-08-25 the port drew nothing
## there at a measured cost of 0.918pp of the world band -- more than the whole
## hero (row 1105).
##
## The hook does NOT carry her position on the CreateNPC. It creates her by
## handle (`res:17095`, creature 679 = NOVIZIN02.GRN) and a separate NPC_Goto
## two records later puts her at cell 3237,2514. That is why QuestCast keys on
## the handle and why nothing here reads a cell out of a create record.
##
## WHAT THIS DOES NOT DO: pick which quests are live. Retail decides that from
## sector and region entry across 11,414 script symbols, and none of that
## scheduler is ported. This runs ONE hook, the one a new game is known to
## start with, and says so on its fact line -- a stand-in that is honest about
## being one rather than a general quest system that is secretly one case.
const START_QUEST := 1
## Where an NPC_Goto leaves its subject, in cells, relative to the target cell's
## corner. See the measurement at the placement site below.
const GOTO_CELL_CENTRE := Vector2(0.5, 0.5)
func _build_quest_cast(install: String, models: Sacred.Models, items: Sacred.Items,
		tex_pak: Sacred.Pak) -> void:
	# The guard lives HERE and not at the call site, so a second caller cannot
	# be added that quietly ignores the flag -- the --nodress lesson (row 1102).
	if not _run_quests:
		print("quest\tid=%d\tskipped=--noquests" % START_QUEST)
		return
	var start := Time.get_ticks_msec()
	var dir := install.path_join("bin/%s" % START_CLASS)
	var vec := Sacred.Vectoren.new(dir)
	if not vec.found or not vec.has_quest(START_QUEST):
		printerr("quest\tid=%d\tnot in %s" % [START_QUEST, dir])
		return
	var hook: Dictionary = vec.hook(START_QUEST, Sacred.Vectoren.H_ON_ENTER)
	if hook.is_empty():
		printerr("quest\tid=%d\tno OnEnter hook" % START_QUEST)
		return
	var code := FileAccess.get_file_as_bytes(dir.path_join("funkcode.bin"))
	var vm := ScriptVM.new()
	var cast := QuestCast.new()
	_quest_cast = cast   # E1: retained so Checkpoint.capture can read the live cast
	if not vm.run(code, hook["offset"], hook["length"], cast):
		# A REFUSAL IS REPORTED, NOT SWALLOWED. ScriptVM refuses a whole hook
		# rather than skipping the opcode it cannot run, so this is "she is
		# absent and here is exactly why", which is what a silent return would
		# have cost the last three sessions.
		printerr("quest\tid=%d\trefused_op=%d\t(nothing executed)" % [
			START_QUEST, vm.refused_op])
		return
	cast.mark_entered(START_QUEST)

	# Resolve every mesh BEFORE building any rig, so Sacred.Rigs decodes the
	# clip corpus ONCE for the whole cast -- the same reason _build_npcs does
	# it, and that one pass is its whole cost. Constructing a Rigs per NPC
	# inside the loop measured 8.9 s for a cast of one.
	var picks: Array[Dictionary] = []
	var wanted := PackedInt32Array()
	var unresolved := 0
	var placed := cast.placed()
	# A SCRIPTED NPC IS WORLD STATE, not a posed doll. Each placed cast entry
	# becomes a simulation actor, so NPC_Goto drives real movement and later
	# quests can walk the same res: handle (quest 9 does exactly that). The
	# renderer then follows the actor, exactly like the hero.
	var scripted: Dictionary[int, ActorState] = {}
	var registry := _registry
	for e: Dictionary in placed:
		var nm: String = items.name_of(int(e["creature"]))
		var mi := models.index_of(nm) if nm != "" else -1
		if mi < 0:
			unresolved += 1
			continue
		if registry != null and _sim != null:
			var id := registry.spawn(int(e["creature"]),
				Vector2(e["cell"]) + GOTO_CELL_CENTRE, 40, 40)
			if id != ActorRegistry.INVALID_ID:
				scripted[int(e["creature"])] = registry.get_actor(id)
		# A GOTO DESTINATION IS A CELL CENTRE, not a cell corner. `cell_to_world`
		# maps an integer cell to its corner vertex, which is right for the hero --
		# she is SPAWNED at a cell and her feet land on retail's to the pixel
		# (y=385 both engines, x within 1). It is wrong for an NPC that WALKED
		# here: retail's `NPC_Goto` converges on the middle of the target cell, and
		# at the corner the port drew her 27 px high.
		#
		# MEASURED, not assumed. Her feet: corner 456, centre 480, retail 483 --
		# so +0.5 closes 24 of the 27 px and the remaining 3 are inside the slack
		# between an exact port mask and a brightness-segmented retail one. The
		# offset is exactly half a cell on both axes, which moves a figure +24 px
		# down the screen and 0 px across, and `x` was already correct -- a fit
		# would have needed both axes to move.
		#
		# Her resting place is reproducible: three retail runs put her extent at
		# EXACTLY y 362-483, x 402-425. A fourth caught her at y 340-419 -- still
		# walking at the 4 s mark, which is the same reason this is a destination
		# and not a spawn point. The port does not simulate the walk, so it draws
		# where she ends up.
		picks.append({"type": int(e["creature"]), "name": nm, "mesh": mi,
			"cell": Vector2(e["cell"]) + GOTO_CELL_CENTRE})
		if not wanted.has(mi):
			wanted.append(mi)
	var rigs: Sacred.Rigs = Sacred.Rigs.new(models, wanted) if not wanted.is_empty() else null

	var built := 0
	var animated := 0
	# Renderer follows the simulation actor when one exists. She walks her
	# NPC_Goto route through the same Movement sweep as the hero instead of
	# being drawn at her destination.
	var scripted_views: Dictionary[int, PlayerView] = {}
	for pick: Dictionary in picks:
		var nm: String = pick["name"]
		var mi: int = pick["mesh"]
		var pv := PlayerView.new(models, nm, tex_pak,
			PackedStringArray(), items.texture_of(int(pick["type"])))
		if pv.node == null:
			unresolved += 1
			continue
		add_child(pv.node)
		var actor: ActorState = scripted.get(int(pick["type"]))
		var cell: Vector2 = actor.cell if actor != null else pick["cell"]
		pv.update(cell)
		# The scripted Goto supplies the initial world-space travel direction;
		# native actor placement converts it once for both body and shadow.
		pv.configure_actor(int(pick["type"]), items, _shadow_creatures)
		_update_native_actor(pv, cell, cell - Vector2(start_cell),
			_sim.interior.initial_support_ref(Vector2i(cell), pv.actor_type, 0))
		# Shared with the rolled and scripted casts so the tree frees these rigs
		# by exactly the same route -- _build_npcs' own stated reason.
		_creature_views.append(pv)
		_creature_cells.append(cell)
		if actor != null:
			scripted_views[actor.id] = pv
		built += 1
		# rest_clip(), NOT clip_for(). clip_for is the best GEOMETRIC score and
		# for a standing character that is routinely wrong: it gives NOVIZIN02 a
		# WALK, THIEF2_MAL another character's WALK, and the Seraphim herself
		# SERA_SPECIAL_MULTI_2WAFFEN -- a two-weapon special attack. rest_clip
		# prefers IDLE, then FIDLE, then WALK, and falls back to clip_for, which
		# is why view/player_view.gd has used it for the hero all along. These
		# builders did not, and that was the whole of the "wrong pose" defect.
		var ci: int = rigs.rest_clip(mi) if rigs != null else -1
		var mv := pv.node as ModelView
		if mv != null and ci >= 0 and mv.play_clip(models, ci):
			animated += 1
			# Desynchronise by CELL and not by rng, for the reason _build_npcs
			# gives: these are fixed placements, so the same NPC must look the
			# same in every capture or a screenshot pair stops being comparable.
			mv.seek_anim(fmod(absf(cell.x * 7.0 + cell.y * 13.0),
				maxf(0.001, mv.anim_length)))
	print("quest\tid=%d\ttitle=%s\trecords=%d\tcast=%d\tplaced=%d\tbuilt=%d\tanimated=%d\tunresolved=%d\tcompass=%d\tbook=%d\t%d ms" % [
		START_QUEST, vec.title_of(START_QUEST), vm.executed, cast.cast.size(),
		placed.size(), built, animated, unresolved,
		placed.reduce(func(n: int, e: Dictionary) -> int: return n + (1 if e["compass"] else 0), 0),
		cast.lines.size(), Time.get_ticks_msec() - start])
	_scripted_views = scripted_views
	# THE CLIP IS NAMED, not just counted. A capture that says `animated=1` and
	# nothing more cannot tell an idle from a walk, and a walk is exactly what
	# clip_for() was handing this NPC while she stood still.
	for pick: Dictionary in picks:
		var rc: int = rigs.rest_clip(pick["mesh"]) if rigs != null else -1
		print("quest\tmodel=%s\tcell=%d,%d\tclip=%s" % [
			pick["name"], int(pick["cell"].x), int(pick["cell"].y),
			models.entry_name(rc) if rc >= 0 else "<none>"])
	for e: Dictionary in placed:
		print("quest\tnpc=%s\tcreature=%d\tcompass=%s" % [
			e["name"], int(e["creature"]), e["compass"]])


## --equip=PREFIX[,PREFIX...] -- the R1.4 demonstration (autoresearch row 741):
## a character's equipment meshes share that character's skeleton, so a body and
## its armour can be drawn as separate meshes driven by ONE pose.
##
## What makes this a demonstration rather than a trick: there is NO retargeting
## step here, and no per-piece binding code. Each mesh is built by the same
## unmodified ModelView.setup() and handed the SAME clip through the same
## unmodified play_clip(), then every rig is seeked to the SAME time. If the
## pieces did not genuinely share the base's skeleton -- same bone names, same
## topology, same local rests -- they would animate independently and slide off
## the body, which is exactly what a failure looks like on screen.
##
## The clip is chosen by Sacred.Rigs (bone geometry, not name) unless --anim=
## names one, so this also exercises the picker end to end.
##
## ponytail: no equipped-item -> mesh mapping exists, because that mapping is
## unread (row 741's own stated limit). The caller names the set. Upgrade path
## is whatever table retail uses to decide which pieces an equipped item shows.
const EQUIP_MAX := 16
## Mid-clip rather than t=0: at rest every piece sits in its bind pose and a
## still frame cannot tell a shared skeleton from a coincidence. Posed, a piece
## bound to the wrong rig is obvious.
const EQUIP_SEEK := 0.35


func _show_equip(install: String, spec: String, anim_name: String = "") -> void:
	var pak := Sacred.Pak.new(install.path_join("pak/models.pak"))
	if not pak.is_open():
		printerr("equip\tcannot open pak/models.pak under %s" % install)
		get_tree().quit(1)
		return
	var models := Sacred.Models.new(pak)

	var prefixes := PackedStringArray()
	for raw in spec.split(","):
		var t := raw.strip_edges().to_upper()
		if t != "":
			prefixes.append(t)
	if prefixes.is_empty():
		printerr("equip\t--equip= needs at least one name prefix")
		get_tree().quit(1)
		return

	# Collected in PREFIX order, not pak order, so the first named prefix owns
	# the camera framing below -- a caller naming the body first gets the body
	# framed rather than whichever piece happens to sit lowest in the pak.
	var entries := PackedInt32Array()
	for pre in prefixes:
		for i in models.count():
			if models.kind_of(i) == Sacred.Models.KIND_MOTION:
				continue
			if entries.size() >= EQUIP_MAX:
				break
			if models.entry_name(i).to_upper().begins_with(pre) and not entries.has(i):
				entries.append(i)
	if entries.is_empty():
		printerr("equip\tno mesh in pak/models.pak begins with any of %s" % ", ".join(prefixes))
		get_tree().quit(1)
		return

	# THE SWITCH (rows 743/744). The FIRST prefix names the wearer; every other
	# mesh is asked what it becomes on that wearer, so a Gladiator armour set
	# can be pointed at a Seraphim and comes back as Seraphim armour. Applying
	# it unconditionally is safe because a wearer's own mesh switches to itself
	# (armour_check.gd pins that); a mesh the table does not know -- the body
	# itself, a creature, a numbered set piece -- is left exactly as it was.
	var armour := Sacred.Armour.new(install)
	var wearer := models.entry_name(entries[0])
	var switched := 0
	var multi := PackedStringArray()
	if armour.found:
		for k in range(1, entries.size()):
			var have := models.entry_name(entries[k])
			var v := armour.variants_for(have, wearer)
			if v.is_empty():
				continue
			if v.size() > 1 or armour.is_ambiguous(have):
				# Two reasons a caller must be told rather than quietly served:
				# retail lists this wearer twice in the group, or this FILENAME
				# is several armour records in different groups and only an item
				# (which --equip does not have) could say which. First taken.
				multi.append("%s->%s%s" % [have, ",".join(v),
					" [name spans %d groups]" % armour.group_count(have) if armour.is_ambiguous(have) else ""])
			var mi := models.index_of(v[0])
			if mi >= 0 and mi != entries[k]:
				entries[k] = mi
				switched += 1
	else:
		printerr("equip\tbin/rust.bin did not decode -- drawing the named meshes unswitched")

	var clip := -1
	if anim_name != "":
		clip = models.clip_index_of(anim_name)
		if clip < 0:
			printerr("equip\tno clip named %s" % anim_name)
			get_tree().quit(1)
			return
	else:
		# The picker under test, asked about the FIRST mesh only: every piece
		# then gets that one clip, which is the point being demonstrated.
		var want := PackedInt32Array()
		want.append(entries[0])
		clip = Sacred.Rigs.new(models, want).clip_for(entries[0])

	var built := 0
	var played := 0
	var verts := 0
	var tris := 0
	var names := PackedStringArray()
	# The camera goes on the first mesh that BUILDS, not on entry 0. Framing on
	# index 0 unconditionally means one undecodable mesh at the head of the list
	# leaves the whole scene unframed and captures a blank grey frame -- which
	# is exactly what it did the first time this ran, on a set whose base mesh
	# does not decode.
	var framed := false
	for k in entries.size():
		var e: int = entries[k]
		var mv := ModelView.new()
		mv.name = "Equip%d" % k
		# Only ONE rig builds a camera and light; the rest would each add a
		# competing Camera3D, exactly as PlayerView's frame_camera=false
		# comment describes.
		if not mv.setup(models, e, not framed):
			printerr("equip\t%s has no decodable mesh -- skipped" % models.entry_name(e))
			mv.free()
			continue
		framed = true
		add_child(mv)
		built += 1
		verts += mv.vertex_count
		tris += mv.triangle_count
		names.append(models.entry_name(e))
		if clip >= 0 and mv.play_clip(models, clip):
			# Same time on every rig. Nothing synchronises them afterwards --
			# they stay together only because they are the same skeleton.
			mv.seek_anim(EQUIP_SEEK)
			played += 1
	print("equip\tprefixes=%s\tmeshes=%d\tbuilt=%d\tanimated=%d\tclip=%s\tverts=%d\ttris=%d\twearer=%s\tswitched=%d" % [
		",".join(prefixes), entries.size(), built, played,
		models.entry_name(clip) if clip >= 0 else "none", verts, tris, wearer, switched])
	if not multi.is_empty():
		print("equip\tambiguous (retail lists this wearer twice, first taken): %s" % ", ".join(multi))
	print("equip\t%s" % ", ".join(names))
	if built == 0:
		printerr("equip\tnothing built -- refusing to exit 0 on an empty render")
		get_tree().quit(1)
		return
	# Same settle-and-capture path --grn= uses; without it this mode never
	# quits under --shot= and a capture run hangs instead of failing.
	await _maybe_screenshot()


## The one definition of where the scripted route puts the actor at tick `t`.
## Both the live path and the recorder's write loop call THIS -- they used to
## carry the same conditional twice, and two spellings of one rule is how a
## record/replay divergence starts.
##
## The actor WALKS in through the door and WALKS back out over the step. No leg
## of this route is a teleport -- every tick moves to a 4-adjacent open cell:
##   t < entry_start     standing on the outside end of the path
##   entry_start ..      the path REVERSED, one cell per tick, arriving on the
##                       DOOR exactly at INTERIOR_TICK -- which is the tick the
##                       INTERIOR swap fires -- then continuing to the floor
##   .. exit_start       standing on the interior floor
##   exit_start ..       the path FORWARDS, arriving on the STEP exactly at
##                       EXTERIOR_TICK, which fires the EXTERIOR swap back
##   after               standing on the outside end again, already EXTERIOR
##
## Exactly two swaps survive this: the steps are crossed on the way in while
## the state is already EXTERIOR, and the door is crossed on the way out while
## it is already INTERIOR, so neither adds a third line.
func _supported_route_cell(t: int) -> Vector2i:
	var n := SUPPORTED_ROUTE_PATH.size()
	# Walking IN is the path reversed, timed so the DOOR lands on the interior
	# tick; walking OUT is the path forwards, timed so the STEP lands on the
	# exterior tick. Crossing the steps on the way IN changes nothing (the
	# state is already EXTERIOR) and crossing the door on the way OUT changes
	# nothing (already INTERIOR), so the run still emits exactly two swaps.
	var entry_start := SUPPORTED_ROUTE_INTERIOR_TICK - (n - 1 - SUPPORTED_ROUTE_DOOR_INDEX)
	var exit_start := SUPPORTED_ROUTE_EXTERIOR_TICK - SUPPORTED_ROUTE_STEP_INDEX
	if t < entry_start:
		return SUPPORTED_ROUTE_PATH[n - 1]
	if t < entry_start + n:
		return SUPPORTED_ROUTE_PATH[n - 1 - (t - entry_start)]
	if t < exit_start:
		return SUPPORTED_ROUTE_PATH[0]
	if t < exit_start + n:
		return SUPPORTED_ROUTE_PATH[t - exit_start]
	return SUPPORTED_ROUTE_PATH[n - 1]


## One key light for the streamed world, added ONLY when a rig is actually
## built. Everything SectorView draws is SHADING_MODE_UNSHADED -- the retail
## art is already lit, so terrain, objects and markers ignore this light
## entirely and their pixels do not move. ModelView's meshes are the one lit
## material in the scene, and in the world path ModelView is built with
## frame_camera=false, so before this the rigs were lit surfaces with NO light
## at all: they rendered as near-black silhouettes. That is why --creatures
## produced figures a pixel diff could find but an eye could not.
##
## Deliberately lights and NOT an Environment: ambient would need a
## WorldEnvironment, whose background mode repaints the area outside the map,
## and several gates assert frame md5s. A light cannot touch a pixel that no lit
## material covers, so both of these are invisible to terrain by construction --
## everything SectorView draws is SHADING_MODE_UNSHADED, and the bare-wall patch
## against retail stayed 100.00% bit-identical across this change.
##
## THE FILL IS THE SECOND HALF OF THAT ARGUMENT, not a preference. With the key
## alone the shaded side of every rig fell to near-black -- ModelView's own
## documented trade-off when it has no fill, and it is why the hero read as a
## silhouette in the world while --figure= showed her properly. ModelView's
## preview buys the fill with an ambient Environment, which this scene may not
## have; one more directional light from the opposite side buys it without one.
##
## CALIBRATED AGAINST RETAIL IN THE SAME ROOM, not chosen by eye. Driving retail
## to the Seraphim's campaign start (analysis/tools/drive/menu.sh new) and
## measuring both engines' hero over the same pixels of Silver Creek's
## cathedral:
##
##            brightness p50   p90    saturation p50
##   retail        87          168        0.20
##   key only      46          102        0.35   <- unlit shaded side
##   key + fill    85          119        0.20
##
## The median and the colour land on retail. What is still short is the HIGHLIGHT
## end -- p90 119 against 168 -- which a fill cannot supply by construction: it
## lifts shadow, it does not add speculars. That gap is the key's business, or
## retail's own character shading, and it wants its own measurement rather than
## more fill (raising this further only drags saturation below retail's 0.20).
const FILL_ENERGY := 1.25
## The fill leans blue the way ModelView's ambient fill does, so a rig in the
## world reads as the same material --grn= shows rather than a warmer one.
const FILL_COLOR := Color(0.55, 0.60, 0.72)

func _ensure_rig_light() -> void:
	if has_node("RigKey"):
		return
	var key := DirectionalLight3D.new()
	key.name = "RigKey"
	key.light_energy = ModelView.KEY_ENERGY
	# Same direction ModelView frames its own previews with, so a creature in
	# the world is lit the way --grn= shows it rather than from some new angle.
	key.transform = Transform3D(Basis(), Vector3.ZERO).looking_at(
		ModelView.LIGHT_DIR.normalized(), Vector3.UP)
	add_child(key)

	var fill := DirectionalLight3D.new()
	fill.name = "RigFill"
	fill.light_energy = FILL_ENERGY
	fill.light_color = FILL_COLOR
	# Straight opposite the key: the surfaces the key grazes are exactly the
	# ones this has to reach. Shadows stay off (the default) -- a fill that
	# cast them would carve a second set of shadows into retail art the key
	# already cannot touch.
	fill.transform = Transform3D(Basis(), Vector3.ZERO).looking_at(
		-ModelView.LIGHT_DIR.normalized(), Vector3.UP)
	add_child(fill)


## --figure=NAME --stage=STAGE -- the STAGED single-model viewer.
##
## WHY IT EXISTS. Every character defect so far was diagnosed from the streamed
## world, where a character is sixty pixels wide, unlit, half behind a tent and
## possibly not in frame at all -- and where a splayed rig, an invisible one and
## an absent one are the same picture. Three defects in a row were attributed to
## the wrong layer that way. This route builds ONE model with NOTHING around it
## and adds one layer at a time, so a fault belongs to the layer that introduced
## it.
##
##   skeleton  bones only, drawn as lines, mesh hidden
##   mesh      + the geometry, untextured
##   textured  + texture.pak skins        (--grn= never passes the pak at all)
##   equipped  + whatever items dock on the named sockets
##
## Each stage is a superset of the one before, so the first stage that looks
## wrong names the culprit.
const FIGURE_STAGES := ["skeleton", "mesh", "surfaces", "textured", "equipped"]


func _show_figure(install: String, name: String, stage: String, anim_name: String = "",
		figure_yaw: float = 270.0, only_surface: int = -1) -> void:
	if not FIGURE_STAGES.has(stage):
		printerr("figure\tunknown --stage=%s, expected one of %s" % [stage, ", ".join(FIGURE_STAGES)])
		get_tree().quit(1)
		return
	var pak := Sacred.Pak.new(install.path_join("pak/models.pak"))
	if not pak.is_open():
		printerr("figure\tcannot open pak/models.pak under %s" % install)
		get_tree().quit(1)
		return
	var models := Sacred.Models.new(pak)
	var idx := models.index_of(name)
	if idx < 0:
		printerr("figure\tno model named %s in pak/models.pak" % name)
		get_tree().quit(1)
		return
	var rank := FIGURE_STAGES.find(stage)

	var view := ModelView.new()
	view.name = "Figure"
	# The pak is withheld below the textured stage rather than the material being
	# stripped afterwards, so "mesh" really is the geometry layer and cannot be
	# quietly carrying a skin.
	if rank >= 3:
		view.set_texture_pak(Sacred.Pak.new(install.path_join("pak/texture.pak")))
	if not view.setup(models, idx):
		printerr("figure\t%s has no decodable mesh" % models.entry_name(idx))
		view.free()
		get_tree().quit(1)
		return
	add_child(view)

	var skel: Skeleton3D = view.get_node_or_null("Skeleton")
	var mesh_node: MeshInstance3D = view.get_node_or_null("Skeleton/Mesh")
	if mesh_node == null:
		mesh_node = view.get_node_or_null("Mesh")

	if rank == 1 + 1:
		# SURFACES -- one flat colour per draw batch, so a batch that is missing,
		# duplicated or drawing someone else's triangles is named rather than
		# guessed at. A skin hides exactly this: a wrongly-assigned batch still
		# looks like plausible leather.
		var mesh_res: ArrayMesh = mesh_node.mesh
		for i in mesh_res.get_surface_count():
			var m := StandardMaterial3D.new()
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			m.albedo_color = Color.from_hsv(float(i) / float(maxi(mesh_res.get_surface_count(), 1)), 0.85, 1.0)
			# --surface=N isolates one batch. Reading six hues off one picture is
			# guesswork; one batch lit against a hidden body is not.
			if only_surface >= 0 and i != only_surface:
				m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				m.albedo_color = Color(0.25, 0.25, 0.28, 0.12)
			mesh_node.set_surface_override_material(i, m)
			print("  legend\tsurface=%d\thue=%.2f" % [i, float(i) / float(maxi(mesh_res.get_surface_count(), 1))])

	if rank == 0:
		# Bones only. The mesh is hidden rather than not built, because the camera
		# is framed from the mesh AABB and a skeleton drawn at a different scale
		# to the body it drives would be a picture of nothing.
		if mesh_node != null:
			mesh_node.visible = false
		if skel != null:
			view.add_child(_bone_lines(skel, view.bound_bones()))

	# --surface=N also isolates in the TEXTURED stage, which is where a batch
	# sampling the empty grey background of the wrong image has to be caught: at
	# full dress every batch carries something and the wrong one is only obvious
	# alone.
	if rank >= 3 and only_surface >= 0 and mesh_node != null and mesh_node.mesh != null:
		for i in mesh_node.mesh.get_surface_count():
			if i == only_surface:
				continue
			var hide := StandardMaterial3D.new()
			hide.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			hide.albedo_color = Color(0.25, 0.25, 0.28, 0.10)
			mesh_node.set_surface_override_material(i, hide)

	var docked := PackedStringArray()
	if rank >= 4 and skel != null:
		# A carried mesh is skinned by the ITEM that carries it, so the piece is
		# reached through an items.pak record rather than by mesh name alone.
		# Twelve items name SHIELD_KITE.GRN and differ ONLY in that skin, so this
		# takes the first and prints which -- picking one silently would make the
		# viewer look like it knew something it does not.
		var ipak := Sacred.Pak.new(install.path_join("pak/items.pak"))
		var items := Sacred.Items.new(ipak) if ipak.is_open() else null
		for pair in [[ModelView.SOCKET_MAIN, "SWORD.GRN"], [ModelView.SOCKET_OFF, "SHIELD_KITE.GRN"]]:
			var socket: String = pair[0]
			var item: String = pair[1]
			var ie := models.index_of(item)
			if ie < 0:
				continue
			var rec := -1
			var skin := -1
			if items != null:
				var recs := items.records_naming(item)
				if not recs.is_empty():
					rec = recs[0]
					skin = items.texture_of(rec)
			if view.attach_socket(models, ie, socket, skin) != null:
				docked.append("%s@%s%s" % [item, socket,
					"" if rec < 0 else "(item %d skin %d)" % [rec, skin]])
	if anim_name != "":
		var ai := models.clip_index_of(anim_name)
		if ai >= 0 and view.play_clip(models, ai):
			view.seek_anim(0.35)

	_reframe(view, mesh_node, figure_yaw)
	# WHICH IMAGE LANDED ON WHICH BATCH, as data rather than as a judgement about
	# a 60-pixel render. material_groups() gives {mesh, material, triangles} and
	# texture_names() is the entry's own Texture-node order, so this is the exact
	# pairing _skin_material made, printed back.
	for i in view.surface_texture.size():
		var tris := 0
		if mesh_node != null and mesh_node.mesh != null:
			tris = mesh_node.mesh.surface_get_array_index_len(i) / 3
		print("  surface\t%d\tmaterial=%d\ttris=%d\ttexture=%s" % [
			i, view.surface_material[i], tris, view.surface_texture[i]])
	if skel != null:
		for c in skel.get_children():
			if not (c is BoneAttachment3D):
				continue
			var att2: BoneAttachment3D = c
			var bp := skel.get_bone_global_pose(att2.bone_idx)
			print("  dock\t%s\tbone=%s\tatt.origin=%s\tbone_pose.origin=%s\ttracking=%s" % [
				att2.name, skel.get_bone_name(att2.bone_idx), att2.transform.origin,
				bp.origin, att2.transform.origin.distance_to(bp.origin) < 0.01])
	print("figure\t%s\tstage=%s\tverts=%d\ttris=%d\tsurfaces=%d\ttextured=%d/%d\tbones=%d\troots=%d\tbinds=%d\tsockets=%s\trefused=%d" % [
		models.entry_name(idx), stage, view.vertex_count, view.triangle_count,
		view.surfaces, view.textured_surfaces, view.surfaces,
		view.bone_count, view.bone_roots, view.bind_count,
		",".join(docked) if not docked.is_empty() else "none", view.sockets_refused])
	await _maybe_screenshot()


## One line per bone, from its parent's rest origin to its own, in the skeleton's
## own space. Unshaded and depth-test-disabled so the rig reads as a diagram
## rather than as geometry competing with the body.
func _bone_lines(skel: Skeleton3D, bound: PackedInt32Array) -> MeshInstance3D:
	# Only the bones the skin binds. The rest are the Max scene's furniture --
	# omni lights, camera targets, the weapon sockets -- and they sit hundreds of
	# units away, so drawing them turns the diagram into four rays off the edge
	# of frame and shrinks the actual skeleton to nothing.
	var keep := {}
	for b in bound:
		keep[b] = true
	var im := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.no_depth_test = true
	im.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	for b in skel.get_bone_count():
		if not keep.has(b):
			continue
		var p := skel.get_bone_parent(b)
		var here := skel.get_bone_global_rest(b).origin
		# Walk up to the nearest ancestor that is itself a deforming bone, so
		# skipping a helper does not break the chain into loose segments.
		while p >= 0 and not keep.has(p):
			p = skel.get_bone_parent(p)
		if p < 0:
			# A parentless bone gets a short vertical stub so a root is visible as
			# a mark rather than as nothing at all.
			im.surface_set_color(Color(1, 0.35, 0.2))
			im.surface_add_vertex(here)
			im.surface_add_vertex(here + Vector3(0, 0, 2))
			continue
		im.surface_set_color(Color(0.3, 1, 0.4))
		im.surface_add_vertex(skel.get_bone_global_rest(p).origin)
		im.surface_add_vertex(here)
	im.surface_end()
	var mi := MeshInstance3D.new()
	mi.name = "BoneLines"
	mi.mesh = im
	return mi


## Re-aims the camera ModelView._frame() built, around the model's own vertical.
##
## _frame's CAM_DIR is fixed and lands GLADIATOR side-on, which is the worst
## angle for judging a skin: the chest, the belt and the face are all edge-on.
## This keeps _frame's distance -- its corner-fitting is what stops the model
## being a smudge -- and only swings the eye around, so --grn= and the parity
## dumps that depend on the canonical angle are untouched.
##
## The light is re-aimed with it and lifted, because a key fixed to the old
## direction backlights the model at any other angle.
func _reframe(view: Node3D, mesh_node: MeshInstance3D, yaw_deg: float) -> void:
	var cam: Camera3D = view.get_node_or_null("Camera")
	if cam == null or mesh_node == null or mesh_node.mesh == null:
		return
	var box: AABB = view.transform * mesh_node.mesh.get_aabb()
	var centre := box.get_center()
	var inv := view.transform.affine_inverse()
	var dist := (view.transform * cam.transform).origin.distance_to(centre)
	var dir := Basis(Vector3.UP, deg_to_rad(yaw_deg)) * Vector3(0.35, 0.30, 1.0).normalized()
	cam.transform = inv * Transform3D(Basis(), centre + dir * dist).looking_at(centre, Vector3.UP)
	# _frame's ambient is tuned for a clay silhouette against a dark plate. A
	# SKIN needs to be read for colour and seam placement, not for outline, so
	# the fill comes up and goes neutral -- a blue-grey ambient tints every
	# judgement about a texture that is mostly browns.
	if cam.environment != null:
		cam.environment.ambient_light_color = Color(1, 1, 1)
		cam.environment.ambient_light_energy = 1.1
	var key: DirectionalLight3D = view.get_node_or_null("Key")
	if key != null:
		key.light_energy = 2.2
		key.transform = inv * Transform3D(Basis(), centre).looking_at(
			centre - dir + Vector3.UP * 0.35, Vector3.UP)


## RETAIL'S TASKBAR. Built from texture.pak at the coordinates recovered from
## cUI_Taskbar2 -- see view/hud.gd. Skipped under --nohud, which every capture
## runbook that md5s the world wants, because the bar covers the bottom 92 rows
## of a 768-row frame.
func _build_hud(tex_pak) -> void:
	if not _show_hud or tex_pak == null:
		return
	_hud = Hud.new(tex_pak)
	add_child(_hud)
	if _encounter != null and _encounter.log != null:
		# The console shows the quest's own opening line, in English, from
		# global.res -- which is only readable at all since row 954.
		var res := Sacred.Resources.new(
			Sacred.find_install().path_join("scripts/us/global.res"))
		_encounter.log.resolve_with(res)
		for l in _encounter.log.lines:
			if String(l["text"]) != "":
				_hud.show_line(String(l["text"]))
				break
	print("hud\tpieces=%d\tmissing=%s" % [_hud.drawn, _hud.missing])


## Opens world/sectors.keyx once, for the sector-change path. Non-fatal: a run
## whose install lacks the file draws the world and says the environment is
## unavailable, matching every other reader here.
func _build_sector_env(install: String) -> void:
	var s = Sacred.Sectors.new(install)
	if not s.found:
		push_warning("sector-env: world/sectors.keyx unreadable -- no environment selected")
		return
	_sectors = s
	print("sector-env\tready\trecords=%d" % s.count)


## RETAIL'S sub_80DB27C, called once per frame from _process. Fires only on a
## CHANGE of the player's sector, which is retail's own condition -- entering a
## sector every frame would re-trigger the music on every frame.
##
## The cell -> sector conversion lives in Sectors.sector_of, where the
## truncate-towards-zero trap it avoids is gated by sectorenv_check rather than
## restated here.
##
## A sector whose music id is 0 INHERITS whatever is already playing -- 1892 of
## the 6050 sectors carry 0, and that is retail's own `if (env->music)` guard,
## not a decode failure. So `_sector_env` keeps the last non-zero selection and
## only the reported line shows the raw record.
func _update_sector_env(cell: Vector2) -> void:
	if _sectors == null:
		return
	var s: Vector2i = Sacred.Sectors.sector_of(cell)
	if s == _sector_now:
		return
	_sector_now = s
	var env: Dictionary = _sectors.env_of(s.x, s.y)
	if env.is_empty():
		# Off the 6050-sector map. Reported rather than ignored: every in-world
		# sector is present exactly once, so a miss means the coordinate is bad.
		print("sector-env\t%d,%d\toff-map" % [s.x, s.y])
		return
	if int(env["music"]) != 0:
		_sector_env = env
	print("sector-env\t%d,%d\tmusic=%d\tclimate=%d\tregion=%d\tatmo2=%d\tplaying=%d" % [
		s.x, s.y, int(env["music"]), int(env["climate"]), int(env["region"]),
		int(env["atmo2"]), int(_sector_env.get("music", 0))])


## Turns the hero to face where it is going.
##
## READS `facing`, NOT `heading`, and an earlier version of this function read
## `heading` and was therefore dead code in every ordinary session. `heading` is
## a per-tick movement INTENT: it is written only by the recording path
## (_advance_sim), the actor probe, the creature demo and replay, so in a normal
## new game it is identically Vector2.ZERO -- click-to-move moves the hero
## through Sim._path_delta, which by explicit design never stores its direction
## back (world/sim.gd). Gating on it meant face() was never called AT ALL, even
## while the hero walked, and the rig stayed in its mesh rest orientation --
## side-on for the Seraphim.
##
## `ActorState.facing` is the sim's own held answer to "which way is this body
## turned", written from the delta it actually moved, seeded towards the viewer.
## No hold is needed here: the hold lives in the sim, where every actor gets it.
##
## Body and shadow share native actor orientation; no calibrated root-bone
## yaw is applied on top of the actual world-space facing.
func _face_player(p: ActorState) -> void:
	# The standing actor starts from item+87's native angle. Once simulation
	# changes facing, its held movement direction is authoritative. Magnitude
	# is simulation-owned; native float subtraction can differ at large cells.
	if p.facing != _player_shadow_last_facing:
		_player_shadow_heading = p.facing
		_player_shadow_last_facing = p.facing
	if _sim.interior != null:
		_update_native_actor(_player_view, p.cell, _player_shadow_heading, _sim.interior.support_ref())


## A class's HERO entry, joined through the authored item model name. Requiring
## uniqueness avoids assigning arbitrary mesh-sharing creature identities.
func _resolve_player_type() -> int:
	if _shadow_items == null or _shadow_creatures == null:
		return 0
	var found := 0
	for type_id in _shadow_creatures.ids():
		if _shadow_creatures.class_of(type_id) != 1 \
				or _shadow_items.name_of(type_id).to_upper() != _player_model.to_upper():
			continue
		if found != 0:
			push_error("player shadow: selected HERO model has ambiguous actor types")
			return 0
		found = type_id
	if found == 0:
		push_error("player shadow: selected HERO model has no creature type")
	return found


## Current production actors are unattached single-player actors. Building
## support comes from the native authored parent lookup, not the cutaway rect.
## Attachments/remote-player suppression must supply their actual predicates
## when those actor states exist; this call does not pretend they exist now.
func _update_native_actor(pv: PlayerView, cell: Vector2, heading: Vector2,
		support_ref: int) -> void:
	if pv.node != null and _view != null:
		_view.place_actor(pv.node, pv.actor_type, cell, support_ref)
	if _sim.interior == null:
		return
	var base_height := 0.0
	if support_ref != 0:
		var support := _shadow_statics.blob(support_ref) if _shadow_statics != null else PackedByteArray()
		if support.size() <= 51:
			push_error("actor shadow: unresolved support record %d" % support_ref)
			pv.disable_blob_shadow()
			return
		base_height = float(support[51]) * 28.0
	var data: PackedByteArray = _sim.interior.cell_data(Vector2i(floori(cell.x), floori(cell.y)), support_ref)
	var height := PlayerView.NativeActorShadow.support_height(cell, data, 0, base_height)
	pv.update_native_actor(cell, heading, height, support_ref, false,
		ACTOR_SHADOW_DETAIL, false, false)


## THE HERO'S ACTION, chosen once per frame from what the sim actually did.
##
## Retail's own clip pick is a state machine with far more in it than this --
## attacking, casting, being hit, dying -- and none of those states exist in
## the port yet: the encounter resolves swings as arithmetic with no clock, so
## there is nothing to time an ATTACK clip against. What DOES exist is
## movement, so this drives the one distinction the sim can currently justify
## and refuses to invent the rest.
##
## WALK, NEVER RUN. Both clips exist on every class body, but the port has a
## single walk speed (Movement.CELLS_PER_SECOND, measured in row 1013), so
## there is no measured threshold to switch on and picking one would be a
## tuning decision dressed as a port. Row 1053.
func _drive_hero_action(p: ActorState) -> void:
	if _anim_rigs == null:
		return
	var moving := _last_player_cell.is_finite() \
		and _last_player_cell.distance_squared_to(p.cell) > MOVING_EPSILON * MOVING_EPSILON
	_last_player_cell = p.cell
	var want := "WALK" if moving else "IDLE"
	if want == _player_view.action:
		return
	var was: String = _player_view.action
	# PRINTED ON THE TRANSITION ONLY, never per frame. A refused switch is
	# printed too and says so, because a body that cannot walk holding its idle
	# is a fact about the model map (SERAPHIM.GRN resolves no WALK, row 1053)
	# and looks identical on screen to this code not running at all.
	var ok := _player_view.play_action(_anim_models, _anim_rigs, want)
	if ok and want == "IDLE" and _anim_phase >= 0.0:
		# The fitted spawn phase (row 1191): retail's hero does not idle from
		# phase 0; the sweep against her own frames pins this constant.
		var mv := _player_view.node as ModelView
		if mv != null:
			mv.seek_anim(_anim_phase * maxf(0.001, mv.anim_length))
	print("hero_action\t%s->%s\t%s" % [was, want, "playing" if ok else "refused"])


## Exports the hero's full scene tree to glTF (.glb) for Bevy.
## Uses Godot's built-in GLTFDocument — the same code path that powers
## the editor's glTF export. Captures all skinned meshes, materials,
## and textures in one standard-format file.
var _ex_v := 1
var _ex_t := 1
var _ex_n := 1
var _ex_surf := 0
## Texture-name prefix for the current export pass ("" for the hero,
## "_castN_" for a quest-cast rig) so a cast texture cannot overwrite the
## hero's tex_%d.png files.
var _ex_prefix := ""
## --export-sera runs from the FIRST _process frame, not _ready: the rig
## placement (PlayerView.update) and the drop shadow only exist after the
## first tick, and the meta sidecar must carry the placed values.
var _export_pending := false
var _export_frame := 0

func _export_hero_obj(out_path: String) -> void:
	_ex_v = 1
	_ex_t = 1
	_ex_n = 1
	_ex_surf = 0
	var mv := _player_view.node
	if mv == null:
		printerr("export: hero node null")
		get_tree().quit(1)
		return
	var f := FileAccess.open(out_path + ".obj", FileAccess.WRITE)
	var m := FileAccess.open(out_path + ".mtl", FileAccess.WRITE)
	if f == null or m == null:
		printerr("export: cannot open output")
		get_tree().quit(1)
		return
	m.store_line("# Seraphim materials\n")
	(mv as ModelView).prepare_render()
	_export_mesh_children(mv, f, m, out_path)
	f.close()
	m.close()
	_write_rig_meta(out_path, _player_view)
	print("export\thero done surfaces=%d verts=%d" % [_ex_surf, _ex_v])
	# The QUEST CAST rigs beside her (the novizin), same world-space pose the
	# live run drew -- each with its own counters and a tex-name prefix so the
	# texture files cannot collide with the hero's.
	for i in _creature_views.size():
		var cast_view: PlayerView = _creature_views[i]
		if cast_view.node == null:
			continue
		_ex_v = 1
		_ex_t = 1
		_ex_n = 1
		_ex_surf = 0
		_ex_prefix = "_cast%d_" % i
		var cf := FileAccess.open(out_path + "_cast%d.obj" % i, FileAccess.WRITE)
		var cm := FileAccess.open(out_path + "_cast%d.mtl" % i, FileAccess.WRITE)
		if cf == null or cm == null:
			printerr("export: cannot open cast output %d" % i)
			continue
		cm.store_line("# Cast material %d\n" % i)
		(cast_view.node as ModelView).prepare_render()
		_export_mesh_children(cast_view.node, cf, cm, out_path + "_cast%d" % i)
		cf.close()
		cm.close()
		_write_rig_meta(out_path + "_cast%d" % i, cast_view)
		print("export\tcast%d done surfaces=%d verts=%d" % [i, _ex_surf, _ex_v])
	_ex_prefix = ""
	get_tree().quit(0)

## Placement metadata. Native actor node transforms are affine, not a rotation
## plus uniform scale. OBJ vertices already contain this transform; the full
## row-major basis preserves it for diagnostic consumers without TRS loss.
func _write_rig_meta(out_path: String, pv: PlayerView) -> void:
	var mf := FileAccess.open(out_path + ".meta", FileAccess.WRITE)
	if mf == null or pv._placement == null:
		printerr("export: cannot write rig meta for %s" % out_path)
		return
	mf.store_line("scale=%f" % pv._placement.rig_scale)
	mf.store_line("yaw=%f" % pv._placement.yaw)
	mf.store_line("offset=%f,%f,%f" % [pv._placement.local_offset.x,
		pv._placement.local_offset.y, pv._placement.local_offset.z])
	var node: Node3D = pv.node
	var xf: Transform3D = node.global_transform
	var q: Quaternion = xf.basis.orthonormalized().get_rotation_quaternion().normalized()
	mf.store_line("node_origin=%f,%f,%f" % [xf.origin.x, xf.origin.y, xf.origin.z])
	mf.store_line("node_quat=%f,%f,%f,%f" % [q.w, q.x, q.y, q.z])
	mf.store_line("node_basis_rows=%f,%f,%f,%f,%f,%f,%f,%f,%f" % [
		xf.basis.x.x, xf.basis.y.x, xf.basis.z.x,
		xf.basis.x.y, xf.basis.y.y, xf.basis.z.y,
		xf.basis.x.z, xf.basis.y.z, xf.basis.z.z])
	mf.close()


func _export_mesh_children(node: Node, f: FileAccess, m: FileAccess, out_path: String) -> void:
	for child in node.get_children():
		# These are compositor packets, not model geometry: their vertices are
		# procedural shader inputs and deliberately have no normals/tri indices.
		if child is ModelView.ActorBlobShadow:
			continue
		if child is MeshInstance3D:
			var mi := child as MeshInstance3D
			if mi.mesh == null:
				continue
			for s in mi.mesh.get_surface_count():
				var arrays: Array = mi.mesh.surface_get_arrays(s)
				if arrays.is_empty():
					continue
				var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
				var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
				var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
				# CPU skinning: reproduce exactly what the GPU does for a skinned
				# surface — sum w * (bone_global_pose * bind_pose) * v — so the
				# exported OBJ carries the posed world-space vertices.
				var xf: Transform3D = mi.global_transform
				var skel: Skeleton3D = null
				if mi.skin != null and mi.skin.get_bind_count() > 0 and mi.skeleton != null:
					skel = mi.get_node_or_null(mi.skeleton) as Skeleton3D
				if skel != null:
					var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
					var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
					if bones.size() >= verts.size() * 4:
						var palette: Array[Transform3D] = []
						for bind in mi.skin.get_bind_count():
							var bone := mi.skin.get_bind_bone(bind)
							var pose: Transform3D = skel.get_meta(&"affine_global_poses")[bone] \
								if skel.has_meta(&"affine_global_poses") else skel.get_bone_global_pose(bone)
							palette.append(pose * mi.skin.get_bind_pose(bind))
						var posed_v := PackedVector3Array()
						posed_v.resize(verts.size())
						var posed_n := PackedVector3Array()
						posed_n.resize(norms.size())
						for vi in verts.size():
							var p := Vector3.ZERO
							var nn := Vector3.ZERO
							for k in 4:
								var w: float = weights[vi * 4 + k]
								if w > 0.0:
									var ki: int = bones[vi * 4 + k]
									var bp: Transform3D = palette[ki]
									p += (bp * verts[vi]) * w
									nn += (bp.basis * norms[vi]) * w
							posed_v[vi] = p
							posed_n[vi] = nn.normalized()
						verts = posed_v
						norms = posed_n
					xf = skel.global_transform
				var gname := "surf_%d" % _ex_surf
				var mat: Material = mi.get_surface_override_material(s)
				if mat == null:
					mat = mi.mesh.surface_get_material(s)
				if mat == null:
					mat = mi.material_override
				var texture: Texture2D
				if mat is StandardMaterial3D:
					texture = mat.albedo_texture
				elif mat is ShaderMaterial and mat.shader == PlayerView.NativeObjectShader:
					texture = mat.get_shader_parameter(&"skin")
				if texture != null:
					var img := texture.get_image()
					if img != null:
						img.save_png(out_path.get_base_dir() + "/tex_%s%d.png" % [_ex_prefix, _ex_surf])
						gname = "tex_%s%d" % [_ex_prefix, _ex_surf]
				m.store_line("newmtl %s\nKa 0.5 0.5 0.5\nKd 0.8 0.8 0.8\nillum 2\n" % gname)
				f.store_line("g %s" % gname)
				f.store_line("usemtl %s" % gname)
				for v in verts:
					var wp: Vector3 = xf * v
					f.store_line("v %f %f %f" % [wp.x, wp.y, wp.z])
				var normal_transform := xf.basis.inverse().transposed()
				for n in norms:
					var wn: Vector3 = (normal_transform * n).normalized()
					f.store_line("vn %f %f %f" % [wn.x, wn.y, wn.z])
				for uv in uvs:
					f.store_line("vt %f %f" % [uv.x, uv.y])
				for i in range(0, indices.size(), 3):
					f.store_line("f %d/%d/%d %d/%d/%d %d/%d/%d" % [
						indices[i] + _ex_v, indices[i] + _ex_t, indices[i] + _ex_n,
						indices[i+1] + _ex_v, indices[i+1] + _ex_t, indices[i+1] + _ex_n,
						indices[i+2] + _ex_v, indices[i+2] + _ex_t, indices[i+2] + _ex_n])
				_ex_v += verts.size()
				_ex_t += uvs.size()
				_ex_n += norms.size()
				_ex_surf += 1
		_export_mesh_children(child, f, m, out_path)
