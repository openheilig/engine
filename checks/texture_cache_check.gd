extends "res://checks/check.gd"
## Cache invalidation exercises real archive bytes, decoding, and disk cache
## reads. Same-path/same-size source replacement must change the visible
## pixels; a malformed cached tile must not replace a valid source tile.
const TILE := 256
const MAGIC := 0x49545831
var _cache_dirs: Dictionary = {}

func _init() -> void:
	super()
	var path := "user://_texture_cache_test/texture.pak"
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	_write_texture(path, Color.RED)
	var first := _load_tile(path)
	expect(first != null and first.get_pixel(100, 100).is_equal_approx(Color.RED),
		"fresh archive must decode the red source tile")
	var warm := _load_tile(path)
	expect(warm != null and warm.get_pixel(100, 100).is_equal_approx(Color.RED),
		"disk-cached tile must retain source pixels")

	_write_texture(path, Color.GREEN)
	var replaced := _load_tile(path)
	expect(replaced != null and replaced.get_pixel(100, 100).is_equal_approx(Color.GREEN),
		"replacing an archive at the same path must invalidate its old tile")

	# Cache files are derived and disposable. A valid-looking but wrong-size
	# tile must fall back to the source, not leak through the cache-hit path.
	for dir: String in _cache_dirs:
		var directory := DirAccess.open(dir)
		if directory == null:
			continue
		for file in directory.get_files():
			if not file.ends_with(".itx"):
				continue
			var f := FileAccess.open(dir.path_join(file), FileAccess.WRITE)
			f.store_32(MAGIC)
			f.store_32(32)
			f.store_32(32)
			var pixels := PackedByteArray()
			pixels.resize(32 * 32 * 4)
			pixels.fill(255)
			f.store_buffer(pixels)
			f.close()
	var recovered := _load_tile(path)
	expect(recovered != null and recovered.get_width() == TILE
		and recovered.get_pixel(100, 100).is_equal_approx(Color.GREEN),
		"wrong-sized disk cache must recover the green source tile")

	for dir: String in _cache_dirs:
		var directory := DirAccess.open(dir)
		if directory != null:
			for file in directory.get_files():
				DirAccess.remove_absolute(dir.path_join(file))
	DirAccess.remove_absolute(path)
	print("texture_cache_check OK")
	finish(0)

func _load_tile(path: String) -> Image:
	var view = load("res://view/sector_view.gd").new()
	view._tex_pak = Sacred.Pak.new(path)
	view._tex_pak_path = path
	var image: Image = view._image(1)
	_cache_dirs[String(view._tex_cache_dir)] = true
	view.free()
	return image

func _write_texture(path: String, color: Color) -> void:
	# Synthetic TEX archive: sentinel entry + a 256x256 raw BGRA tile.
	var payload := TILE * TILE * 4
	var data := PackedByteArray()
	data.resize(280 + 80 + payload)
	data[0] = 84
	data[1] = 69
	data[2] = 88
	data[3] = 3
	data.encode_u32(4, 2)
	data.encode_u32(272, 280)
	data.encode_u32(276, payload)
	data.encode_u16(280 + 32, TILE)
	data.encode_u16(280 + 34, TILE)
	data[280 + 36] = 6
	for offset in range(360, data.size(), 4):
		data[offset] = int(color.b * 255)
		data[offset + 1] = int(color.g * 255)
		data[offset + 2] = int(color.r * 255)
		data[offset + 3] = 255
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(data)
	f.close()
