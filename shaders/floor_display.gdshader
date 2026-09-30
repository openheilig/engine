shader_type spatial;
// An opaque, far-plane background. Normal depth writes/testing keep opaque
// objects in front regardless of submission order; the floor itself used no depth.
render_mode unshaded, cull_disabled, fog_disabled;

uniform sampler2D image : filter_nearest, repeat_disable;

vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

void fragment() {
	// The RGBA8 viewport holds the already-composited, encoded retail RGB.
	// Decode exactly once before Forward+ applies its normal output transfer.
	ALBEDO = srgb_to_linear(texture(image, UV).rgb);
}
