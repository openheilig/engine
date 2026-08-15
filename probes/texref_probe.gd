extends SceneTree
## What each Texture node names, and what each Material points at.
##
##   godot --headless --path . --script res://probes/texref_probe.gd -- NAME
##
## Written because GLADIATOR.GRN carries ten .tga path strings, declares six
## Texture nodes and six Materials, and the port resolved four of the six
## materials to the SAME image (Gladiator_body) -- so either a Texture node is
## resolving to the wrong file name or the material reference is off. This
## prints both sides raw so the two can be told apart.
func _init() -> void:
	var name := "GLADIATOR.GRN"
	for a in OS.get_cmdline_user_args():
		name = a
	var install := Sacred.find_install()
	var pak := Sacred.Pak.new(install.path_join("pak/models.pak"))
	var models := Sacred.Models.new(pak)
	var e := models.index_of(name)
	print("entry\t%d\t%s" % [e, name])
	var names := models.texture_names(e)
	for i in names.size():
		print("texture\t%d\t%s" % [i, names[i]])
	var link := models.material_textures(e)
	for i in link.size():
		print("material\t%d\t-> texture %d\t%s" % [
			i, link[i], names[link[i]] if link[i] >= 0 and link[i] < names.size() else "<none>"])
	# Per draw batch, the UV box its own triangles sample. A batch whose box runs
	# outside 0..1 is reading the wrap, which is what a smeared skin looks like.
	var m := models.mesh_arrays(e)
	var uv: PackedVector2Array = m.get("uvs", PackedVector2Array())
	var idx: PackedInt32Array = m.get("indices", PackedInt32Array())
	# the same submesh reconciliation ModelView does: port submeshes in first-use
	# order, group meshes matched to them by triangle count.
	var vmesh: PackedInt32Array = m.get("vertex_mesh", PackedInt32Array())
	var faces := {}
	var starts := {}
	for t0 in idx.size() / 3:
		var pm: int = vmesh[idx[t0 * 3]]
		if not faces.has(pm):
			faces[pm] = 0
			starts[pm] = t0
		faces[pm] = int(faces[pm]) + 1
	var by_count := {}
	for pm2 in faces:
		by_count[int(faces[pm2])] = pm2
	# vertices actually REFERENCED per submesh, which is what a draw call sees
	var vused := {}
	for t1 in idx.size() / 3:
		var pm1: int = vmesh[idx[t1 * 3]]
		var st: Dictionary = vused.get(pm1, {})
		for c1 in 3:
			st[idx[t1 * 3 + c1]] = 1
		vused[pm1] = st
	for pm1 in vused:
		print("submesh\t%s\ttris %d\tvertices referenced %d" % [
			str(pm1), int(faces[pm1]), (vused[pm1] as Dictionary).size()])
	var g_sum := {}
	for g0 in models.material_groups(e):
		g_sum[g0["mesh"]] = int(g_sum.get(g0["mesh"], 0)) + int(g0["triangles"])
	var g2p := {}
	for gm in g_sum:
		if by_count.has(int(g_sum[gm])):
			g2p[gm] = by_count[int(g_sum[gm])]
	var gi := 0
	for g in models.material_groups(e):
		var picks: PackedInt32Array = g.get("tri_index", PackedInt32Array())
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for t in picks.size():
			var tri: int = int(starts.get(g2p.get(g["mesh"], -1), 0)) + picks[t]
			for c in 3:
				var vi := idx[tri * 3 + c]
				if vi < uv.size():
					lo = lo.min(uv[vi])
					hi = hi.max(uv[vi])
		print("uvbox\tgroup %d\tmesh %s\tmaterial %s\ttris %d\tu %.3f..%.3f\tv %.3f..%.3f" % [
			gi, str(g["mesh"]), str(g["material"]), int(g["triangles"]), lo.x, hi.x, lo.y, hi.y])
		gi += 1

	# and the images themselves, so a claim about what the skin should look like
	# is read off the retail bitmap instead of off the render it produced.
	var tpak := Sacred.Pak.new(install.path_join("pak/texture.pak"))
	for extra in OS.get_environment("TEXREF_ALSO").split(",", false):
		var xid := Sacred.TextureFormat.find_model_texture(tpak, extra)
		if xid < 0:
			print("image\t%s\tNOT FOUND" % extra)
			continue
		var ximg := Sacred.TextureFormat.decode_texture(tpak, xid)
		var xout := "/tmp/look/tex-%s.png" % extra.get_basename()
		ximg.save_png(xout)
		print("image\t%s\t%dx%d\t%s" % [extra, ximg.get_width(), ximg.get_height(), xout])
	var done := {}
	for n in names:
		var stem := n.get_file()
		if done.has(stem):
			continue
		done[stem] = 1
		var tid := Sacred.TextureFormat.find_model_texture(tpak, stem)
		if tid < 0:
			print("image\t%s\tNOT FOUND" % stem)
			continue
		var img := Sacred.TextureFormat.decode_texture(tpak, tid)
		var out := "/tmp/look/tex-%s.png" % stem.get_basename()
		img.save_png(out)
		print("image\t%s\t%dx%d\t%s" % [stem, img.get_width(), img.get_height(), out])
	quit()
