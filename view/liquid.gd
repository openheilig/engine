extends RefCounted
## The animated liquid materials -- Sacred's water, lava and sulphur surfaces.
##
## WHY THIS EXISTS. Retail draws liquid in its own pass, over the ordinary
## terrain, and the port never had that pass: liquid cells drew their bare
## ground tile and nothing else. On the open sea that ground tile is ISO00 --
## ONE flat 256x256 image, mean colour (0.52, 0.51, 0.43), over all 4096 cells
## of a sector -- which is why the sea read as a grey-tan surface rather than
## water. Walkable.is_liquid already knew which cells those were; only the
## drawing was missing.
##
## THE TABLE IS MEASURED, NOT GUESSED (rows 1008/1011). The 14 materials are
## built by an unrolled initialiser in the retail binary -- sub_83A6572 in the
## Linux build this install pairs with -- as 14 blocks, each storing a count to
## record +0xC8, flag bytes to +0xCC and +0xD4, an alpha multiplier to +0xD0,
## then sprintf-ing "%s%.2d.TGA" per frame into `[0x9118 + k*0xD8 + i*4]`.
## Record order is push order, read off the count stores that bracket every
## block. TWO ADJACENT B_WATER BLOCKS open the sequence -- row 1008's table
## missed the second one and came out shifted; the frame counts pin the truth,
## because the pak's two 20-frame sets (C_LAVA, A_SCHWEFEL) land exactly on
## the records whose +0xC8 says 0x14 only under this order. It also restores
## row 669's original names, wrongly called shifted in between.
##
## Corroboration: the +0xCC flag is 1 for exactly idx 0,1,2,3,10,11 -- the six
## indices row 669 recovered independently from the WINDOWS build, and under
## this order they are all waters bar E_WATER and the last B_WATER, exactly as
## row 669's own parenthetical describes.

const Pak := preload("res://formats/pak.gd")
const LIQUID_SHADER: Shader = preload("res://shaders/liquid.gdshader")

## Per-record fields, from the initialiser described above.
##   stem        the TGA family; B_WATER holds three slots (0, 1, 13), which is
##               also its three xrefs into the function.
##   +0xCC       REFLECTIVE -- gates retail's pass-1 mirrored ambient quad.
##   +0xD0       ALPHA MULTIPLIER, applied to the cell's SIGNED corner bytes
##               (+0x10..13, which on liquid cells hold DEPTH: the open sea is
##               -20, shallows rise to 0) and clamped to 0..255. Negative
##               multiplier times negative depth = opaque water that fades out
##               at the shoreline. -255 means opaque at any depth at all.
##   +0xD4       set on every lava and the schwefel -- "hot", unconsumed here.
const MATERIALS := [
	"B_WATER",     # 0   reflective  alpha -12
	"B_WATER",     # 1   reflective  alpha -12
	"C_WATER",     # 2   reflective  alpha -12
	"D_WATER",     # 3   reflective  alpha -12
	"A_LAVA",      # 4               alpha -255  hot
	"B_LAVA",      # 5               alpha -255  hot
	"C_LAVA",      # 6               alpha -255  hot   (20 frames)
	"A_SCHWEFEL",  # 7               alpha -255  hot   (20 frames)
	"D_LAVA",      # 8               alpha -255  hot
	"E_WATER",     # 9               alpha -255
	"F_WATER",     # 10  reflective  alpha -24
	"G_WATER",     # 11  reflective  alpha -12
	"E_LAVA",      # 12              alpha -255  hot
	"B_WATER",     # 13              alpha -12
]
const ALPHA_MULT := [-12, -12, -12, -12, -255, -255, -255, -255, -255, -255,
	-24, -12, -255, -12]
const REFLECTIVE := [true, true, true, true, false, false, false, false,
	false, false, true, true, false, false]

## Frames are numbered from 00 and run until the next number is absent; the sets
## measured in texture.pak are 50 frames except C_LAVA and A_SCHWEFEL at 20 --
## the same counts the initialiser hardcodes at record +0xC8, which is the
## agreement that pinned the record order. Capped so a pak whose numbering does
## not terminate cannot spin here.
const FRAME_MAX := 64

## Animation cadence, measured from the frame-selection arithmetic in the draw
## (sub_80E3EB2): frame = ((ms >> 1) & 0x3FF) * count / 1024, i.e. the WHOLE
## frame set loops once every 2048 ms whatever its length -- 50 frames run at
## ~24.4 fps, the two 20-frame sets at ~9.8 fps. Not a per-record field; the
## record has no delay, only the count.
const CYCLE_MS := 2048.0

