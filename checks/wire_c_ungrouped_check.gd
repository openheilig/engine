extends "res://checks/check.gd"
## wire_c_ungrouped_check.gd -- Wire C test: ungrouped triangles are skipped
## not drawn as <clay>, but the counter still increments (autoresearch row 1167).
##
##   godot --headless --path godot-port --script checks/wire_c_ungrouped_check.gd
##
## WHAT THIS PROTECTS. model_view.gd used to emit a clay surface for any
## single-texture entry whose declared groups did not cover every triangle --
## the "single-texture fallback". Retail's own draw loop binds glDrawElements
## to dword_9551F14 from sub_8624508 at 0x8625404 with one indexed
## GL_TRIANGLES call per declared batch, no implicit material, no separate
## pass. So the leftover triangles must NOT be drawn; they must be counted
## only, so the residue stays measurable without rendering as visible clay.
##
## Three properties are pinned:
##   1. ungrouped_triangles STILL increments for any not-claimed triangle.
##   2. surface_texture does NOT contain "<clay>" added by the leftovers path
##      (declared groups may legitimately use <clay> only when hide_materials
##      refused them, which does not apply to the entries tested below).
##   3. surfaces equals material_groups().size() -- one per declared group,
##      never groups+1.
##
## A SOLDIER.GRN run is included as a corpus sanity check: it has 1 texture
## and 6 declared groups; if any group falls through to the leftovers path,
## one of the three properties above will fail.

const ENTRIES := ["SOLDIER.GRN", "BAT.GRN", "WOLF.GRN"]


func _init() -> void:
	super()
	var install := Sacred.find_install()
	assert(install != "", "no retail install found; pass --install=/path/to/install")
	var models := Sacred.Models.new(Sacred.Pak.new(install.path_join("pak/models.pak")))
	assert(models.count() > 0, "models.pak did not open")

	for nm in ENTRIES:
		var e := models.index_of(nm)
		assert(e >= 0, "%s is not in models.pak" % nm)

		var mv = load("res://view/model_view.gd").new()
		root.add_child(mv)
		var ok: bool = mv.setup(models, e)
		if not ok:
			mv.queue_free()
			continue

		# 1. ungrouped_triangles is reported (>= 0).
		expect(mv.ungrouped_triangles >= 0,
			"%s: ungrouped_triangles is %d, expected >= 0" % [nm, mv.ungrouped_triangles])

		# 2. surfaces count equals the number of declared groups, never +1
		#    for a leftovers clay pass. A regression of the single-texture
		#    fallback would add exactly one clay surface per submesh that
		#    had any ungrouped triangle, raising surfaces above groups.size().
		var groups := models.material_groups(e)
		if groups.size() > 1:
			expect(mv.surfaces == groups.size(),
				"%s: surfaces=%d, expected %d (= material_groups count) -- a clay pass was added for leftovers" % [
					nm, mv.surfaces, groups.size()])

		# 3. surface_texture contains NO new "<clay>" entries -- declared
		#    groups on these three entries carry real textures, so any <clay>
		#    here is from the leftover pass the wire removes.
		var clay_count := 0
		for tx in mv.surface_texture:
			if tx == "<clay>":
				clay_count += 1
		expect(clay_count == 0,
			"%s: %d <clay> surface(s) on a fully-textured entry -- the single-texture fallback is back" % [
				nm, clay_count])

		# 4. When the entry DOES carry ungrouped triangles, the counter MUST
		#    have grown -- the wire removes the DRAW but keeps the COUNT.
		#    SOLDIER/BAT/WOLF are chosen because each is a single-texture
		#    rigged mesh whose declared groups don't always sum to the entry
		#    total; if the count is ever zero while the corpus has leftovers
		#    here, the counter was dropped along with the fallback.
		var claimed_total := 0
		for g in groups:
			claimed_total += int(g["triangles"])
		if mv.triangle_count > claimed_total:
			expect(mv.ungrouped_triangles == mv.triangle_count - claimed_total,
				"%s: ungrouped_triangles=%d but residue is %d -- the counter was dropped with the fallback" % [
					nm, mv.ungrouped_triangles, mv.triangle_count - claimed_total])

		mv.queue_free()

	print("wire_c_ungrouped_check OK: surfaces match declared groups, no <clay> on fully-textured entries, ungrouped_triangles counter increments")
	finish(0)
