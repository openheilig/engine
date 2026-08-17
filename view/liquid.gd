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
## THE TABLE IS MEASURED, NOT GUESSED (row 1008). The 14 materials are built by
## an unrolled initialiser in the retail binary -- sub_83A6572 in the Linux
## build this install pairs with -- as 14 blocks 0x63 bytes apart, each one
## sprintf-ing a "%s%.2d.TGA" format string and storing the decoded frames to
## `[edi + esi*4 + 0x9118 + k*0xD8]`. Block 0 stores at 0x9118 and block 13 at
## 0x9C10, and 0x9C10 - 0x9118 = 0xAF8 = 13 * 0xD8 exactly, so block order IS
## record order and the names below are read straight off that sequence.
##
## Corroboration: each block also writes two flag bytes, at record +0xCC and
## +0xD4. The +0xCC flag comes out 1 for exactly idx 0,1,2,3,10,11 -- the same
## six indices row 669 recovered independently from the WINDOWS build. Two
## separately-compiled binaries agreeing on the record order is what makes this
## a reading rather than an inference. (Row 669's NAMES are shifted one slot
## against this; its flag indices are right. Trust the indices.)
##
## ponytail: the +0xCC flag is not acted on here. Row 669 reads it as "this
## liquid is reflective" and gates a mirrored grey pass on it, but that pass is
## a second surface with its own geometry, and the first thing to fix is that
## water is not drawn at all.

const Pak := preload("res://formats/pak.gd")
const LIQUID_SHADER: Shader = preload("res://shaders/liquid.gdshader")

## Record k's TGA stem, from the initialiser described above. B_WATER appears at
## three indices, which is why texture.pak carries 12 liquid image sets for 14
## records -- and it is also the only string with three xrefs into that
## function, so the repeat is confirmed from the other side too.
const MATERIALS := [
	"B_WATER",     # 0
	"C_WATER",     # 1
	"D_WATER",     # 2
	"A_LAVA",      # 3
	"B_LAVA",      # 4
	"C_LAVA",      # 5
	"A_SCHWEFEL",  # 6
	"D_LAVA",      # 7
	"E_WATER",     # 8
	"F_WATER",     # 9
	"G_WATER",     # 10
	"E_LAVA",      # 11
	"B_WATER",     # 12
	"B_WATER",     # 13
]

## Frames are numbered from 00 and run until the next number is absent; the sets
## measured in texture.pak are 50 frames except C_LAVA and A_SCHWEFEL at 20.
## Capped so a pak whose numbering does not terminate cannot spin here.
const FRAME_MAX := 64

## Animation rate. ponytail: NOT measured. The material record has more fields
## than the frame array and the flags -- one of them is very likely a delay --
## but nothing here has traced them, and a still surface reads as more broken
## than a slightly-wrong-speed one. 12 fps runs a 50-frame set in ~4.2 s.
## Measure it against retail before treating this number as parity.
const FPS := 12.0

## Liquid images are 128x128 (terrain tiles are 256x256), and the surface tiles
## in SCREEN space -- this is a 2D game, and the quads' own vertex positions are
## already screen pixels, so one texture spans 128 px whatever the cell does.
## Sharing the lattice corners is what makes it seamless across cells.
const TEX_PX := 128.0

var _pak: Pak
var _cache: Dictionary = {}   ## material id -> ShaderMaterial (null when unbuildable)


func _init(texture_pak: Pak) -> void:
	_pak = texture_pak


## The animated material for liquid id `id`, or null when its frames will not
## load. Cached, including the failure: a material that cannot be built will not
## build on the next sector either, and retrying it per sector would re-decode
## up to 50 images each time.
func material_for(id: int) -> ShaderMaterial:
	if _cache.has(id):
		return _cache[id]
	var mat := _build(id)
	_cache[id] = mat
	return mat


func _build(id: int) -> ShaderMaterial:
	if _pak == null or id < 0 or id >= MATERIALS.size():
		return null
	var stem: String = MATERIALS[id]
	var images: Array[Image] = []
	for i in FRAME_MAX:
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
	mat.set_shader_parameter(&"fps", FPS)
	return mat


## The liquid material id for one sector.
##
## THIS IS THE ONE PIECE STILL UNSOURCED, and it is deliberately isolated here
## rather than smeared through the mesh builder. Retail's consumer is exact and
## was read at sub_80E3EB2:
##
##     mov eax, [edi+17Ch]    ; sector -> a per-sector block
##     mov cl,  [eax+0F7h]    ; id used where cell[0x1F] & 0xF0 == 0x90
##     mov bl,  [eax+0F8h]    ; id used where cell[0x1F] & 0xF0 == 0xA0
##     record = 0x9118 + idx*0xD8
##
## so the id is PER SECTOR, and there are two of them selected by the same
## nibble that marks the cell as liquid at all. What is NOT known is which file
## that block is loaded from. Two candidates were tested against a condition
## stated before looking, and both were refused:
##
##   - sectors.keyx records are 768 bytes and +0xF7/+0xF8 fall in the unclaimed
##     gap between csize and dsize -- but those bytes are 0 in ALL 6050 records,
##     so they carry nothing.
##   - the wldx stream's tail past the 4096-entry grid -- but that tail is the
##     REGION TABLE (formats/regions.gd reads it at the same offset), and read
##     as an id it yields values up to 209, far outside the table's 0..13.
##
## Until the block is found this returns 0. That is not arbitrary: B_WATER holds
## three of the fourteen slots (0, 12 and 13), more than any other material, 0
## is what a zero-initialised field reads as, and the overworld liquid this
## fixes is water. It WILL be wrong on lava, which is confined to specific maps.
## One function, one line, when the source turns up.
func material_id(_gx: int, _gy: int, _nibble: int) -> int:
	return 0
