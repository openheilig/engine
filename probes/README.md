# probes — one-shot investigations

Fifty-six scripts, each written to answer one question about the retail data
and then left alone. They are read-only, they print rather than assert, and
none of them is part of normal work: the engine does not load them and no gate
runs them.

They are kept because a probe is how a fact was *found*. The conclusions live
in [research/formats/](../../research/formats/) and, row by row, in the
findings log — a claim there can be re-measured by running the script that
produced it. Most headers name the log row they answered.

```
godot --headless --path . --script res://probes/<name>.gd
```

Each states its own question and any environment variables it takes (`SIDS=`,
and so on) in its header comment.

## By subject

| Family | Question it was chasing |
|---|---|
| `floor_*` (15) | `world/floor.pak` fields: the tile index, the top 15 bits, layer resolution, spawn and stat fields. |
| `cell1e_*`, `cell08_*` (7) | Region cell classes — what the `0x1e` and `0x08` classes mean, and which are walkable. |
| `trigger_*`, `unnamed_trigger_probe` (4) | Trigger records: rosters, links to creatures, and the unnamed ones. |
| `npc_*`, `creature_*`, `chest_*` (8) | Where an NPC's model, fields and creature record come from; chest and container ids. |
| `corner3_*`, `depth_probe`, `band_probe`, `h0c_probe` (5) | Terrain corner heights, draw depth and height bands. |
| `kapelle_*`, `loggia_scan`, `static_layer_probe`, `overhead_census` (5) | Named buildings and the static/overhead layers, including the roofed-overhang case. |
| `class_*`, `route_class_probe`, `spawninfo_probe`, `defpos_probe` (5) | Class nibbles, route classes, spawn info and default positions. |
| `sector_*`, `f32_probe`, `flag_census`, `itemrec_probe`, `pax_c8`, `snd_count` (7) | Sector tails, float layout, flag and sound censuses, item records, one PAX section. |

## A probe is not a check

A probe prints and forms no verdict; a [check](../checks/) asserts and exits
non-zero. If a probe's finding matters enough to defend against regression, it
graduates into a check — that is the intended direction of travel, and several
of the checks began here.
