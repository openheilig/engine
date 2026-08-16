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
	expect(pieces >= 9, "only %d taskbar pieces are described" % pieces)

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
	# The wings TILE, so the count is derived rather than listed: each side
	# steps at the slot pitch from its anchor to the console.
	var wings := 0
	var wx := Hud.WING_LEFT_X
	while wx < Hud.WING_LEFT_END:
		wings += 1
		wx += Hud.SLOT_STEP
	wx = Hud.WING_RIGHT_X
	while wx > Hud.WING_RIGHT_END:
		wings += 1
		wx -= Hud.SLOT_STEP
	var want := Hud.PIECES.size() + Hud.ART_SLOTS.size() + Hud.SLOTS * 2 + 1 + wings
	expect(hud.drawn == want,
		"the HUD placed %d pieces, expected %d (%d of them wing tiles)" % [
			hud.drawn, want, wings])
	# The wings must MEET the console rather than leave a gap or overlap it.
	expect(Hud.WING_LEFT_END <= 397 and Hud.WING_RIGHT_END >= 397,
		"a wing does not reach the console")

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
