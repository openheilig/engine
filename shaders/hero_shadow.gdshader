shader_type spatial;
render_mode blend_mix, unshaded, depth_draw_never, depth_test_disabled, cull_disabled, world_vertex_coords;

// The character drop shadow: retail's cGranny::renderShadow (0x80FDBDC,
// decompiled) re-draws the character's OWN posed mesh projected onto the
// ground. The projection compresses the height toward the foot line, stretches
// the silhouette laterally about the character's axis (retail's measured blob
// is ~105 px wide -- WIDER than the body, so a pure squash reads too narrow;
// the stretch is CALIBRATED through the masked hero-box gate, SHADOW_STRETCH
// env during calibration), and flattens to the ground depth. The compression
// factor, stretch and alpha are CALIBRATED (SHADOW_K / SHADOW_ALPHA /
// SHADOW_STRETCH env).

uniform float foot_x = 0.0;
uniform float foot_y = 0.0;
uniform float ground_z = 0.0;
uniform float k = 0.25;
uniform float stretch = 1.0;
uniform float alpha : hint_range(0.0, 1.0) = 0.5;

void vertex() {
	// VERTEX is in world space (world_vertex_coords); world y is up-positive
	// and the foot line sits at foot_y (measured lift + cell y).
	VERTEX.y = foot_y + (VERTEX.y - foot_y) * k;
	VERTEX.x = foot_x + (VERTEX.x - foot_x) * stretch;
	VERTEX.z = ground_z;
}

void fragment() {
	ALBEDO = vec3(0.0, 0.0, 0.0);
	ALPHA = alpha;
}
