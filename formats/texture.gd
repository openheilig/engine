extends RefCounted
## Terrain texture decode: the 18-diamond atlas geometry and ARGB4444.

const Pak := preload("res://formats/pak.gd")

const Common := preload("res://formats/common.gd")

## Terrain textures are not one tile each -- every 256x256 image is an ATLAS of
## 18 iso diamonds, and `tiles.pak +0x24` (0..17) selects which one. Measured
## 2026-08-07 by connected-component labelling of the alpha channel: exactly 18
## components, each exactly 2500 px with a 100x49 bounding box, and the mask is
## byte-identical across every terrain texture sampled. Layout is 9 rows of 2,
## odd rows staggered by half a cell:
##     slot n -> row = n / 2, col = n % 2
##     x0 = col * 104 + (row % 2) * 52,   y0 = row * 25
## Slot 17 ends at (255, 248), so all 18 fit with no wrap.
const SLOT_COUNT := 18
const SLOT_W := 100      ## measured opaque diamond width  (stride is 104)
const SLOT_H := 49       ## measured opaque diamond height (row step is 25, so 50)
const SLOT_DX := 104
const SLOT_DY := 25
const SLOT_STAGGER := 52
const ATLAS := 256.0
## Half-texel shrink of the sampled rect. Without it, linear filtering at the
## diamond's tips reaches into the 4 px of padding between slots and draws a
## faint dark grid over the whole world.
const SLOT_INSET := 1.0


## Normalised UV rect of atlas slot n, covering the slot's *opaque* diamond
## bounding box (not the 104x50 lattice cell) and inset to keep the filter off
## the padding. The diamond's four tips are this rect's edge midpoints.
static func slot_uv(n: int) -> Rect2:
	var row := n / 2
	var col := n % 2
	return Rect2(
		(col * SLOT_DX + (row % 2) * SLOT_STAGGER + SLOT_INSET) / ATLAS,
		(row * SLOT_DY + SLOT_INSET) / ATLAS,
		(SLOT_W - 2 * SLOT_INSET) / ATLAS,
		(SLOT_H - 2 * SLOT_INSET) / ATLAS)



static func decode_texture(pak: Pak, id: int, render: bool = false) -> Image:
	var buf := pak.blob(id, 80)
	var w := buf.decode_u16(32)
	var h := buf.decode_u16(34)
	var kind := buf.decode_u8(36)
	if kind != 4:
		push_error("Sacred.decode_texture: id %d has unsupported type %d" % [id, kind])
		return null
	var px := Common.inflate(buf.slice(80), w * h * 2)
	if px.size() != w * h * 2:
		push_error("Sacred.decode_texture: id %d inflated to %d, expected %d" % [id, px.size(), w * h * 2])
		return null
	if render:
		var img := Image.create_from_data(w, h, false, Image.FORMAT_RGBA4444, px)
		img.convert(Image.FORMAT_RGBA8)
		# ponytail: NO mipmaps -- see terrain.gdshader. Atlas slots are only 4 px
		# apart, so mip level 2 already averages across into the next diamond.
		return img
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, _argb4444_to_rgba8(px, w * h))


## Two 512-byte lookup tables turn each source byte into its two expanded
## channels, so the hot loop does table reads instead of shifts and multiplies.
static var _hi := PackedByteArray()   ## (a<<4)|r  ->  r, a
static var _lo := PackedByteArray()   ## (g<<4)|b  ->  g, b


static func _argb4444_to_rgba8(px: PackedByteArray, n: int) -> PackedByteArray:
	if _hi.is_empty():
		_hi.resize(512)
		_lo.resize(512)
		for b in 256:
			_hi[b * 2] = (b & 0xF) * 17          # r
			_hi[b * 2 + 1] = (b >> 4) * 17       # a
			_lo[b * 2] = (b >> 4) * 17           # g
			_lo[b * 2 + 1] = (b & 0xF) * 17      # b
	var out := PackedByteArray()
	out.resize(n * 4)
	for i in n:
		var lo := _lo[px[i * 2] * 2]
		var hi := px[i * 2 + 1] * 2
		var o := i * 4
		out[o] = _hi[hi]
		out[o + 1] = lo
		out[o + 2] = _lo[px[i * 2] * 2 + 1]
		out[o + 3] = _hi[hi + 1]
	return out
