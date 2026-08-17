shader_type spatial;
// Same posture as terrain.gdshader: depth test on, each quad carrying a Z
// proportional to its iso depth, so liquid sorts against terrain and against
// other sectors' liquid without a CPU sort.
render_mode unshaded, cull_disabled;

// One layer per animation frame -- 50 for most liquids, 20 for C_LAVA and
// A_SCHWEFEL. repeat_enable because the surface tiles in screen space: the UVs
// are the quad's own pixel coordinates over 128, and cells share lattice
// corners, so the water runs continuously across a sector instead of restarting
// per cell.
uniform sampler2DArray frames : filter_linear, repeat_enable;
uniform float frame_count = 1.0;
// The whole frame set loops once per cycle regardless of length -- retail's
// frame pick is ((ms >> 1) & 0x3FF) * count / 1024, i.e. a fixed 2048 ms
// cycle (row 1011). 50-frame sets run at ~24.4 fps, 20-frame ones at ~9.8.
uniform float cycle_ms = 2048.0;

// NOT the channel rotation terrain.gdshader has to undo. That one exists
// because SectorView._image uploads FORMAT_RGBA4444 and lets the shader sort
// the channels out; liquid frames are decoded to ordinary RGBA8 on the CPU
// (Liquid._build, render=false), so .rgb is already red, green, blue.
vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

void fragment() {
	// fract before floor, so the frame index cannot drift out of range however
	// long TIME has been running.
	float f = floor(fract(TIME * 1000.0 / cycle_ms) * frame_count);
	vec4 c = texture(frames, vec3(UV, f));
	// COLOR carries the cell's four per-corner light bytes, multiplied in gamma
	// space before the decode -- the same order terrain.gdshader uses, because
	// the 2005 engine had no linear pipeline and did this in its 2D blitter.
	ALBEDO = srgb_to_linear(c.rgb * COLOR.rgb);
	// COLOR.a is retail's depth fade (row 1011): the per-record alpha
	// multiplier times the cell's signed corner DEPTH byte, clamped -- opaque
	// over deep water, clear at the shoreline. Writing ALPHA moves the surface
	// to the transparent queue, which draws after the opaque bed it covers.
	ALPHA = c.a * COLOR.a;
}
