shader_type spatial;
// Depth test is ON and each quad carries a Z proportional to its iso depth
// (x + y), so tiles sort correctly *across* sector meshes without any CPU
// painter's sort.
render_mode unshaded, cull_disabled;

// Uploaded via Image.FORMAT_RGBA4444 -> convert(RGBA8), in engine C++. Godot
// reads the u16 high-nibble-first as R,G,B,A while Sacred stores A,R,G,B, so
// every channel arrives rotated by one: .r is Sacred's ALPHA, .gba are its
// red, green, blue.
//
// NO source_color, deliberately. That hint sRGB-decodes RGB *but not A*, and
// with the rotation above that decodes Sacred's red and green while leaving its
// blue raw -- which the framebuffer then re-encodes, brightening blue only.
// Desert tan (210,180,130) came out (210,180,189), a lavender. It reproduced on
// Vulkan/Forward+ and not on the OpenGL3 path, so the transfer function is done
// here instead, where both backends must agree.
uniform sampler2DArray tex : filter_linear;

vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

void fragment() {
	vec4 c = texture(tex, vec3(UV, UV2.x));
	// Low threshold, not 0.5: linear filtering at the diamond tips reaches a
	// little into the padding between atlas slots. The diamond geometry already
	// defines the silhouette, so this only needs to keep genuinely-transparent
	// interior pixels.
	if (c.r < 0.25) discard;
	// COLOR carries the cell's four per-corner light bytes (WldxEntry +0x14..17).
	// Multiplied in GAMMA space, before the decode, because that is what the
	// 2005 engine's 2D blitter did -- it had no linear pipeline.
	ALBEDO = srgb_to_linear(c.gba * COLOR.rgb);
}
