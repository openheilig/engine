shader_type canvas_item;
render_mode unshaded, blend_premul_alpha;

// The model viewport has already applied Forward+'s output transfer. Keep
// encoded RGB here: FloorDisplay decodes the completed scene exactly once.
uniform sampler2D image : filter_nearest, repeat_disable;

void fragment() {
	COLOR = texture(image, UV);
}
