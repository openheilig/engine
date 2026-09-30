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
const SLOT_DX := 104
const SLOT_DY := 25
const SLOT_STAGGER := 52
const ATLAS := 256.0


## Retail's four UVs in mesh order N, E, S, W, not a bounding rectangle.
## LGP 1.0.02 and Win 2.28 ENG initialize the table at cWorld +2096
## with asymmetric tips and a selective 0.002 bias; live floor draws agree.
static func slot_uv(n: int) -> PackedVector2Array:
	var row := n / 2
	var x := float((n % 2) * SLOT_DX + (row % 2) * SLOT_STAGGER)
	var y := float(row * SLOT_DY)
	return PackedVector2Array([
		Vector2((x + 50.0) / ATLAS + 0.002, (y + 0.5) / ATLAS + 0.002),
		Vector2((x + 97.5) / ATLAS + 0.002, (y + 23.5) / ATLAS),
		Vector2((x + 50.0) / ATLAS, (y + 48.0) / ATLAS + 0.002),
		Vector2((x + 2.0) / ATLAS + 0.002, (y + 23.5) / ATLAS + 0.002)])



## texture.pak's two pixel formats. Everything else that appears to be a `kind`
## is a misread offset, not a third format.
const TYPE_ARGB4444 := 4     ## zlib, inflates to w*h*2
const TYPE_RAW32 := 6        ## uncompressed, w*h*4, BGRA byte order


## One raw 32-bit texture. Separate from decode_texture's body because it shares
## none of it: no inflate, no channel expansion, and the size check is against
## the ENTRY rather than an inflated length.
static func _raw32(pak: Pak, id: int, w: int, h: int) -> Image:
	var want := w * h * 4
	var buf := pak.blob(id, 80 + want)
	if buf.size() < 80 + want:
		push_error("Sacred.decode_texture: id %d holds %d bytes, expected %d" % [
			id, buf.size() - 80, want])
		return null
	# Godot has no BGRA8 format, so the swap is done here rather than by asking
	# it for one. In place, on the slice, so this is one pass and no second copy.
	var px := buf.slice(80, 80 + want)
	var i := 0
	while i < want:
		var b := px[i]
		px[i] = px[i + 2]
		px[i + 2] = b
		i += 4
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, px)


static func decode_texture(pak: Pak, id: int, render: bool = false) -> Image:
	var buf := pak.blob(id, 80)
	var w := buf.decode_u16(32)
	var h := buf.decode_u16(34)
	var kind := buf.decode_u8(36)
	# TYPE 6 IS RAW 32-BIT, and it is not compressed at all. 233 of texture.pak's
	# entries carry it, and they are exactly the ones a HUD needs: every
	# GUI_CHAR_*, GUI_HERO_* and GUI_UW_* portrait is type 6, so a decoder that
	# knows only type 4 can draw the whole world and none of the interface.
	#
	# The payload is exactly `w*h*4` bytes from +80 -- GUI_CHAR_01 is 256x256
	# with a 262144-byte payload, FX_HORIZON 1024x128 with 524288 -- where type
	# 4's is a zlib stream inflating to `w*h*2`.
	if kind == TYPE_RAW32:
		return _raw32(pak, id, w, h)
	if kind != TYPE_ARGB4444:
		push_error("Sacred.decode_texture: id %d has unsupported type %d" % [id, kind])
		return null
	# The zlib stream does not sit at one fixed offset: model textures carry a
	# 64-byte name (stream at +80) while the small interface entries carry a
	# 32-byte name (stream at +52 -- GUI_MOVE_ATTACKE measured). Scan the
	# header window for the stream and take the first candidate that inflates
	# to the exact size.
	var want := w * h * 2
	# The +80 read stays FIRST: a header-window scan can hit a false 78 9c
	# pair inside a big stream's own bytes and decode garbage over the whole
	# world (measured: the sector terrain vanished). The scan only runs when
	# +80 fails -- exactly the small-interface-entry case, whose stream sits
	# at +52 (32-byte name; GUI_MOVE_ATTACKE measured).
	var px := Common.inflate(buf.slice(80), want)
	if px.size() != want:
		# Manual byte scan: PackedByteArray.find() on a packed-array needle
		# raises at runtime on this Godot build, which took the whole world
		# down with it.
		var head := buf.slice(32, 80)
		var z := -1
		for i in range(head.size() - 1):
			if head[i] == 0x78 and head[i + 1] == 0x9c:
				z = 32 + i
				break
		if z >= 0:
			px = Common.inflate(buf.slice(z), want)
	if px.size() != want:
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


## --- Model textures -------------------------------------------------------
##
## A creature's skin is NOT an atlas tile: `slot_uv()` and the 18-diamond
## geometry above are terrain-only and answer a different question. A model
## texture is one whole image, named by the .GRN's own Texture nodes
## (Models.texture_names()), and it is stored in texture.pak in exactly the
## same container decode_texture() already reads -- u16 w, u16 h, kind 4,
## zlib payload from +80, RGBA4444. Nothing new is decoded here; what is new
## is FINDING the entry.
##
## THE JOIN IS ON THE STEM, NOT THE FILENAME. The names in a .GRN are the
## artist's authoring paths and their extension does not survive the build:
## `...\animals\wolf\maps\wolf.bmp` is `WOLF.TGA` in the pak, and
## `SORCERESS_BODY.BMP` is `SORCERESS_BODY.TGA`. Matching on the full
## filename silently loses every .bmp.

static var _name_index: Dictionary = {}     ## pak file size -> {STEM: id}

## STEM (upper case, no extension, no directory) -> texture.pak id, built once
## per pak. Keyed on file size so a different install rebuilds rather than
## silently reusing another corpus's index.
static func _stems(pak: Pak) -> Dictionary:
	var key := pak.file_size()
	if _name_index.has(key):
		return _name_index[key]
	var out: Dictionary = {}
	for i in range(pak.count() - 1, -1, -1):
		# Read the name from the entry's own bytes, NOT through blob(i, 0). The
		# index's `size` is the ZLIB PAYLOAD length and the 32-byte name sits
		# before it, so gating on that size drops every small entry:
		# ELVE_SORCERESS_HANDS.TGA declares 15 and is a real 16x16 texture that
		# retail draws on the wood elf's hands. 28 entries are that small, 8 of
		# them referenced 13 times from models.pak.
		var b := pak.read_at(pak.entry_offset(i), 32)
		if b.size() < 32:
			continue
		var nul := b.find(0)
		if nul <= 0:
			continue
		var nm := b.slice(0, nul).get_string_from_ascii().to_upper()
		var dot := nm.rfind(".")
		if dot > 0:
			nm = nm.substr(0, dot)
		# Native inserts headers backwards into a first-match hash: last wins.
		if nm != "" and not out.has(nm):
			out[nm] = i
	_name_index[key] = out
	return out

## texture.pak id for a .GRN texture name, or -1. `name` is taken verbatim
## from Models.texture_names(), backslashes and drive letter included.
static func find_model_texture(pak: Pak, name: String) -> int:
	if name == "":
		return -1
	var s := name.replace("\\", "/")
	var slash := s.rfind("/")
	if slash >= 0:
		s = s.substr(slash + 1)
	var dot := s.rfind(".")
	if dot > 0:
		s = s.substr(0, dot)
	return _stems(pak).get(s.to_upper(), -1)
