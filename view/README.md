# view — rendering

Everything that draws. The rule this layer follows is the mirror of
[`../world/`](../world/)'s: it may not name a simulation type
(`ActorRegistry`, `ActorState`, `RecordStore`, `Sim.`) and may not define its
own per-frame entry point — no `_process`, no `_physics_process`. The
simulation drives; the view reflects.

`parity/verify.gd`'s `LAYER_RULES` scans this directory and fails if either
appears. It is also why `iso_camera.gd` sits at the project root: the camera
legitimately owns a `_process`, so it is not a `view/` file.

| File | What |
|---|---|
| `sector_view.gd` | Streams the 100×100 sector grid out of the retail install — one mesh and one `Texture2DArray` per sector, with residency driven by the camera. |
| `model_view.gd` | Renders one Granny `.GRN` entry as a single `ArrayMesh`, with its skeleton and clips. |
| `player_view.gd` | The posed player mesh in the streamed world, depth-sorted against the painted object quads by the same rule the terrain uses. |
| `cursor.gd` | Sacred's own mouse pointer, read from the install at runtime. |
| `rig_placement.gd` | A `SkeletonModifier3D` that places a rig. Deliberately has **no** `class_name`: a newly added global class is not in Godot's script-class cache for a `--path` run until the project is reimported. |

The shaders these materials use are in [`../shaders/`](../shaders/); the
readers they draw from are in [`../formats/`](../formats/).
