extends SceneTree
## Dumps the port's SERAPHIM mesh world-space bbox per axis, in the same
## units the trace strips use (GRN local units through the model basis), so
## the proportion comparison against retail's strips is apples to apples.
func _init() -> void:
	var install: String = Sacred.find_install()
	var pak := Sacred.Pak.new(install.path_join("pak/models.pak"))
	var models := Sacred.Models.new(pak)
	var e := models.index_of("SERAPHIM.GRN")
	var tp := Sacred.Pak.new(install.path_join("pak/texture.pak"))
	var mv := ModelView.new()
	mv.set_texture_pak(tp)
	root.add_child(mv)
	var ok := mv.setup(models, e, false)
	var mi: MeshInstance3D = mv._mesh
	var aabb := mi.get_aabb()
	var out := FileAccess.open("/tmp/sera_dims.txt", FileAccess.WRITE)
	out.store_line("setup=%s aabb pos=%s size=%s" % [str(ok), str(aabb.position), str(aabb.size)])
	out.store_line("x: %.1f..%.1f (%.1f)" % [aabb.position.x, aabb.end.x, aabb.size.x])
	out.store_line("y: %.1f..%.1f (%.1f)" % [aabb.position.y, aabb.end.y, aabb.size.y])
	out.store_line("z: %.1f..%.1f (%.1f)" % [aabb.position.z, aabb.end.z, aabb.size.z])
	# vertices in local space: the ArrayMesh arrays
	var arrays: Array = mv._mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if verts.size() > 0:
		var mn := verts[0]
		var mx := verts[0]
		for v in verts:
			mn = mn.min(v)
			mx = mx.max(v)
		out.store_line("surface0 verts=%d x %.1f..%.1f y %.1f..%.1f z %.1f..%.1f" % [
			verts.size(), mn.x, mx.x, mn.y, mx.y, mn.z, mz_max(mx.z, mn.z)])
	out.close()
	quit()
func mz_max(a: float, b: float) -> float:
	return maxf(a, b)
