shader_type canvas_item;
render_mode unshaded, blend_mix;

// Native SHADOWDOT: black 0x50000000, linear sampling and encoded blending.
uniform sampler2D shadow_texture : filter_linear, repeat_enable;

void fragment() {
	COLOR = vec4(0.0, 0.0, 0.0, texture(shadow_texture, UV).a * (80.0 / 255.0));
}
