# view — rendering

Everything that draws. Actor ownership and simulation advancement remain in
[`../world/`](../world/): `ActorRegistry`, `ActorState`, `RecordStore`, and
`Sim.` stay out of this layer. Views have no `_process` or `_physics_process`.
SectorView reads authored building identity and subscribes to Interior's raw
trigger-state signal; it does not advance or mutate that state.

`parity/verify.gd`'s `LAYER_RULES` scans this directory and fails if either
appears. It is also why `iso_camera.gd` sits at the project root: the camera
legitimately owns a `_process`, so it is not a `view/` file.

| File | What |
|---|---|
| `sector_view.gd` | Streams sectors, retains static spans/shadows and registers live models with their actual cell/type/support. Raw trigger changes refresh static and dynamic admission; model targets retain their original sector/simulation lifetime. |
| `model_view.gd` | Renders Granny meshes and clips. Non-TRS rigs preserve full affine rest/animated scale-shear matrices in GPU skin palettes; worn meshes, sockets, bounds and shadows share the resulting pose. |
| `player_view.gd` | Uses native model-header scale, heading, support height and camera projection for bodies and objects. Shared Gouraud materials replace the old flat ramp; definition texture overrides apply to actors as well as equipment. Solar modulation and projected object shadows remain incomplete. |
| `model_canvas.gd` | Private 3D world and pixel-aligned cropped target per model. Cached bind bounds consume exact affine poses where required; no per-frame vertex extraction or CPU texture readback. Offscreen targets shrink to 2×2. |
| `floor_view.gd` | Shared encoded-color FIFO: floors, static passes, model images and actor/static shadows. Statics precede support-grid and base-grid dynamics at each cell; category partitions retain placement-chain order. Skin updates run at `frame_pre_draw`; static commands remain cached. |
| `actor_blob_shadow.gd` | Five native root/foot SHADOWDOT packets, updated after skeleton modifiers. The world compositor consumes their quads directly; the spatial mesh is excluded from model captures to avoid double shadows. |
| `native_actor_shadow.gd` | Actor type/branch, native model/heading transforms, and authored support-height sampling. Projected/stencil shadows and final raster parity remain incomplete. |
| `hud.gd` | Retail's taskbar and the player-portrait frame, blitted from retail's own sheets at retail's own coordinates on a fixed 1024×768 canvas. Slot and rail counts derive from the number of ASSIGNED arts, not a constant. |
| `liquid.gd` | The animated liquid materials — the 14-record table, its frame sets and the fixed 2048 ms cadence — cached across sectors. |
| `cursor.gd` | Sacred's own mouse pointer, read from the install at runtime. |
| `rig_placement.gd` | A `SkeletonModifier3D` that places a rig. Deliberately has **no** `class_name`: a newly added global class is not in Godot's script-class cache for a `--path` run until the project is reimported. |

Current ordinary model integration is not full renderer parity: liquids and
the native special-vector branch remain separate. Cropped model targets have
independent self-depth; cross-model native depth-buffer equivalence is not
established. Rendered probes cover behind/front occlusion, same-cell placement
order, category partition, hide/restore, camera changes, tree re-entry and
sector unload/revisit. No retail assets or captured geometry are bundled.

The shaders these materials use are in [`../shaders/`](../shaders/); the
readers they draw from are in [`../formats/`](../formats/).
