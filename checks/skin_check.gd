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
## +80, RGBA4444 -- so nothing here decodes a new format. Terrain's atlas
## geometry (slot_uv, the 18 diamonds) does NOT apply and is not used: a skin
## is one whole image.
##
## WHAT IS DELIBERATELY NOT DONE. mesh_arrays() concatenates every submesh into
## one surface, so a rig carries one material. That is right for the 1393 of
## 1558 mesh entries naming a single texture and wrong for GLADIATOR (six names
## over three submeshes) and WALDELFE_DARK (seven), so the binding is gated on
## `== 1` rather than taking the first name. Those stay clay until the
## Material->Mesh chain (0xCA5E0D00/0xCA5E0D01) is read. A confidently wrong
## skin is worse than no skin.
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
	var img := Sacred.TextureFormat.decode_texture(tp, wid, true)
	assert(img != null, "WOLF's texture did not decode")
	assert(img.get_width() >= 64 and img.get_height() >= 64,
		"WOLF's texture is %dx%d" % [img.get_width(), img.get_height()])

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

	var ModelViewScript := load("res://view/model_view.gd")
	var mv = ModelViewScript.new()
	mv.set_texture_pak(tp)
	assert(mv.setup(models, wolf, false), "WOLF did not build")
	assert(mv.textures_named == 1 and mv.textured,
		"WOLF built with textures_named=%d textured=%s" % [mv.textures_named, mv.textured])
	var gl = ModelViewScript.new()
	gl.set_texture_pak(tp)
	assert(gl.setup(models, models.index_of("GLADIATOR.GRN"), false), "GLADIATOR did not build")
	assert(gl.textures_named > 1 and not gl.textured,
		"GLADIATOR names %d textures and textured=%s -- a multi-material model must NOT be skinned from one name" % [
			gl.textures_named, gl.textured])
	mv.free()
	gl.free()

	print("skin_check\tOK\tsingle_texture_entries=%d\tnamed=%d\tresolved=%d (%.3f)\twolf=%dx%d" % [
		single, named, resolved, rate, img.get_width(), img.get_height()])
	finish(0)
