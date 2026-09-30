extends "res://checks/check.gd"
## A forward parent must be copied as it exists NOW, not resolved recursively.
## Later parent writes must not mutate a previously generated child's art.

func _init() -> void:
	super()
	var directory := "user://weapon-inheritance-%d" % OS.get_process_id()
	DirAccess.make_dir_recursive_absolute(directory)
	var names := ["", "A.GRN", "B.GRN", "C.GRN", "D.GRN", "E.GRN", "F.GRN"]
	var data := PackedByteArray()
	data.resize(256 + names.size() * (12 + 128))
	data[0] = 73
	data[1] = 84
	data[2] = 77
	data[3] = 5
	data.encode_u32(4, names.size())
	for i in names.size():
		var offset := 256 + names.size() * 12 + i * 128
		data.encode_u32(256 + i * 12 + 4, offset)
		data.encode_u32(256 + i * 12 + 8, 128)
		data[offset + 46] = 5
		var name_bytes: PackedByteArray = names[i].to_ascii_buffer()
		for j in name_bytes.size():
			data[offset + 55 + j] = name_bytes[j]
	var file := FileAccess.open(directory.path_join("items.pak"), FileAccess.WRITE)
	assert(file != null)
	file.store_buffer(data)
	file.close()
	var links := [Vector2i(3, 2), Vector2i(2, 1), Vector2i(4, 3), Vector2i(5, 2), Vector2i(6, 0)]
	data = PackedByteArray()
	data.resize(256 + links.size() * (258 + 64))
	data[0] = 87
	data[1] = 80
	data[2] = 78
	data[3] = 8
	data.encode_u32(4, links.size())
	for row in links.size():
		data.encode_u32(256 + row * 258 + 128, links[row].x)
		data.encode_u32(256 + row * 258 + 36, links[row].y)
	file = FileAccess.open(directory.path_join("weapon.pak"), FileAccess.WRITE)
	assert(file != null)
	file.store_buffer(data)
	file.close()
	var items := Sacred.Items.new(Sacred.Pak.new(directory.path_join("items.pak")))
	expect(items.name_of(3) == "B.GRN", "forward parent was resolved recursively or mutated retroactively")
	expect(items.name_of(4) == "B.GRN", "later child did not copy its already-generated parent")
	expect(items.name_of(5) == "A.GRN", "later child did not observe the updated parent")
	expect(items.name_of(6) == "F.GRN", "parent zero must retain the original definition")
	DirAccess.remove_absolute(directory.path_join("items.pak"))
	DirAccess.remove_absolute(directory.path_join("weapon.pak"))
	DirAccess.remove_absolute(directory)
	finish()
