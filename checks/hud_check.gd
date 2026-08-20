extends "res://checks/check.gd"
## hud_check.gd -- the ONE runnable check for the taskbar (row 962).
##
##   godot --headless --path . --script res://checks/hud_check.gd
##
## The HUD was the largest single thing this port did not draw -- zero lines of
## Control code against roughly a quarter of a Sacred screenshot. What makes it
## drawable rather than guessable is that retail's layout is TABLE-DRIVEN: a
## static array of 1887 texture sub-rects, placed by cUI_Taskbar2 onto a fixed
## 1024x768 canvas.
##
## WHAT THIS GATE PROTECTS. Not "does it render" -- a HUD of the wrong pieces
## in the wrong places renders perfectly. Every assertion below is an
## arithmetic relation between transcribed numbers, so a rect or a coordinate
## that drifts breaks one:
##
##   - the console is CENTRED: x = 512 - W/2 exactly
##   - the middle combat-art slot is centred: at.x + W/2 = 512 exactly
##   - the taskbar window is exactly the bottom 92 rows of 768
##   - every piece lies inside the canvas, and every rect inside its 256 sheet
const CANVAS := Vector2i(1024, 768)
const SHEET := 256
const CENTRE := 512


func _init() -> void:
	super()
	var install := Sacred.find_install()
	var tex := Sacred.Pak.new(install.path_join("pak/texture.pak"))
	expect(tex.is_open(), "texture.pak did not open")

	# THE WINDOW. {0, 676, 1024, 92} -- and 676 + 92 is 768 exactly, so the bar
	# is flush with the bottom of the canvas rather than near it.
	expect(Hud.TASKBAR.position.x == 0 and Hud.TASKBAR.size.x == CANVAS.x,
		"the taskbar is not full width")
	expect(Hud.TASKBAR.position.y + Hud.TASKBAR.size.y == CANVAS.y,
		"the taskbar does not reach the bottom of the canvas")

	# EVERY RECT INSIDE ITS SHEET, and every placement inside the canvas. A
	# transposed coordinate usually escapes one or the other.
	var pieces := 0
	for p in Hud.PIECES:
		_bounds(p["rect"], p["at"], "piece %d" % int(p["id"]))
		pieces += 1
	for a in Hud.ART_SLOTS:
		_bounds(a["rect"], a["at"], "art slot %d" % int(a["id"]))
	expect(pieces >= 8, "only %d taskbar pieces are described" % pieces)
	# THE PORTRAIT WINDOW IS ALLOWED OFF THE RIGHT EDGE, and only there. Its
	# 95-wide frame starts at 932, so three columns of the leafwork fall past
	# 1024 -- retail clips them exactly the same way, which is visible in its
	# own capture. So this asserts the weaker true property: the piece reads
	# inside its sheet, starts on screen, and overlaps the canvas.
	for w in Hud.PORTRAIT:
		var wr: Rect2i = w["rect"]
		var wa: Vector2i = w["at"]
		expect(wr.position.x >= 0 and wr.position.y >= 0
			and wr.end.x <= SHEET and wr.end.y <= SHEET,
			"portrait piece reads %s, outside its %dx%d sheet" % [wr, SHEET, SHEET])
		expect(wa.x >= 0 and wa.y >= 0 and wa.x < CANVAS.x and wa.y < CANVAS.y,
			"portrait piece at %s does not start on the canvas" % wa)
		expect(wa.y + wr.size.y <= CANVAS.y,
			"portrait piece at %s runs off the BOTTOM, which retail never does" % wa)
	expect(not Hud.PORTRAIT.is_empty(), "the portrait window is not described")

	# THE CONSOLE IS CENTRED. Retail computes x = 512 - W/2 rather than storing
	# a literal, so this is the arithmetic and not a measurement.
	var console: Dictionary = {}
	for p in Hud.PIECES:
		if int(p["id"]) == 12:
			console = p
	expect(not console.is_empty(), "the console piece is gone")
	var cw: int = (console["rect"] as Rect2i).size.x
	expect((console["at"] as Vector2i).x == CENTRE - cw / 2,
		"the console is at x %d, expected %d for a %d-wide piece" % [
			(console["at"] as Vector2i).x, CENTRE - cw / 2, cw])

	# THE COMBAT-ART ARC. Five slots, and the MIDDLE one is centred on the
	# screen. Its neighbours must sit symmetrically about it and rise towards
	# the centre -- the arc dips UP, which is the shape of the console's rim.
	expect(Hud.ART_SLOTS.size() == 5, "there are %d combat-art slots" % Hud.ART_SLOTS.size())
	var mid: Dictionary = Hud.ART_SLOTS[2]
	expect((mid["at"] as Vector2i).x + (mid["rect"] as Rect2i).size.x / 2 == CENTRE,
		"the middle combat-art slot is not screen-centred")
	for i in 2:
		var lo: Vector2i = Hud.ART_SLOTS[i]["at"]
		var hi: Vector2i = Hud.ART_SLOTS[i + 1]["at"]
		expect(hi.x > lo.x, "the combat-art slots are not left to right")
		expect(hi.y < lo.y, "the left half of the arc does not rise towards the centre")
	for i in range(2, 4):
		var lo2: Vector2i = Hud.ART_SLOTS[i]["at"]
		var hi2: Vector2i = Hud.ART_SLOTS[i + 1]["at"]
		expect(hi2.x > lo2.x, "the combat-art slots are not left to right")
		expect(hi2.y > lo2.y, "the right half of the arc does not fall away from the centre")

	# THE TWO WINGS are symmetric about the centre in COUNT and share a row.
	expect(Hud.SKILL_X0 + Hud.SLOT_STEP * (Hud.SLOTS - 1) < Hud.SPELL_X0,
		"the skill and spell wings overlap")
	expect(Hud.SPELL_X0 + Hud.SLOT_STEP * (Hud.SLOTS - 1) + 64 <= CANVAS.x,
		"the spell wing runs off the right of the canvas")
	expect(Hud.SKILL_X0 >= 0, "the skill wing runs off the left of the canvas")

	# NOW BUILD IT. Every sheet must resolve -- and the type-6 decoder is what
	# makes that possible, so a regression there shows up here as a missing
	# sheet rather than as a silently blank interface.
	var hud := Hud.new(tex)
	get_root().add_child(hud)
	expect(hud.missing.is_empty(),
		"these sheets did not resolve: %s" % [hud.missing])
	expect(hud.found, "the HUD drew nothing")
	# The wings CARRY THE SLOTS -- one rail tile per slot per side -- so the
	# count is derived from SLOTS rather than from a fixed screen span.
	var wings := Hud.SLOTS * 2
	var want := Hud.PIECES.size() + Hud.PORTRAIT.size() + Hud.ART_SLOTS.size() \
		+ Hud.SLOTS * 2 + 1 + wings
	expect(hud.drawn == want,
		"the HUD placed %d pieces, expected %d (%d of them wing tiles)" % [
			hud.drawn, want, wings])
	# THE LIFE GAUGE. The two blocks are complementary slices of one ring, so
	# the invariant is that they TILE it: whatever the fraction, the grey rows
	# plus the red rows cover the band exactly once, with no overlap and no
	# gap. That is the property a wrong sign or an off-by-one breaks, and it is
	# checkable without a frame.
	for f in [1.0, 0.75, 0.5, 0.25, 0.0]:
		hud.set_health(f)
		var red := (hud._ring_full.texture as AtlasTexture).region as Rect2
		var split := Hud.RING_TOP + roundi((1.0 - f) * float(
			Hud.RING_BOTTOM + 1 - Hud.RING_TOP))
		expect(int(red.position.y) == split and
			int(red.end.y) == (Hud.PORTRAIT[0]["rect"] as Rect2i).end.y,
			"at %.2f health the red slice is %s, not rows %d..%d" % [
				f, red, split, (Hud.PORTRAIT[0]["rect"] as Rect2i).end.y])
		expect(hud._ring_full.position.y == 15 + split,
			"the red slice is at y %d but its rows start at %d" % [
				hud._ring_full.position.y, split])
		# Full health draws NO grey. Anything else would blend the red ring's
		# soft edge against grey rather than against the world, which moves
		# pixels in a frame the capture runbooks md5.
		expect(hud._ring_empty.visible == (f < 1.0),
			"at %.2f health the drained half is %s" % [
				f, "shown" if hud._ring_empty.visible else "hidden"])
		if hud._ring_empty.visible:
			var grey := (hud._ring_empty.texture as AtlasTexture).region as Rect2
			expect(int(grey.end.y) == split,
				"the grey slice ends at %d and the red starts at %d -- they %s"
					% [int(grey.end.y), split,
					"overlap" if int(grey.end.y) > split else "leave a gap"])
	# Leave it where a fresh run finds it.
	hud.set_health(1.0)

	# THE RAIL MUST NOT OUTRUN THE SLOTS, which is exactly what the earlier
	# full-width tiling did: ten pieces laid across bare terrain, charged 13%
	# of the whole two-engine frame delta (row 1015). Each rail butts the
	# console and reaches just far enough to carry the outermost slot.
	var lw: int = (Hud.WING_LEFT[0]["rect"] as Rect2i).size.x
	var rail_l: int = Hud.CONSOLE_LEFT - lw - Hud.SLOT_STEP * (Hud.SLOTS - 1)
	expect(rail_l <= Hud.SKILL_X0 and rail_l > Hud.SKILL_X0 - Hud.SLOT_STEP,
		"the left rail starts at %d; the outermost skill slot is at %d" % [
			rail_l, Hud.SKILL_X0])
	var rw: int = (Hud.WING_RIGHT[0]["rect"] as Rect2i).size.x
	var rail_r: int = Hud.CONSOLE_RIGHT + Hud.SLOT_STEP * (Hud.SLOTS - 1) + rw
	var spell_end: int = Hud.SPELL_X0 + Hud.SLOT_STEP * (Hud.SLOTS - 1) + 63
	expect(rail_r >= spell_end and rail_r < spell_end + Hud.SLOT_STEP,
		"the right rail ends at %d; the outermost spell slot ends at %d" % [
			rail_r, spell_end])
	# The console's own edges are the anchors, so a moved console moves both.
	expect(Hud.CONSOLE_LEFT == (console["at"] as Vector2i).x
		and Hud.CONSOLE_RIGHT == (console["at"] as Vector2i).x + cw,
		"the rail anchors have drifted off the console's %d-wide rect" % cw)
	# THE DIAL IS 56 WIDE ON SCREEN, not the 128 of its own texture. Setting
	# size before add_child let the layout snap it back and painted a 128px
	# night-sky annulus across the console; this reads the live node.
	var dial: TextureRect = null
	for c in hud.get_node("Taskbar").get_children():
		var t := c as TextureRect
		if t != null and t.texture is ImageTexture:
			dial = t
	expect(dial != null, "the day/night dial was not placed")
	if dial != null:
		expect(dial.size == Vector2(Hud.DISC_SIZE, Hud.DISC_SIZE),
			"the dial renders %s, expected %dx%d" % [
				dial.size, Hud.DISC_SIZE, Hud.DISC_SIZE])

	# The console shows text, and retail's own break marker becomes a newline.
	hud.show_line("Kill the demon,<n>after Shareefa has summoned it.")

	print("hud_check\tOK\tpieces=%d\tcanvas=%dx%d\tconsole_x=%d\tmissing=%d" % [
		hud.drawn, CANVAS.x, CANVAS.y, (console["at"] as Vector2i).x, hud.missing.size()])
	finish(0)


func _bounds(rect: Rect2i, at: Vector2i, what: String) -> void:
	expect(rect.position.x >= 0 and rect.position.y >= 0
		and rect.end.x <= SHEET and rect.end.y <= SHEET,
		"%s reads %s, outside its %dx%d sheet" % [what, rect, SHEET, SHEET])
	expect(at.x >= 0 and at.y >= 0
		and at.x + rect.size.x <= CANVAS.x and at.y + rect.size.y <= CANVAS.y,
		"%s at %s runs off the canvas" % [what, at])
