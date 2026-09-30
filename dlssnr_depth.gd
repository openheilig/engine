extends Node
## Experimental DLSS5 depth feed (--dlssnr-depth). Never loaded without the flag.
##
## Renders the live world a second time into a hidden SubViewport that shares
## the main world_3d, draws a full-screen quad that copies that viewport's own
## hardware depth into its COLOR target (24-bit fixed point packed across RGB,
## inverted: 1.0 = near, 0.0 = far, matching the helper's DLSSNR.DepthInverted
## = 1 contract), and writes the result to a sidecar file the forked dlssnr
## helper polls. The stock helper ignores the file; the stock port never runs
## this script. One frame of latency: the readback in _process returns the
## frame rendered last pass, which is exactly the previous-frame data the
## model consumes anyway.
##
## Sidecar layout (all little-endian): "DPTH", u32 width, u32 height,
## u32 format (0 = RGB8 packed-24), u64 seq, then width*height*4 bytes RGBA8.
## See fork notes: tmp/DLSS5VKLayer in the analysis workspace.

const SIDEcar_DIR := "/tmp/dlssnr-1000"
const OUT_PATH := SIDEcar_DIR + "/depth.bin"
const MAGIC := 0x48545044  # "DPTH"

const SHADER := "
shader_type spatial;
render_mode unshaded, depth_draw_never, depth_test_disabled, cull_disabled,
		blend_mix, shadows_disabled;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
precision highp float;

void fragment() {
	highp float d = texture(depth_tex, SCREEN_UV).r;
	// Encoding sweep (DLSSNR_DEPTH_MODE, chosen empirically -- the model's
	// exact depth convention is undocumented):
	// 0 raw hardware depth, 1 inverted, 2 remapped to [0.5,1.0],
	// 3 inverted remapped to [0.5,1.0]
	highp int mode = 0;  // patched by the exporter below
	highp float v = d;
	// PLACEHOLDER_MODE
	highp float f = floor(v * 16777215.0 + 0.5);  // 24-bit fixed point
	highp float r = floor(f / 65536.0);
	highp float g = floor(mod(f, 65536.0) / 256.0);
	highp float b = mod(f, 256.0);
	ALBEDO = vec3(r, g, b) / 255.0;
	ALPHA = 1.0;
}
"

var _cam: Camera3D
var _vp: SubViewport
var _sub_cam: Camera3D
var _quad: MeshInstance3D
var _file: FileAccess
var _seq: int = 0
var _frames: int = 0
var _warned: int = 0


func _init(camera: Camera3D) -> void:
	_cam = camera
	process_priority = 100  # after IsoCamera's own _process movement


func _ready() -> void:
	var main_vp := _cam.get_viewport()
	_vp = SubViewport.new()
	_vp.size = main_vp.size
	_vp.own_world_3d = false
	_vp.world_3d = main_vp.world_3d
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)

	_sub_cam = Camera3D.new()
	_sub_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_vp.add_child(_sub_cam)
	_sub_cam.make_current()

	var mat := ShaderMaterial.new()
	var sh := Shader.new()
	var mode := int(OS.get_environment("DLSSNR_DEPTH_MODE")) if OS.get_environment("DLSSNR_DEPTH_MODE") != "" else 0
	var encode := "v = d;" if mode == 0 \
		else "v = 1.0 - d;" if mode == 1 \
		else "v = mix(0.5, 1.0, d);" if mode == 2 \
		else "v = mix(1.0, 0.5, d);" if mode == 3 \
		else "v = vec3(0.9).r;"
	sh.code = SHADER.replace("// PLACEHOLDER_MODE", encode)
	mat.shader = sh
	_quad = MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.orientation = PlaneMesh.FACE_Z
	mesh.material = mat
	_quad.mesh = mesh
	_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_quad.position = Vector3(0, 0, -1)
	_sub_cam.add_child(_quad)

	DirAccess.make_dir_recursive_absolute(SIDEcar_DIR)
	_file = FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if _file == null:
		push_error("dlssnr_depth: cannot open %s (%s) -- feed disabled"
			% [OUT_PATH, error_string(FileAccess.get_open_error())])
		set_process(false)


func _process(_delta: float) -> void:
	if _file == null:
		return
	var vp := _cam.get_viewport()
	if vp == null:
		return
	# Mirror the main camera exactly; the depth must line up with the frame
	# the layer presented, pixel for pixel.
	_sub_cam.global_transform = _cam.global_transform
	_sub_cam.near = _cam.near
	_sub_cam.far = _cam.far
	_sub_cam.size = _cam.size
	if _vp.size != vp.size:
		_vp.size = vp.size
	var aspect := float(vp.size.x) / float(max(vp.size.y, 1))
	var qmesh := _quad.mesh as QuadMesh
	qmesh.size = Vector2(_cam.size * aspect, _cam.size)

	# Read back the PREVIOUS frame's render (this frame has not rendered yet),
	# which is the temporal neighbour the model wants anyway.
	var img := _vp.get_texture().get_image()
	_frames += 1
	if OS.get_environment("DLSSNR_DEPTH_DEBUG") != "" and _frames == 10:
		img.save_png("/tmp/look/depth-quad.png")
	if img == null or img.is_empty():
		if _warned < 3:
			_warned += 1
			push_warning("dlssnr_depth: empty readback")
		return
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)

	_seq += 1
	_file.seek(0)
	_file.store_32(MAGIC)
	_file.store_32(vp.size.x)
	_file.store_32(vp.size.y)
	_file.store_32(0)  # fmt 0 = RGB8 packed-24
	_file.store_64(_seq)
	_file.store_buffer(img.get_data())
	# Commit marker: the helper re-reads seq after the pixels and discards the
	# frame if it moved, so a partial write is never uploaded as depth.
	_file.seek(16)
	_file.store_64(_seq)
	_file.flush()