## Liquid images are 128x128 (terrain tiles are 256x256), and the surface tiles
## in SCREEN space -- this is a 2D game, and the quads' own vertex positions are
## already screen pixels, so one texture spans 128 px whatever the cell does.
## Sharing the lattice corners is what makes it seamless across cells.
const TEX_PX := 128.0

var _pak: Pak
var _cache: Dictionary = {}   ## material id -> ShaderMaterial (null when unbuildable)
var _rcache: Dictionary = {}   ## reflection variant, before the liquid surface


func _init(texture_pak: Pak) -> void:
	_pak = texture_pak


## The animated material for liquid id `id`, or null when its frames will not
## load. Cached, including the failure: a material that cannot be built will not
## build on the next sector either, and retrying it per sector would re-decode
## up to 50 images each time.
func material_for(id: int, checkpoint: Callable = Callable()) -> ShaderMaterial:
	if _cache.has(id):
		return _cache[id]
	var mat := await _build(id, checkpoint)
	# Cancellation is not a decode failure. A later sector must be able to
	# request this material again rather than inherit a cached null.
	if checkpoint.is_valid() and not await checkpoint.call():
		return null
	_cache[id] = mat
	return mat


## The reflection variant of a material: an identical ShaderMaterial clone with
## lower priority so it draws BEFORE the liquid surface. Retail draws the
## mirrored ambient quad first and the bed over it (row 1012); the lower
## priority makes the port's transparent queue reproduce that order without a
## second MeshInstance3D. Cached like material_for, including the null failure.
func material_for_reflection(id: int, checkpoint: Callable = Callable()) -> ShaderMaterial:
	if _rcache.has(id):
		return _rcache[id]
	var base := await material_for(id, checkpoint)
	if not _cache.has(id):
		return null
	if base == null:
		_rcache[id] = null
		return null
	var mat := base.duplicate() as ShaderMaterial
	mat.render_priority = -1
	_rcache[id] = mat
	return mat


func _build(id: int, checkpoint: Callable) -> ShaderMaterial:
	if _pak == null or id < 0 or id >= MATERIALS.size():
		return null
	var stem: String = MATERIALS[id]
	var images: Array[Image] = []
	for i in FRAME_MAX:
		if checkpoint.is_valid() and not await checkpoint.call():
			return null
		var tid := Sacred.TextureFormat.find_model_texture(_pak, "%s%02d" % [stem, i])
		if tid < 0:
			break
		# render=false, unlike SectorView._image. The render path uploads
		# FORMAT_RGBA4444 and leaves the channels rotated for the terrain shader
		# to undo, and it also asserts a 256x256 tile size -- which every liquid
		# frame fails, being 128x128. This path returns ordinary RGBA8.
		var img := Sacred.TextureFormat.decode_texture(_pak, tid, false)
		if img == null:
			break
		# A Texture2DArray needs one size and one format for every layer, so a
		# frame that disagrees ends the set rather than failing the whole build.
		if not images.is_empty() and (img.get_width() != images[0].get_width()
				or img.get_height() != images[0].get_height()
				or img.get_format() != images[0].get_format()):
			break
		images.append(img)
	if images.is_empty():
		return null
	var tex := Texture2DArray.new()
	tex.create_from_images(images)
	var mat := ShaderMaterial.new()
	mat.shader = LIQUID_SHADER
	mat.set_shader_parameter(&"frames", tex)
	mat.set_shader_parameter(&"frame_count", float(images.size()))
	mat.set_shader_parameter(&"cycle_ms", CYCLE_MS)
	return mat


## The liquid material id for one sector, straight from the file (row 1010).
##
## Retail's consumer (sub_80E3EB2) reads sector->[0x17C]+0xF7 for nibble-9
## cells and +0xF8 for nibble-10 cells. The block at [0x17C] turned out to be
## a 0x100-byte slice of the sector's own keyx RECORD -- bytes 0x1E9..0x2E8,
## memcpy'd out by the 768-byte-record loader sub_80EF4EE -- so the two ids
## are keyx record bytes 736 and 737, which World.liquid_id reads. Measured
## over all 1360 liquid sectors before being wired: every value is in 0..13,
## the sea reads B_WATER, the underworld reads lava, and 22 sectors carry two
## DIFFERENT liquids at once, which is why the format keeps two bytes.
func material_id(world: Sacred.World, gx: int, gy: int, nibble: int) -> int:
	if world == null:
		return 0
	var id := world.liquid_id(gx, gy, nibble)
	# A malformed id falls back to B_WATER rather than to nothing: retail data
	# never exceeds the table, so this path is for a modded or truncated keyx,
	# where flat water beats a hole in the world.
	return id if id >= 0 and id < MATERIALS.size() else 0
