shader_type spatial;
// The floor.pak quads that carry a MASK tile (rows 701/703). Retail draws
// these with two texture units and a fixed-function GL_COMBINE:
//
//   unit 1 (mask)  COMBINE_RGB   = GL_REPLACE, SRC0_RGB   = GL_PREVIOUS
//                  COMBINE_ALPHA = GL_REPLACE, SRC0_ALPHA = GL_TEXTURE
//   unit 0 (art)   ENV_MODE = GL_COMBINE, COMBINE_RGB = GL_MODULATE
//   framebuffer    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
//
// Read off a live apitrace capture at the chapel spawn, not just inferred.
// So: colour is the ART tile modulated by the per-corner light, alpha is the
// MASK tile's texel alpha and nothing else, composited over the ground.
//
// depth_draw_never, because these are decals: they sit a hair in front of the
// ground they blend into and must not occlude anything drawn later. Depth
// TESTING stays on, so the terrain still hides them where it should.
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never;

uniform sampler2DArray tex : filter_linear;

// UV/UV2 carry the art tile's slot UV and array layer. CUSTOM0 carries the
// mask's -- xy its slot UV, z its layer -- because UV2 is already spent.
// CUSTOM0 is vertex-stage only, hence the varying.
varying vec3 mask_uv;

void vertex() {
	mask_uv = CUSTOM0.xyz;
}

vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

void fragment() {
	vec4 a = texture(tex, vec3(UV, UV2.x));
	vec4 m = texture(tex, vec3(mask_uv.xy, mask_uv.z));
	// Both are RGBA4444 uploaded as A,R,G,B and read back rotated, so .r is
	// Sacred's ALPHA and .gba its colour -- the same convention terrain.gdshader
	// documents at length. The mask's ALPHA is therefore m.r, not m.a.
	ALBEDO = srgb_to_linear(a.gba * COLOR.rgb);
	ALPHA = m.r;
}
