shader_type spatial;
render_mode unshaded, cull_front, fog_disabled, depth_draw_always;

// Native scene initialization creates the directional light from (1,-1,-3).
// LGP sub_80E7416 selects ambient by item category; the caller supplies it.
// Material shininess is 30 * 1.28 (sub_8053F3C).
uniform mat3 native_view_normal_from_world;
uniform vec3 light_direction;
uniform vec3 half_vector;
uniform float ambient_value;
uniform sampler2D skin : filter_linear, repeat_enable;
varying vec3 vertex_light;

void vertex() {
	// NORMAL is already skinned. Undo only the synthetic world projection,
	// retaining each body's or socket mesh's own actor transform.
	vec3 normal = normalize(native_view_normal_from_world * MODEL_NORMAL_MATRIX * NORMAL);
	float diffuse = dot(normal, light_direction);
	float specular = diffuse > 0.0
		? pow(max(dot(normal, half_vector), 0.0), 38.4) : 0.0;
	vertex_light = vec3(clamp(ambient_value + max(diffuse, 0.0) + specular, 0.0, 1.0));
}

vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

void fragment() {
	// ModelView requests decode_texture(..., false): ordinary RGBA8.
	// Filter encoded RGB, apply native lighting, then enter Godot's linear space.
	vec4 texel = texture(skin, UV);
	if (texel.a <= 64.0 / 255.0) { discard; }
	ALBEDO = srgb_to_linear(texel.rgb * vertex_light);
	ALPHA = texel.a;
}
