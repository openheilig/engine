extends "res://checks/check.gd"
## Synthetic format-contract regressions; no retail payloads or IDs.
const Pak := preload("res://formats/pak.gd")
const TextureFormat := preload("res://formats/texture.gd")

func _init() -> void:
	super()
	var root := ProjectSettings.globalize_path("user://_pak_extents_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(root)
	var tex_path := root.path_join("texture.pak")
	var bytes := PackedByteArray()
	bytes.resize(860)
	bytes[0] = 84
	bytes[1] = 69
	bytes[2] = 88
	bytes[3] = 3
	bytes.encode_u32(4, 4)
	# Reordered index, sparse padding and duplicate aliases. The final two
	# compressed textures declare inflated8192, well beyond remaining bytes.
	bytes = _index(bytes, 0, 500, 4)
	bytes = _index(bytes, 1, 304, 8192)
	bytes = _index(bytes, 2, 740, 8192)
	bytes = _index(bytes, 3, 500, 4)
	bytes = _tex_header(bytes, 500, 1, 1, 6)
	bytes[580] = 0
	bytes[581] = 0
	bytes[582] = 255
	bytes[583] = 255
	var pixels := PackedByteArray()
	pixels.resize(8192)
	pixels.fill(255)
	var compressed := pixels.compress(FileAccess.COMPRESSION_DEFLATE)
	if not expect(compressed.size() <= 40, "synthetic constant texture fits its authored physical tail"):
		DirAccess.remove_absolute(root)
		finish(1)
		return
	for offset: int in [304, 740]:
		bytes = _tex_header(bytes, offset, 64, 64, 4)
		for i in compressed.size():
			bytes[offset + 80 + i] = compressed[i]
	_write(tex_path, bytes)
	expect(Pak.validate_archive(tex_path) == "", "TEX inflated metadata is not rejected as physical byte length")
	var tex := Pak.new(tex_path)
	if expect(tex.is_open(), "compressed-tail TEX archive opens"):
		expect(tex.physical_size(0) == 240 and tex.physical_size(1) == 196 and tex.physical_size(2) == 120 and tex.physical_size(3) == 240,
			"physical spans follow sorted distinct offsets, not record order or aliases")
		expect(tex.blob(1, 80).size() == 196 and tex.blob(2, 80).size() == 120,
			"TEX reads stop at next physical entry/EOF despite inflated metadata")
		expect(tex.blob(0, 80).size() == 240 and tex.blob(3, 80) == tex.blob(0, 80),
			"raw texture and aliased entry use their bounded physical bytes")
		var image := TextureFormat.decode_texture(tex, 2)
		expect(image != null and image.get_width() == 64 and image.get_pixel(0, 0) == Color.WHITE,
			"legal compressed tail actually decodes, not just passes header validation")
		image = TextureFormat.decode_texture(tex, 0)
		expect(image != null and image.get_pixel(0, 0) == Color.RED,
			"raw TEX pixels retain their header and complete physical payload")

	var ascending := bytes.duplicate()
	ascending = _index(ascending, 0, 304, 8192)
	ascending = _index(ascending, 1, 500, 4)
	ascending = _index(ascending, 2, 740, 8192)
	ascending = _index(ascending, 3, 0, 0)
	var ascending_path := root.path_join("ascending.pak")
	_write(ascending_path, ascending)
	var ordered := Pak.new(ascending_path)
	if expect(ordered.is_open(), "ascending TEX with empty sentinel opens"):
		expect(ordered.physical_size(0) == 196 and ordered.physical_size(1) == 240
			and ordered.physical_size(2) == 120 and ordered.blob(3, 80).is_empty(),
			"ascending fast path matches real extents and empty slots borrow no header bytes")

	# Existing MDL kind64 mesh metadata is not a disk length either; motion
	# kind65 retains true declared-byte bounds (formats/models.gd contract).
	var model_bytes := bytes.duplicate()
	model_bytes[0] = 77
	model_bytes[1] = 68
	model_bytes[2] = 76
	for i in 4:
		model_bytes.encode_u32(256 + i * 12, 64)
	var model_path := root.path_join("model.pak")
	_write(model_path, model_bytes)
	expect(Pak.validate_archive(model_path) == "", "MDL mesh metadata may exceed physical entry bytes")
	var model := Pak.new(model_path)
	expect(model.is_open() and model.blob(2).size() == 120,
		"MDL mesh blob remains confined to its actual tail extent")
	model_bytes.encode_u32(256 + 2 * 12, 65)
	_write(model_path, model_bytes)
	expect(Pak.validate_archive(model_path) != "", "MDL motion declared bytes cannot exceed physical entry")

	# Ordinary declared byte lengths remain real bounds, including entries
	# crossing another entry while still inside the overall file.
	bytes[0] = 73
	bytes[1] = 84
	bytes[2] = 77
	bytes[3] = 5
	bytes = _index(bytes, 0, 500, 241)
	bytes = _index(bytes, 1, 304, 196)
	bytes = _index(bytes, 2, 740, 120)
	bytes = _index(bytes, 3, 500, 240)
	var ordinary_path := root.path_join("ordinary.pak")
	_write(ordinary_path, bytes)
	expect(Pak.validate_archive(ordinary_path) != "", "ITM declared bytes cannot cross into the next physical entry")
	bytes = _index(bytes, 0, 500, 240)
	_write(ordinary_path, bytes)
	expect(Pak.validate_archive(ordinary_path) == "", "valid reordered ordinary extents are admitted")
	bytes = _index(bytes, 2, 740, 121)
	_write(ordinary_path, bytes)
	expect(Pak.validate_archive(ordinary_path) != "", "ordinary physical EOF overrun is refused")
	bytes[0] = 84
	bytes[1] = 69
	bytes[2] = 88
	bytes[3] = 3
	bytes = _index(bytes, 2, 861, 8192)
	_write(tex_path, bytes)
	expect(Pak.validate_archive(tex_path) != "", "TEX cannot use out-of-file offsets even when declared sizes are metadata")
	bytes = _index(bytes, 2, 280, 8192)
	_write(tex_path, bytes)
	expect(Pak.validate_archive(tex_path) != "", "TEX cannot overlap its own index")
	tex = null
	ordered = null
	model = null
	DirAccess.remove_absolute(tex_path)
	DirAccess.remove_absolute(ordinary_path)
	DirAccess.remove_absolute(ascending_path)
	DirAccess.remove_absolute(model_path)
	DirAccess.remove_absolute(root)
	print("pak_extent_check\tOK")
	finish()

func _index(bytes: PackedByteArray, id: int, offset: int, size: int) -> PackedByteArray:
	bytes.encode_u32(256 + id * 12, 0)
	bytes.encode_u32(260 + id * 12, offset)
	bytes.encode_u32(264 + id * 12, size)
	return bytes

func _tex_header(bytes: PackedByteArray, offset: int, width: int, height: int, kind: int) -> PackedByteArray:
	bytes.encode_u16(offset + 32, width)
	bytes.encode_u16(offset + 34, height)
	bytes[offset + 36] = kind
	bytes.encode_u32(offset + 40, width * height * (4 if kind == 6 else 2))
	return bytes

func _write(path: String, bytes: PackedByteArray) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()
