shader_type canvas_item;
// Static sprites share retail's encoded framebuffer and global painter order.
// FloorView submits contiguous runs without reordering them by texture.
render_mode unshaded, blend_mix;

// filter_NEAREST, deliberately. Object sprites are chopped into 64x64 tiles
// packed 16 to a 256x256 page, and tiles that are adjacent IN THE SPRITE are
// not adjacent in the atlas -- sprite 24471's tile0 and tile1 stack vertically
// on screen but sit side by side in UV. With linear filtering the sampler
// blends across each tile's edge into an unrelated part of the sprite, drawing
// a 1px wrong-content fringe around every tile: the visible rectangular boxes.
//
// A live native GL observation confirms NEAREST minification/magnification
// for both chapel cobble miniatures (finding 1236), independently of the
// earlier MIX fringe comparison. That observation does not establish every
// object texture's sampler state; terrain has its own sampling path.
uniform sampler2DArray tex : filter_nearest;

// The packed upload retains Sacred A,R,G,B in Godot R,G,B,A.
// Do not sRGB-decode before blending: the display shader decodes once, last.
uniform int layer;

void vertex() {
	// Miniature metadata: COLOR stores
	// columns, rows, timing divisor, frame count as normalized retail bytes.
	// Zero columns marks regular MIX/static-UV geometry, not an animation.
	ivec4 animation = ivec4(round(COLOR * 255.0));
	if (animation.x > 0) {
		// Native uses integer milliseconds from its performance-counter epoch:
		// tick = (4*ms / (columns*divisor)) % 1000
		// frame = frame_count*tick / 1000, then row-major atlas addressing.
		// TIME follows the existing liquid convention; its epoch, pause policy
		// and rollover are not synchronized with retail's counter.
		uint ms = uint(floor(TIME * 1000.0));
		uint tick = (4u * ms / uint(animation.x * animation.z)) % 1000u;
		int frame = int(uint(animation.w) * tick / 1000u);
		UV += vec2(float(frame % animation.x) / float(animation.x),
			float(frame / animation.x) / float(animation.y));
	}
}

void fragment() {
	vec4 c = texture(tex, vec3(UV, float(layer)));
	COLOR = vec4(c.gba, c.r);
}
