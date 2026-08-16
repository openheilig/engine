shader_type spatial;
// Static object sprites. Unshaded screen-space billboards -- this is a 2D game
// drawn in a 3D engine, and the only 3D thing about an object is the Z it sorts
// on, which the mesh carries per-vertex.
//
// depth_draw_opaque: blended fragments must not write depth, or a sprite's
// transparent halo punches a hole in everything drawn after it. So the depth
// buffer orders objects against the (opaque) terrain but NOT against each
// other -- object-vs-object order is submission order, and main.gd supplies it
// by emitting one surface per sector, back-to-front, with each object's tiles
// in mixed.pak order.
render_mode unshaded, cull_disabled, blend_mix, depth_draw_opaque;

// A Texture2DArray, one layer per distinct texture.pak page in this sector,
// with UV2.x carrying the layer -- the same trick terrain.gdshader uses. This
// is what lets a whole sector's objects live in ONE surface: batching by
// texture into sibling meshes instead handed ordering to Godot's per-instance
// transparent sort (AABB centroid), which cannot express a painter order.
// filter_NEAREST, deliberately. Object sprites are chopped into 64x64 tiles
// packed 16 to a 256x256 page, and tiles that are adjacent IN THE SPRITE are
// not adjacent in the atlas -- sprite 24471's tile0 and tile1 stack vertically
// on screen but sit side by side in UV. With linear filtering the sampler
// blends across each tile's edge into an unrelated part of the sprite, drawing
// a 1px wrong-content fringe around every tile: the visible rectangular boxes.
//
// Nearest removes it at the root and is what the retail software blitter does
// anyway -- this is a 2D game whose art is authored at final pixel size, so
// there is nothing to interpolate. Terrain solves the same problem differently
// (a 1-texel UV inset) because its diamonds are sampled off-grid.
uniform sampler2DArray tex : filter_nearest;

// Same channel rotation as terrain.gdshader: the texture is uploaded via
// Image.FORMAT_RGBA4444 -> convert(RGBA8), and Godot reads the u16 as R,G,B,A
// where Sacred stores A,R,G,B. So .r is Sacred's ALPHA and .gba are its colour.
//
// This shader exists because StandardMaterial3D cannot express that. Pointing
// albedo_texture at these images makes alpha-scissor test Sacred's *blue*,
// which discards almost every pixel and leaves thin coloured slivers.
//
// No source_color, for the same reason as terrain: it would sRGB-decode RGB but
// not A, and with the rotation that hits the wrong three channels.
varying flat float layer;
// Per-vertex swap bucket id (UV2.y): encodes the region key and the
// exterior/interior class. The swap hides buckets by setting hidden_bucket_count
// and filling hidden_buckets with the ids to discard. This is the shader-side
// discard mechanism (06-04-SUMMARY's Option 3): ONE mesh per band keeps the
// painter-correct contiguous submission order, and the swap is a uniform update
// -- no mesh split, no per-run sorting_offset ambiguity, no geometry rebuild.
varying flat float bucket;
// HIDDEN_BUCKET_SLOTS in view/sector_view.gd MUST equal this array length. The
// CPU side clamps hidden_bucket_count to it; a mismatch, or an unclamped count,
// lets the loop below index past the end of the array.
#define HIDDEN_BUCKET_SLOTS 64
uniform int hidden_bucket_count = 0;
uniform int hidden_buckets[HIDDEN_BUCKET_SLOTS];

void vertex() {
	layer = UV2.x;
	bucket = UV2.y;
}

vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

void fragment() {
	// The swap: discard any fragment whose bucket is hidden. SHARED buckets
	// (id < 0) are never hidden -- props and ground always draw.
	if (bucket >= 0.0) {
		int b = int(bucket + 0.5);
		for (int i = 0; i < hidden_bucket_count; ++i) {
			if (hidden_buckets[i] == b) {
				discard;
			}
		}
	}
	vec4 c = texture(tex, vec3(UV, layer));
	// Sacred's alpha is a real 4-bit gradient, not a mask: shadows, glass and
	// smoke are drawn at partial alpha. An alpha-scissor cut renders those
	// fully opaque, which showed up as flat dark blobs over the buildings --
	// the same sprites composited with real blending in Python looked clean.
	// So blend, and discard only what is fully transparent.
	if (c.r < 0.02) discard;
	ALBEDO = srgb_to_linear(c.gba);
	ALPHA = c.r;
}
