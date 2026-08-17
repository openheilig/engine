extends "res://checks/check.gd"
## liquid_check.gd -- the ONE runnable check for the animated liquid pass
## (row 1008).
##
##   godot --headless --path . --script res://checks/liquid_check.gd
##
## WHAT THIS PROTECTS. Liquid is drawn from a 14-entry material table read out
## of the retail binary's own unrolled initialiser, and a table read that way
## has two ways to be wrong that no crash would reveal: a name could be
## mistyped, or the whole sequence could be off by a slot. Neither shows up as
## an error -- the sea just animates with the wrong skin, or silently stops
## being drawn at all, which is the state this fix was written to end.
##
## So the assertions are about the properties that make the pass sound:
##
##   1. EVERY name in the table resolves to real frames in texture.pak. A
##      mistyped stem or a slot that drifted off the end is caught here and
##      nowhere else, because material_id currently only ever returns 0.
##   2. The sets are ANIMATIONS, not stills -- more than one frame each.
##   3. A known all-liquid sea sector still reads as liquid, so the marker this
##      hangs off (WldxEntry +0x1f high nibble 9/10) has not moved, and it
##      agrees cell for cell with what Walkable blocks movement on.
##   4. Building that sector emits one liquid quad per liquid cell.
##   5. The liquid quad sits ABOVE its own cell's ground and BELOW the next
##      cell's ground. That ordering is the whole reason the water covers its
##      bed without punching through the neighbour, and it is a property of two
##      constants that are edited independently.
const LiquidScript := preload("res://view/liquid.gd")

## A sector measured to be 4096/4096 liquid. If the marker ever changes meaning
## this is the first thing that stops being true.
const SEA := Vector2i(47, 67)


func _init() -> void:
	super()
	var install := Sacred.find_install()
	var tex := Sacred.Pak.new(install.path_join("pak/texture.pak"))
	expect(tex.is_open(), "texture.pak did not open -- is the install present?")
	var world := Sacred.World.new(install.path_join("world"))
	expect(world.is_open(), "world did not open")
	if not tex.is_open() or not world.is_open():
		finish(1)
		return

	# (1) and (2): the table against the shipped images.
	var liquid := LiquidScript.new(tex)
	expect(LiquidScript.MATERIALS.size() == 14,
		"the liquid table has %d entries, expected 14" % LiquidScript.MATERIALS.size())
	var frames := PackedStringArray()
	for id in LiquidScript.MATERIALS.size():
		var mat: ShaderMaterial = liquid.material_for(id)
		if not expect(mat != null, "liquid %d (%s) built no material -- the name does not resolve in texture.pak"
				% [id, LiquidScript.MATERIALS[id]]):
			continue
		var n: float = mat.get_shader_parameter(&"frame_count")
		expect(n > 1.0, "liquid %d (%s) has %d frame(s); an animation needs more than one"
			% [id, LiquidScript.MATERIALS[id], int(n)])
		frames.append("%s=%d" % [LiquidScript.MATERIALS[id], int(n)])

	# (3) the marker, counted straight off the file rather than through the
	# renderer, so a builder that silently drops cells cannot also define what
	# the right answer is.
	var cells := world.entries(SEA.x, SEA.y)
	expect(not cells.is_empty(), "sector %s is absent" % SEA)
	var want := 0
	for i in Sacred.SECT * Sacred.SECT:
		var nib := cells[i * Sacred.CELL + 0x1f] >> 4
		if nib == 9 or nib == 10:
			want += 1
	expect(want == Sacred.SECT * Sacred.SECT,
		"sector %s is %d/%d liquid, expected all of it -- pick a new sample sector"
			% [SEA, want, Sacred.SECT * Sacred.SECT])

	# The renderer and the sim must read the SAME cells. Two independent
	# readings of one nibble is how a field drifts out of agreement with itself,
	# which is why Walkable.is_liquid is public in the first place.
	var walk := Walkable.new(world)
	var disagree := 0
	for i in Sacred.SECT * Sacred.SECT:
		var nib := cells[i * Sacred.CELL + 0x1f] >> 4
		var cx := SEA.x * Sacred.SECT + i % Sacred.SECT
		var cy := SEA.y * Sacred.SECT + i / Sacred.SECT
		if (nib == 9 or nib == 10) != walk.is_liquid(cx, cy):
			disagree += 1
	expect(disagree == 0,
		"the renderer's liquid test disagrees with Walkable.is_liquid on %d cell(s)" % disagree)

	# (4) the geometry.
	var view := SectorView.new()
	view._world = world
	view._tex_pak = tex
	view._tiles = Sacred.Tiles.new(install.path_join("pak/tiles.pak"))
	view._liquid = liquid
	var mi := view._build_sector(SEA.x, SEA.y)
	if not expect(mi != null, "sector %s built no mesh at all" % SEA):
		finish(1)
		return
	var got: int = mi.get_meta("liquid_quads", 0)
	expect(got == want, "sector %s has %d liquid cells but emitted %d liquid quad(s)"
		% [SEA, want, got])

	# (5) the depth ordering, from the constants rather than from the mesh: the
	# liquid bump must clear every overlay the same cell can stack and still
	# stay inside the step to the next cell's ground.
	var overlay_top := SectorView.OVERLAY_Z * (SectorView.OVERLAY_MAX - 1)
	expect(SectorView.LIQUID_Z > overlay_top,
		"liquid sits at %.4f, under the highest overlay at %.4f -- the bed would show through"
			% [SectorView.LIQUID_Z, overlay_top])
	expect(SectorView.LIQUID_Z < SectorView.DEPTH_STEP,
		"liquid sits at %.4f, at or past the %.4f step to the next cell's ground"
			% [SectorView.LIQUID_Z, SectorView.DEPTH_STEP])

	print("liquid_check\tOK\tmaterials=%d\tsea=%s\tquads=%d" % [
		LiquidScript.MATERIALS.size(), SEA, got])
	print("liquid_check\tframes\t%s" % " ".join(frames))
	finish(0)
