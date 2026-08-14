# shaders

Three `spatial` shaders. Sacred is a 2D game drawn in a 3D engine: the only
3D thing about most of what is on screen is the Z it sorts at.

| Shader | What |
|---|---|
| `terrain.gdshader` | Unpacks ARGB4444 out of a `FORMAT_RG8` texture array on the GPU and applies per-corner light. Sampling a sub-rect of the 18-diamond atlas, never `0..1`. |
| `terrain_mask.gdshader` | The `floor.pak` quads that carry a MASK tile. Retail draws these with two texture units and a fixed-function `GL_COMBINE`; this reproduces that. |
| `object.gdshader` | Static object sprites — unshaded screen-space billboards. |

The atlas geometry the terrain shaders sample is
[`../formats/texture.gd`](../formats/texture.gd)'s `slot_uv()`, and the
half-texel inset there exists for a visible reason: without it, linear
filtering reaches into the padding between slots and draws a faint dark grid
over the whole world.
