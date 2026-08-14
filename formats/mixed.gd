extends RefCounted
## pak/mixed.pak -- the sprite table that static.pak's type id indexes.
##
##   header 16 B: u32 tile_count, u16 w, u16 h, i16 dx, i16 dy, u32 pad
##   then tile_count fixed 64-byte tiles; entry size is exactly 16 + 64*n.
##
## Tile: name[32] ("MIX233.444"), u32 texture.pak index @0x20,
##       u16 x1,y1,x0,y0 @0x24 (destination rect in sprite-local pixels),
##       f32 u0,v0,u1,v1 @0x30 (source rect in the texture).
##
## The tiles are NOT animation frames or facings -- they are pieces of ONE
## large sprite, packed across one or more atlases. A 195x341 object is
## assembled from 13 of them. Proof: every tile's destination rect is exactly
## the same size as its UV rect in pixels, and compositing them produces
## coherent objects (a crystal shrine, a boulder, a chair).
##
## 15840 of 32096 entries have zero tiles, including type 1037 -- the most
## common static type in the world. Those placements are invisible markers
## (collision, spawn, sound), not art.

const Pak := preload("res://formats/pak.gd")

var _pak: Pak

func _init(pak: Pak) -> void:
	_pak = pak

func count() -> int:
	return _pak.count()

## {size: Vector2i, anchor: Vector2i, tiles: Array[Dictionary]} or {} if the
## entry has no art. Each tile is {tex: int, src: Rect2, dst: Rect2i}.
func sprite(i: int) -> Dictionary:
	if i <= 0 or i >= _pak.count():
		return {}
	var r := _pak.blob(i)
	if r.size() < 16:
		return {}
	var n := r.decode_u32(0)
	if n <= 0 or r.size() < 16 + n * 64:
		return {}
	var tiles: Array[Dictionary] = []
	for j in n:
		var o := 16 + j * 64
		tiles.append({
			"tex": r.decode_u32(o + 0x20),
			"dst": Rect2i(r.decode_u16(o + 0x28), r.decode_u16(o + 0x2a),
				r.decode_u16(o + 0x24) - r.decode_u16(o + 0x28),
				r.decode_u16(o + 0x26) - r.decode_u16(o + 0x2a)),
			"src": Rect2(r.decode_float(o + 0x30), r.decode_float(o + 0x34),
				r.decode_float(o + 0x38) - r.decode_float(o + 0x30),
				r.decode_float(o + 0x3c) - r.decode_float(o + 0x34)),
		})
	return {
		"size": Vector2i(r.decode_u16(4), r.decode_u16(6)),
		"anchor": Vector2i(r.decode_s16(8), r.decode_s16(10)),
		"tiles": tiles,
	}
