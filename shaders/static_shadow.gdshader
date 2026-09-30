shader_type canvas_item;
render_mode unshaded, blend_mix;
// SHADOW_TREE00 uses linear/repeat, unlike the nearest-filtered object atlas.
// Observed on all 125 native start-scene shadow draws. Blend encoded RGB.
uniform sampler2D shadow_tex : filter_linear, repeat_enable;
void fragment() {
	COLOR *= texture(shadow_tex, UV);
}
