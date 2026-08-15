# formats — the runtime readers

One file per retail format. Every read seeks into the user's own install;
nothing here copies, caches or ships a retail byte.

These were a single 3800-line `sacred.gd` until they were split out. The
public API did not change: [`../sacred.gd`](../sacred.gd) is now a facade that
preloads each of these under its old name, so `Sacred.Pak`, `Sacred.SECT` and
`Sacred.find_install()` mean exactly what they always did.

| File | Reads |
|---|---|
| `common.gd` | The shared layout constants (`SECT`, `CELL`, `PAK_*`, `KEY_*`) and zlib `inflate`. |
| `pak.gd` | `.pak` archives, on demand — `texture.pak` is 820 MB and is never slurped whole. |
| `tiles.gd` | `tiles.pak`: 64-byte records — source `.tga` name, texture id, and an orientation that is exactly `tile_id % 18`. The table is a product: 18 tile ids per art group. |
| `world.gd` | `sectors.keyx` + `sectors.wldx`. keyx is the shipped index: no scan, no cache. |
| `texture.gd` | ARGB4444 decode, and the 18-diamond atlas geometry `slot_uv()` resolves. |
| `statics.gd` | Placed static art. |
| `mixed.gd` | The mixed object/name archive. |
| `regions.gd` | Region grids and cell classes — what walkability is derived from. |
| `footprints.gd` | Correspondence between region footprints and placed art. |
| `items.gd` | Item and levelled-object records. |
| `models.gd` | Granny `.GRN`: the tag walk, meshes, skeletons, bind poses, weights, clips. |
| `pax.gd` | `.pax` hero saves. |
| `funk.gd` | `Start/FunkCode.bin` script bytecode. |
| `startcode.gd` | `startcode.bin` opcodes 23/1/8 — which NPCs and objects exist, their body and hand items, and the cells they start in. Refuses an unlisted tag rather than shifting its cursor. |
| `factions.gd` | The faction hostility matrix. |
| `creatures.gd` | `creature.pak` records. |
| `rigs.gd` | Rig identity across models — which skeletons are the same rig. |
| `armour.gd` | Armour piece grouping. |
| `resources.gd` | `scripts/<lang>/global.res`, both namespaces — `res:N` by slot for the bytecode, and the engine's own name hash so a numeric resource id resolves. |

## Dependencies point one way

`common.gd` depends on nothing. Each reader preloads only what it actually
uses (`footprints.gd` → `items`, `regions`, `statics`; `rigs.gd` → `models`),
and **nothing here reaches back for `Sacred`** — that would be a preload
cycle, since `Sacred` preloads all of them. Shared numbers therefore live in
`common.gd`, not in the facade.

## The format documentation

What these implement is written up in
[research/formats/](../../research/formats/), and each is independently
re-implemented in Python under [tools/formats/](../../tools/formats/) so the
two can be diffed — see [`../parity/`](../parity/).
