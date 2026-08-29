shader_type spatial;
render_mode blend_mix, unshaded, depth_draw_never, depth_test_disabled, cull_disabled, world_vertex_coords;

// The character drop shadow: retail's cGranny::renderShadow (0x80FDBDC,
// decompiled) re-draws the character's OWN posed mesh projected onto the
// ground. The projection compresses the height toward the foot line and
// keeps the silhouette width — the blob climbs the character's legs exactly
// as retail's does. The compression factor and alpha are CALIBRATED through
// the masked hero-box gate (SHADOW_K / SHADOW_ALPHA env during calibration).

uniform float foot_y = 0.0;
uniform float ground_z = 0.0;
uniform float k = 0.25;
uniform float alpha : hint_range(0.0, 1.0) = 0.5;

void vertex() {
	// VERTEX is in world space (world_vertex_coords); world y is up-positive
	// and the foot line sits at foot_y (measured lift + cell y).
	VERTEX.y = foot_y + (VERTEX.y - foot_y) * k;
	VERTEX.z = ground_z;
}

void fragment() {
	ALBEDO = vec3(0.0, 0.0, 0.0);
	ALPHA = alpha;
}
