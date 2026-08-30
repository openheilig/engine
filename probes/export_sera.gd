extends SceneTree
## Exports the SERAPHIM mesh + textures for Bevy in a renderer-independent
## format: mesh_arrays JSON + decoded texture PNGs. Pure data, no Node3D.

func group_max(arr: PackedInt32Array) -> int:
	var m := -1
	for v in arr:
		if v > m: m = v
	return m + 1 if m >= 0 else 1

func _init() -> void:
	var install: String = Sacred.find_install()
	var out_dir := "/home/rlinev/Projects/openheilig/bevy-port/assets"
	DirAccess.make_dir_recursive_absolute(out_dir + "/models")
	DirAccess.make_dir_recursive_absolute(out_dir + "/textures")

	var pak := Sacred.Pak.new(install.path_join("pak/models.pak"))
	var models := Sacred.Models.new(pak)
	var e := models.index_of("SERAPHIM.GRN")
	if e < 0:
		push_error("SERAPHIM.GRN not found")
		quit(1)
		return

	# --- MESH DATA ---
	var arrays: Dictionary = models.mesh_arrays(e)
	if arrays.is_empty():
		push_error("mesh_arrays empty")
		quit(1)
		return

	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var vertex_mesh: PackedInt32Array = arrays.get("vertex_mesh", PackedInt32Array())

	var mesh_data := {
		"vertex_count": verts.size(),
		"index_count": indices.size(),
		"group_count": group_max(vertex_mesh),
		"positions": [],
		"normals": [],
		"uvs": [],
		"indices": [],
		"group_ids": [],
	}
	for v in verts:
		mesh_data["positions"].append([v.x, v.y, v.z])
	for n in norms:
		mesh_data["normals"].append([n.x, n.y, n.z])
	for uv in uvs:
		mesh_data["uvs"].append([uv.x, uv.y])
	for idx in indices:
		mesh_data["indices"].append(idx)
	for gm in vertex_mesh:
		mesh_data["group_ids"].append(gm)

	var mf := FileAccess.open(out_dir + "/models/seraphim_mesh.json", FileAccess.WRITE)
	mf.store_string(JSON.stringify(mesh_data))
	mf.close()
	print("export: mesh %d verts %d indices %d groups" % [verts.size(), indices.size(),
		mesh_data["group_count"]])

	# --- TEXTURE NAMES + PERMUTATION ---
	var names: PackedStringArray = models.texture_names(e)
	var perm: Array = models.material_textures(e)
	var tex_info := {
		"names": [],
		"permutation": perm,
	}
	for n in names:
		tex_info["names"].append(n.get_file())

	var tf := FileAccess.open(out_dir + "/models/seraphim_textures.json", FileAccess.WRITE)
	tf.store_string(JSON.stringify(tex_info))
	tf.close()
	print("export: %d texture names, permutation %s" % [names.size(), str(perm)])

	# --- TEXTURES AS PNGS ---
	var tpak := Sacred.Pak.new(install.path_join("pak/texture.pak"))
	for i in names.size():
		var tex_name: String = names[i].get_file()
		var stem: String = tex_name.get_basename()
		var tid: int = Sacred.TextureFormat.find_model_texture(tpak, tex_name)
		if tid < 0:
			print("export: texture %d '%s' NOT FOUND" % [i, tex_name])
			continue
		var img: Image = Sacred.TextureFormat.decode_texture(tpak, tid)
		if img == null:
			print("export: texture %d '%s' DECODE FAILED" % [i, tex_name])
			continue
		var png_path := out_dir + "/textures/" + stem + ".png"
		img.save_png(png_path)
		print("export: texture %d '%s' -> %s (%dx%d)" % [i, tex_name, stem, img.get_width(), img.get_height()])

	print("export: DONE")
	quit()
