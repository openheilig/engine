shader_type canvas_item;
render_mode unshaded, blend_mix;

// A,R,G,B retail bytes: no source_color conversion before encoded-space blending.
uniform sampler2DArray tex : filter_linear, repeat_enable;
uniform int art_layer;
uniform int mask_layer = -1;

// Canvas triangle arrays have no UV2. The input color carries scalar corner
// light in R and the independent mask UV in GB; neither is a display color.
varying float corner_light;
varying vec2 mask_uv;

void vertex() {
	corner_light = COLOR.r;
	mask_uv = COLOR.gb;
}

void fragment() {
	vec4 art = texture(tex, vec3(UV, float(art_layer)));
	float coverage = art.r;
	if (mask_layer >= 0) {
		coverage = texture(tex, vec3(mask_uv, float(mask_layer))).r;
	}
	COLOR = vec4(art.gba * corner_light, coverage);
}
