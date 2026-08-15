extends "res://checks/check.gd"
## skin_check.gd -- the ONE runnable check for creature TEXTURES.
##
##   godot --headless --path . --script res://checks/skin_check.gd
##
## Until 2026-08-15 every creature rendered as flat clay: model_view.gd set an
## albedo_color and no albedo_texture existed anywhere in the project. The
## images were always in the install; what was missing was the three joins
## this gate pins.
##
## JOIN 1 -- WHICH texture. Models.texture_names() walks the .GRN's own
## TextureSection (0xCA5E0304) and each Texture's DataExtensionReference, the
## same two-hop chain bone_names() uses, asking for __FileName instead of
## __ObjectName.
##
## What that adds over strings() is ORDER AND MULTIPLICITY, not new names: the
## two agree on the DISTINCT set every time, which this gate asserts as a
## cross-check. GLADIATOR carries six Texture nodes over three distinct images
## -- the per-material assignment -- and the string table can only say the
## three exist. (An earlier note here claimed SOLDIER.GRN's table held nine
## SORCERESS_* names against one Texture node. It does not; that came from a
## regex over the raw entry bytes reading past the StringTable node, and the
## table and the nodes both say one.)
##
## JOIN 2 -- WHERE it lives. The name is an artist's authoring path and its
## EXTENSION DOES NOT SURVIVE THE BUILD: `...\animals\wolf\maps\wolf.bmp` is
## WOLF.TGA in texture.pak. The join is on the STEM; matching the filename
## loses every .bmp.
##
## JOIN 3 -- the decode is not new. A model skin sits in the same container
## decode_texture() already read for terrain -- u16 w, u16 h, kind 4, zlib from
## +80, ARGB4444 -- so nothing here decodes a new format. Terrain's atlas
## geometry (slot_uv, the 18 diamonds) does NOT apply and is not used: a skin
## is one whole image. The CHANNEL ORDER does differ from terrain's, though;
## see JOIN 5, which is where this gate previously said "RGBA4444" and was
## wrong in a way that made every character see-through.
##
## JOIN 4 -- WHICH SUBMESH. Models.material_groups() reads the ModelSection's
## draw batches: 0xCA5E0E02 carries {u32 mesh, u32 material_index (ONE-BASED),
## f32, f32} and the group's 0xCA5E0E04 carries its triangle count. ModelView
## builds one surface per group.
##
## The check that the fields are what they look like is arithmetic, not
## plausibility: THE GROUP TRIANGLE COUNTS SUM TO THE ENTRY'S OWN TOTAL, and
## the PER-MESH sums equal each submesh's own face count. GLADIATOR is
## 212+230+260+258+350+385 = 1695 over three meshes; WALDELFE_DARK 1792 over
## seven groups. A wrong field does not partition anything.
##
## STILL ASSUMED: that groups of the SAME mesh appear in triangle order. The
## per-mesh partition is measured, so a mis-slice can only swap two batches
## within one submesh, never across submeshes.
const SINGLE_MIN := 1300     ## mesh entries naming exactly one texture
const RESOLVE_MIN := 0.60    ## share of named textures found in texture.pak

