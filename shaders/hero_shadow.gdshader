shader_type spatial;
render_mode blend_mix, unshaded, depth_draw_never, cull_disabled, world_vertex_coords, fog_disabled;

// LGP 0x080FE8DA / Win 2.28 0x00407960: SHADOWDOT.TGA, five XY quads,
// black diffuse 0x50000000. Captured GL state: linear filtering, repeat,
// SRCALPHA/ONE_MINUS_SRCALPHA, LEQUAL, no depth writes/alpha test/stencil.
// IMPORTANT: Forward+ blends this in LINEAR color, unlike native encoded
// framebuffer blending. This shader deliberately does not fudge alpha to
// conceal that unresolved actor/object compositing difference. Forward+'s
// equal-depth behavior also differs from native LEQUAL.
uniform sampler2D shadow_texture : filter_linear, repeat_enable;
uniform vec3 centers[5];
uniform float half_sizes[5];
uniform mat3 retail_to_port;
uniform vec3 world_origin;
uniform bool root_present;
varying flat int draw_index;

void vertex() {
	draw_index = int(UV2.x);
	VERTEX = world_origin + retail_to_port *
		(centers[draw_index] + VERTEX * half_sizes[draw_index]);
}

void fragment() {
	if (draw_index == 0 && !root_present) {
		discard;
	}
	ALBEDO = vec3(0.0);
	ALPHA = texture(shadow_texture, UV).a * (80.0 / 255.0);
}
