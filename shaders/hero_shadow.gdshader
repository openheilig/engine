shader_type spatial;
render_mode blend_mix, unshaded, depth_draw_never, depth_test_disabled, cull_disabled, world_vertex_coords;

// The character drop shadow: retail draws a second pass of the character's
// own posed mesh squashed into a low band at the foot line (the projected
// silhouette; cGranny::renderShadow 0x80FDBDC decompiled — the exact matrix
// semantics resisted the decompile, so the squash span, foot lift and alpha
// are CALIBRATED against retail's blob through the masked hero-box gate:
// retail blob ~110x35 px under the hero, ~40x18 under the novizin).
//
// foot_y  — world screen-y of the character's feet (measured lift + cell y)
// ground_z — the iso depth the character stands at
// span    — the squashed band height in px

uniform float foot_y = 0.0;
uniform float ground_z = 0.0;
uniform float span = 28.0;
uniform float alpha : hint_range(0.0, 1.0) = 0.5;

void vertex() {
	// VERTEX arrives in world space (world_vertex_coords); world y is
	// up-positive, so the height above the foot line is VERTEX.y - foot_y.
	float h = clamp((VERTEX.y - foot_y) / 140.0, 0.0, 1.0);
	VERTEX.y = foot_y - 8.0 + h * span;
	VERTEX.z = ground_z;
}

void fragment() {
	ALBEDO = vec3(0.0, 0.0, 0.0);
	ALPHA = alpha;
}