func _init() -> void:
	super()
	var install := Sacred.find_install()
	var mp := Sacred.Pak.new(install.path_join("pak/models.pak"))
	var tp := Sacred.Pak.new(install.path_join("pak/texture.pak"))
	var models := Sacred.Models.new(mp)

	# The Texture nodes disagree with the string table, and must.
	var soldier := models.index_of("SOLDIER.GRN")
	assert(soldier >= 0, "SOLDIER.GRN is not in models.pak")
	var s_tex := models.texture_names(soldier)
	assert(s_tex.size() == 1,
		"SOLDIER.GRN names %d textures, expected 1" % s_tex.size())
	assert(s_tex[0].to_lower().contains("soldier_black_cloth1"),
		"SOLDIER.GRN's texture is %s" % s_tex[0])
	# CROSS-CHECK: two independent readings of the same file must agree on the
	# distinct set. strings() walks the StringTable node; texture_names() walks
	# the Texture nodes and their extension references, sharing none of that
	# path. Multiplicity may differ -- that is the point of the node walk -- so
	# the comparison is on the SET.
	for nm in ["SOLDIER.GRN", "GLADIATOR.GRN", "WOLF.GRN", "WALDELFE_DARK.GRN"]:
		var e := models.index_of(nm)
		var from_table := {}
		for x in models.strings(e):
			var l := x.to_lower()
			if l.ends_with(".tga") or l.ends_with(".bmp"):
				from_table[x] = 1
		var from_nodes := {}
		for x in models.texture_names(e):
			from_nodes[x] = 1
		var tk := from_table.keys(); tk.sort()
		var nk := from_nodes.keys(); nk.sort()
		assert(tk == nk,
			"%s: the string table and the Texture nodes disagree on which images exist -- table %s, nodes %s" % [
				nm, tk, nk])
	# and the node walk must add something, or it is an expensive strings()
	var gtex := models.texture_names(models.index_of("GLADIATOR.GRN"))
	var gset := {}
	for x in gtex:
		gset[x] = 1
	assert(gtex.size() > gset.size(),
		"GLADIATOR's %d Texture nodes are all distinct -- the per-material multiplicity the node walk exists for is gone" % gtex.size())

	# The stem join, on a name whose extension does not survive.
	var wolf := models.index_of("WOLF.GRN")
	var w_tex := models.texture_names(wolf)
	assert(w_tex.size() == 1 and w_tex[0].to_lower().ends_with(".bmp"),
		"WOLF.GRN no longer names a single .bmp: %s" % [w_tex])
	var wid := Sacred.TextureFormat.find_model_texture(tp, w_tex[0])
	assert(wid >= 0, "WOLF's .bmp did not resolve to a .tga -- the stem join broke")
	# and matching the filename instead must FAIL, or the stem rule is idle
	assert(Sacred.TextureFormat.find_model_texture(tp, "wolf.bmp.keepextension") < 0,
		"a name with a bogus stem resolved -- the lookup is not keying on the stem")

	# The image decodes, and it is not an atlas tile.
	var img := Sacred.TextureFormat.decode_texture(tp, wid, false)
	assert(img != null, "WOLF's texture did not decode")
	assert(img.get_width() >= 64 and img.get_height() >= 64,
		"WOLF's texture is %dx%d" % [img.get_width(), img.get_height()])

	# JOIN 5 -- THE CHANNEL ORDER, which a skin gets wrong in a way terrain does
	# not. The payload is ARGB4444. decode_texture(render=true) hands those bytes
	# to Godot as FORMAT_RGBA4444, rotating every channel by one: the real ALPHA
	# arrives as red and the real BLUE as alpha. Terrain survives it by sampling
	# through its own shader; a StandardMaterial3D does not, and with the
	# transparent pass PlayerView draws in, an average alpha of 0.28 and NO fully
	# opaque pixel made every character invisible while its untextured weapon
	# stayed solid.
	#
	# So the two decodes must DISAGREE, and disagree by exactly that rotation --
	# asserting only that the right one looks opaque would pass just as well if
	# both paths were changed to the wrong one.
	var rot := Sacred.TextureFormat.decode_texture(tp, wid, true)
	assert(rot != null, "WOLF's texture did not decode on the render path")
	var argb := img.get_pixel(img.get_width() / 2, img.get_height() / 2)
	var rgba := rot.get_pixel(rot.get_width() / 2, rot.get_height() / 2)
	assert(is_equal_approx(rgba.r, argb.a) and is_equal_approx(rgba.g, argb.r)
		and is_equal_approx(rgba.b, argb.g) and is_equal_approx(rgba.a, argb.b),
		"the two decode paths no longer differ by one channel rotation: ARGB %s vs render %s" % [argb, rgba])
	# and the ARGB decode must be OPAQUE where retail's own art is opaque, which
	# is the property the transparent pass depends on.
	var opaque := 0
	var sampled := 0
	for y in range(0, img.get_height(), 4):
		for x in range(0, img.get_width(), 4):
			sampled += 1
			if img.get_pixel(x, y).a > 0.98:
				opaque += 1
	assert(float(opaque) / float(sampled) > 0.95,
		"only %.3f of WOLF's skin is opaque under the ARGB decode -- a character drawn with this is see-through" % [
			float(opaque) / float(sampled)])

	# JOIN 6 -- THE MATERIAL IS NOT THE TEXTURE. A draw batch's material number
	# indexes the MATERIAL list; the material then names a texture. The port read
	# the material number as a texture number, which is the identity mapping, and
	# on 1415 of 1546 entries the identity happens to be right -- which is why a
	# corpus census passed while GLADIATOR rendered with its head on the body
	# image, an arm on the boots image and a leg on the head image.
	#
	# MaterialSection 0xCA5E0D01 -> Material 0xCA5E0D00, 16 bytes each, whose +4
	# is a ONE-BASED texture reference. GLADIATOR's six read 2,6,1,3,4,5.
	#
	# The corpus check is structural: where an entry has as many materials as
	# textures the references must form a PERMUTATION. A wrong field does not
	# permute 1546 times out of 1546.
	var with_mat := 0
	var equal := 0
	var permutation := 0
	var nonidentity := 0
	for e in models.count():
		if models.kind_of(e) != 64:
			continue
		var link := models.material_textures(e)
		if link.is_empty():
			continue
		with_mat += 1
		var ntex := models.texture_names(e).size()
		if link.size() != ntex:
			continue
		equal += 1
		var seen := {}
		var ident := true
		for i in link.size():
			seen[link[i]] = 1
			if link[i] != i:
				ident = false
		if seen.size() == link.size() and not seen.has(-1):
			permutation += 1
		if not ident:
			nonidentity += 1
	assert(with_mat > 1500, "only %d mesh entries carry a material table" % with_mat)
	assert(permutation == equal,
		"only %d of %d equinumerous entries map materials to DISTINCT textures -- the +4 field is not a texture reference" % [
			permutation, equal])
	# and the identity must NOT be good enough, or this join is decoration
	assert(nonidentity > 50,
		"only %d entries permute -- if the identity really is the mapping this reader is pointless" % nonidentity)
	# the case that made it visible
	var gi := models.index_of("GLADIATOR.GRN")
	var glink := models.material_textures(gi)
	var gnames := models.texture_names(gi)
	var head_mat := -1
	for i in glink.size():
		if glink[i] >= 0 and gnames[glink[i]].to_lower().contains("head"):
			head_mat = i
	assert(head_mat >= 0, "no GLADIATOR material references the head image")
	assert(head_mat != glink[head_mat],
		"GLADIATOR's head material is its own index, so this file no longer demonstrates the permutation")

	# JOIN 7 -- A GROUP NAMES ITS OWN TRIANGLES, and they are not contiguous.
	# 0xCA5E0E06 holds u32 count then 16 bytes per triangle whose first u32 is an
	# index into the SUBMESH's triangle array. Slicing the submesh in group order
	# instead put half a boot on a thigh. The invariant is exact: across a
	# submesh's groups the indices cover 0..n-1 once, with no gaps and no repeats.
	var interleaved := 0
	for nm3 in ["GLADIATOR.GRN", "WALDELFE_DARK.GRN", "NOBLE_FEM.GRN"]:
		var e3 := models.index_of(nm3)
		if e3 < 0:
			continue
		var by_mesh := {}
		for g in models.material_groups(e3):
			var picks: PackedInt32Array = g.get("tri_index", PackedInt32Array())
			assert(picks.size() == int(g["triangles"]),
				"%s: a group declares %d triangles but names %d" % [
					nm3, int(g["triangles"]), picks.size()])
			var lst: Array = by_mesh.get(g["mesh"], [])
			lst.append(picks)
			by_mesh[g["mesh"]] = lst
		for mk in by_mesh:
			var all: Array[int] = []
			var contiguous := true
			for picks2: PackedInt32Array in by_mesh[mk]:
				for i2 in picks2.size():
					all.append(picks2[i2])
					if i2 > 0 and picks2[i2] != picks2[i2 - 1] + 1:
						contiguous = false
			all.sort()
			var want: Array[int] = []
			for i3 in all.size():
				want.append(i3)
			assert(all == want,
				"%s mesh %s: the groups' triangle indices do not cover 0..%d exactly once" % [
					nm3, mk, all.size() - 1])
			if not contiguous:
				interleaved += 1
	# and at least one submesh must be INTERLEAVED, or a contiguous slice would
	# have worked and this join is untested by its own corpus.
	assert(interleaved > 0,
		"every group's triangles are contiguous, so this gate cannot tell the exact reading from the slice it replaced")

	# JOIN 8 -- A SMALL ENTRY IS STILL AN ENTRY. texture.pak's index `size` is
	# the ZLIB PAYLOAD length, not the entry length, and the 32-byte name sits
	# before it. Gating the name index on that size dropped every entry under 32
	# bytes -- 28 of 25535, all solid-colour placeholders, 8 of which models.pak
	# references 13 times. The wood elf's hands batch is the visible one: retail
	# binds ELVE_SORCERESS_HANDS.TGA, a 16x16 flat skin block (measured off
	# retail's own glTexImage2D, row 903), where the port drew clay.
	var tiny := 0
	for i in tp.count():
		var head := tp.read_at(tp.entry_offset(i), 40)
		if head.size() < 40:
			continue
		var z := head.find(0)
		if z <= 0:
			continue
		# +32 u16 width, +34 u16 height, +36 u32 kind, and the index size is the
		# payload -- a real image with a tiny payload is exactly the dropped case
		if int(tp.blob(i, 0).size()) < 32 and head.decode_u16(32) > 0:
			tiny += 1
			var stem := head.slice(0, z).get_string_from_ascii()
			assert(Sacred.TextureFormat.find_model_texture(tp, stem) >= 0,
				"%s is a %dx%d texture the index cannot find -- the payload size is being read as the entry size again" % [
					stem, head.decode_u16(32), head.decode_u16(34)])
	assert(tiny >= 20,
		"only %d entries have a sub-32-byte payload; this gate is watching nothing" % tiny)
	# and the one that renders, named outright so a corpus count cannot hide it
	var hands := Sacred.TextureFormat.find_model_texture(tp, "elve_sorceress_hands.bmp")
	assert(hands >= 0, "ELVE_SORCERESS_HANDS is unresolvable, so the wood elf's hands draw clay")
	var himg := Sacred.TextureFormat.decode_texture(tp, hands)
	assert(himg != null and himg.get_width() == 16 and himg.get_height() == 16,
		"ELVE_SORCERESS_HANDS did not decode to the 16x16 retail uploads")

	# Corpus census, and a rig that actually carries the skin.
	var single := 0
	var named := 0
	var resolved := 0
	for e in models.count():
		if models.kind_of(e) != 64:
			continue
		var t := models.texture_names(e)
		if t.is_empty():
			continue
		if t.size() == 1:
			single += 1
		for x in t:
			named += 1
			if Sacred.TextureFormat.find_model_texture(tp, x) >= 0:
				resolved += 1
	assert(single >= SINGLE_MIN,
		"only %d mesh entries name exactly one texture, floor is %d" % [single, SINGLE_MIN])
	var rate := float(resolved) / float(maxi(named, 1))
	assert(rate >= RESOLVE_MIN,
		"only %.3f of named textures resolve in texture.pak, floor %.2f" % [rate, RESOLVE_MIN])

	# THE PARTITION. Group triangles must sum to the entry total, and the
	# per-mesh sums must equal each submesh's own face count -- derived here
	# from the index array and the per-vertex mesh id, which material_groups()
	# never sees. Two readings of the same file, no shared path.
	var checked := 0
	for nm2 in ["GLADIATOR.GRN", "WALDELFE_DARK.GRN", "WOLF.GRN", "NOBLE_FEM.GRN", "BEAR.GRN"]:
		var e := models.index_of(nm2)
		var a := models.mesh_arrays(e)
		var groups := models.material_groups(e)
		if a.is_empty() or groups.is_empty():
			continue
		checked += 1
		var total := 0
		var per_mesh := {}
		for g in groups:
			total += int(g["triangles"])
			per_mesh[g["mesh"]] = int(per_mesh.get(g["mesh"], 0)) + int(g["triangles"])
		assert(total == int(a["triangle_count"]),
			"%s: groups sum to %d triangles, the mesh has %d" % [nm2, total, a["triangle_count"]])
		var faces := {}
		var ind: PackedInt32Array = a["indices"]
		var vmesh: PackedInt32Array = a["vertex_mesh"]
		for t in ind.size() / 3:
			var mi2: int = vmesh[ind[t * 3]]
			faces[mi2] = int(faces.get(mi2, 0)) + 1
		# THE GROUP'S MESH NUMBER IS NOT mesh_arrays()' -- GLADIATOR's groups
		# total {0:442, 1:868, 2:385} against a layout of {0:868, 1:385, 2:442},
		# and WALDELFE_DARK permutes differently again. So the invariant is that
		# the MULTISETS of triangle counts match, which is what lets ModelView
		# reconcile the two orderings by count; comparing index to index would
		# fail here and did.
		var gs := per_mesh.values(); gs.sort()
		var fs := faces.values(); fs.sort()
		assert(gs == fs,
			"%s: group triangle counts %s do not match the submesh face counts %s" % [nm2, gs, fs])
		# and the counts must be DISTINCT, or the reconciliation is a guess
		assert(fs.size() == 1 or fs[0] != fs[1],
			"%s: two submeshes share a face count %s -- the count mapping is ambiguous" % [nm2, fs])
	assert(checked >= 4, "only %d models had both arrays and groups" % checked)

	var ModelViewScript := load("res://view/model_view.gd")
	var mv = ModelViewScript.new()
	mv.set_texture_pak(tp)
	assert(mv.setup(models, wolf, false), "WOLF did not build")
	assert(mv.textures_named == 1 and mv.textured,
		"WOLF built with textures_named=%d textured=%s" % [mv.textures_named, mv.textured])
	assert(mv.surfaces == 1, "WOLF built %d surfaces, expected 1" % mv.surfaces)
	var gl = ModelViewScript.new()
	gl.set_texture_pak(tp)
	assert(gl.setup(models, models.index_of("GLADIATOR.GRN"), false), "GLADIATOR did not build")
	assert(gl.surfaces == 6,
		"GLADIATOR built %d surfaces, expected one per material group (6)" % gl.surfaces)
	assert(gl.textured_surfaces == 6,
		"only %d of GLADIATOR's 6 surfaces carry an image" % gl.textured_surfaces)
	mv.free()
	gl.free()

	print("skin_check\tOK\tsingle_texture_entries=%d\tnamed=%d\tresolved=%d (%.3f)\twolf=%dx%d" % [
		single, named, resolved, rate, img.get_width(), img.get_height()])
	finish(0)
