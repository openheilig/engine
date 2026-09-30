# shaders

Floor tiles, static sprites, model images and shadows share a non-HDR canvas
for retail's encoded-space blending, then an opaque spatial display plane.
Models rasterize into private cropped 3D targets first; liquids remain separate.

| Shader | What |
|---|---|
| `floor_canvas.gdshader` | Art RGB times per-corner light, art or independent mask alpha; ordered ground and alternating overlay passes without per-tile depth or alpha testing. |
| `floor_display.gdshader` | Decodes the completed encoded-space scene once for Forward+ output. |
| `object.gdshader` | Encoded-space static/miniature sprite composition with authored alpha and nearest atlas sampling. |
| `static_shadow.gdshader` | Linear/repeat SHADOW_TREE00 atlas, dedicated pass and inline-before-sprite placement; current daylight alpha. |
| `model_canvas.gdshader` | Composites a cropped model viewport with premultiplied alpha at its native FIFO position. |
| `actor_shadow_canvas.gdshader` | Encoded-space SHADOWDOT composition, black alpha 80/255, immediately before its model. |
| `hero_shadow.gdshader` | Spatial SHADOWDOT packet preview. The shared world compositor excludes this mesh and consumes its quads through `actor_shadow_canvas` instead. |
| `native_object.gdshader` | Shared body/equipment/object Gouraud lighting. Converts post-skin world normals back to native light space, applies category ambient and source diffuse/specular, then modulates encoded skin RGB. Initial white daylight only. |

The atlas geometry comes from
[`../formats/texture.gd`](../formats/texture.gd)'s `slot_uv()`: four
asymmetric UV tips in N/E/S/W order, recovered from both retail builds and
verified against live draw inputs. A bounding rectangle or uniform inset
cannot express this table. SectorView places the tile at its cell centre and
uses retail's 48.2/24.2 half-extents over the 96x48 logical grid.
