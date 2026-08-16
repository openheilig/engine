class_name Hud
extends CanvasLayer
## RETAIL'S OWN TASKBAR, drawn from retail's own art at retail's own
## coordinates (findings log row 962).
##
## Every number in this file was transcribed, not chosen. The HUD is
## TABLE-DRIVEN in the executable: a static array of 1887 texture sub-rects at
## 0x880DC68, stride 84, each `{char name[32]; float u0,v0,u1,v1; int hx0..hy1;
## int W,H; int id; int type}`, and `cUI_Taskbar2::createControls`
## (sub_85E85EE) places elements from it by id.
##
## THE CANVAS IS FIXED AT 1024x768. `cUI_Manager::createWindows` (sub_84FA548)
## hard-codes every window rect, and `UI_WND_TASKBAR` is {0, 676, 1024, 92}.
## There is no division against a screen-width global anywhere on the HUD path,
## so the interface is authored in a fixed virtual space and scaled -- which is
## why this class scales rather than re-anchoring.
##
## THE VERTICAL CONVENTION is `y = 80 - hy0` inside the window (transcribed at
## 0x85E8627, `mov $0x50,%eax; sub <hy0>,%eax`), i.e. every piece hangs from an
## anchor line at window y=80, screen y=756, and `hy0` is the sprite's own
## distance from its top to that line. The rects below are already resolved to
## screen coordinates so that convention lives here in one comment rather than
## in twelve subtractions.
##
## WHAT THIS DOES NOT DRAW, and it is a real gap rather than a simplification:
## the LIFE AND MANA GAUGES. All 46 functions of cUI_Taskbar2 were enumerated
## and the class references no orb, globe or fill-bar art and computes no
## fraction or scissor rect. The two orb-looking 95x107 elements in
## GUI_main_02 belong to the mercenary window instead. So where the gauges are
## drawn is unrecovered, and inventing a pair of orbs here would be inventing
## the most recognisable part of the screen.
##
## Nothing here reads a simulation type (R10.2): the caller pushes values in.

## The virtual canvas the whole interface is authored against.
const CANVAS := Vector2i(1024, 768)
## `UI_WND_TASKBAR` -- {x, y, w, h}, verbatim.
const TASKBAR := Rect2i(0, 676, 1024, 92)
## Every sheet in the gfx table is 256x256.
const SHEET := 256.0

## One piece: which sheet, its texel rect there, and where it lands on the
## 1024x768 canvas.
##
## SIZE IS `u1 - u0`, NOT `u1 - u0 + 1`. The gfx table stores an inclusive
## corner and the loader adds 1.0 to it, but it then takes W as the DIFFERENCE
## of the adjusted values against the unadjusted origin -- so the console's
## (0,169)-(230,255) is 230x86, not 231x87. That is not a rounding preference:
## retail places the console at `x = 512 - W/2`, which gives its transcribed
## 397 only for W = 230. Writing the rects one texel too large put the middle
## combat-art slot one pixel off centre and pushed the collect toggle one row
## off the bottom of the canvas, and hud_check caught both.
##
## The ids are the gfx table's own, kept so a number can be checked against the
## table rather than trusted.
const PIECES := [
	# id 12 -- the console, the bar's centre panel. Not stretched.
	{"id": 12, "sheet": "GUI_MAIN_03", "rect": Rect2i(0, 169, 230, 86), "at": Vector2i(397, 680)},
	# The four taskbar buttons, in their UP state.
	{"id": 88, "sheet": "GUI_MAIN_01", "rect": Rect2i(102, 0, 33, 33), "at": Vector2i(399, 705)},
	{"id": 90, "sheet": "GUI_MAIN_01", "rect": Rect2i(136, 0, 33, 33), "at": Vector2i(434, 729)},
	{"id": 92, "sheet": "GUI_MAIN_01", "rect": Rect2i(170, 0, 33, 33), "at": Vector2i(558, 729)},
	{"id": 94, "sheet": "GUI_MAIN_01", "rect": Rect2i(204, 0, 33, 33), "at": Vector2i(594, 705)},
	# Single-player's collect toggle, and the unnamed static at the right edge.
	{"id": 135, "sheet": "GUI_MAIN_01", "rect": Rect2i(184, 230, 35, 25), "at": Vector2i(496, 743)},
	{"id": 82, "sheet": "GUI_MAIN_01", "rect": Rect2i(0, 0, 33, 33), "at": Vector2i(898, 686)},
	# The two small icons flanking the console.
	{"id": 40, "sheet": "GUI_MAIN_03", "rect": Rect2i(240, 201, 15, 17), "at": Vector2i(424, 690)},
	{"id": 41, "sheet": "GUI_MAIN_03", "rect": Rect2i(238, 183, 17, 17), "at": Vector2i(586, 690)},
]

## The five combat-art slots, ids 177..181. They form a shallow arc dipping UP
## at the centre, and the centre one sits at x 497 + 15 = 512, which is exactly
## half of 1024 -- the arithmetic checks itself.
const ART_SLOTS := [
	{"id": 177, "rect": Rect2i(129, 65, 31, 31), "at": Vector2i(435, 667)},
	{"id": 178, "rect": Rect2i(129, 98, 31, 31), "at": Vector2i(465, 653)},
	{"id": 179, "rect": Rect2i(129, 131, 31, 31), "at": Vector2i(497, 649)},
	{"id": 180, "rect": Rect2i(129, 164, 31, 31), "at": Vector2i(530, 653)},
	{"id": 181, "rect": Rect2i(129, 197, 31, 31), "at": Vector2i(560, 667)},
]
const ART_SHEET := "GUI_MAIN_05"

## THE TWO WINGS -- the ornamental rail the skill and spell slots sit on. Each
## side starts with its own anchor piece and then TILES outward, and retail
## alternates the follow-on pieces with `rand() & 1` so the ornament does not
## visibly repeat. This alternates deterministically instead: a recorded run
## has to replay identically, and a HUD that reshuffles its own woodwork every
## launch cannot be compared frame to frame.
##
## Left runs rightward from x 32 until it reaches the console; right runs
## leftward from x 890 until it does. Both step at the slot pitch.
const WING_LEFT := [
	{"id": 6, "rect": Rect2i(0, 56, 102, 19), "y": 747},
	{"id": 7, "rect": Rect2i(0, 76, 99, 17), "y": 749},
	{"id": 8, "rect": Rect2i(0, 94, 99, 16), "y": 750},
]
const WING_RIGHT := [
	{"id": 9, "rect": Rect2i(0, 111, 104, 19), "y": 747},
	{"id": 10, "rect": Rect2i(0, 131, 99, 18), "y": 748},
	{"id": 11, "rect": Rect2i(0, 150, 99, 18), "y": 748},
]
const WING_SHEET := "GUI_MAIN_03"
const WING_LEFT_X := 32
const WING_LEFT_END := 397        ## the console's left edge
const WING_RIGHT_X := 890
const WING_RIGHT_END := 532

## The skill and spell wings. Five slots each, 63x63, from gfx id 103 (empty).
## `x = 394 + 66*(i - n)` and `x = 640 + 66*i` with n the visible slot count,
## both at window y 15 -> screen 691.
const SLOT_EMPTY := {"id": 103, "sheet": "GUI_MAIN_01", "rect": Rect2i(19, 169, 63, 63)}
const SLOTS := 5
const SLOT_Y := 691
const SLOT_STEP := 66
const SKILL_X0 := 394 - SLOT_STEP * SLOTS      ## i - n with n = SLOTS
const SPELL_X0 := 640

## The day/night disc, loaded by NAME in the taskbar's constructor rather than
## through the gfx table, and drawn as a 56x56 quad.
const DISC := "GUI_DAYNIGHTDISC"
const DISC_SIZE := 56
const DISC_AT := Vector2i(477, 680)

var found := false
var drawn := 0                  ## pieces that resolved and were placed
var missing := PackedStringArray()

var _root: Control
var _text: Label


func _init(tex_pak) -> void:
	layer = 1
	_root = Control.new()
	_root.name = "Taskbar"
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	if tex_pak == null or not tex_pak.is_open():
		push_warning("Hud: texture.pak is not open -- no interface drawn")
		return
	var cache: Dictionary = {}
	for p in PIECES:
		_blit(tex_pak, cache, p["sheet"], p["rect"], p["at"])
	for a in ART_SLOTS:
		_blit(tex_pak, cache, ART_SHEET, a["rect"], a["at"])
	_wings(tex_pak, cache)
	for i in SLOTS:
		_blit(tex_pak, cache, SLOT_EMPTY["sheet"], SLOT_EMPTY["rect"],
			Vector2i(SKILL_X0 + SLOT_STEP * i, SLOT_Y))
		_blit(tex_pak, cache, SLOT_EMPTY["sheet"], SLOT_EMPTY["rect"],
			Vector2i(SPELL_X0 + SLOT_STEP * i, SLOT_Y))
	_disc(tex_pak)
	_build_text()
	found = drawn > 0


## The scale hook belongs here, not in _init: a CanvasLayer has no tree until
## it is added to one, so connecting in the constructor dereferences null.
func _ready() -> void:
	_rescale()
	# GUARDED: _ready runs again if this node is ever removed and re-added, and
	# a second connect to the same callable is an error.
	var vp := get_viewport()
	if vp != null and not vp.size_changed.is_connected(_rescale):
		vp.size_changed.connect(_rescale)


## One sub-rect of one sheet, placed at a canvas coordinate. A sheet that does
## not resolve is RECORDED and skipped, never substituted.
func _blit(tex_pak, cache: Dictionary, sheet: String, rect: Rect2i, at: Vector2i) -> void:
	var tex: Texture2D = cache.get(sheet)
	if tex == null:
		var id: int = Sacred.TextureFormat.find_model_texture(tex_pak, sheet)
		if id < 0:
			if not missing.has(sheet):
				missing.append(sheet)
			return
		var img := Sacred.decode_texture(tex_pak, id)
		if img == null:
			if not missing.has(sheet):
				missing.append(sheet)
			return
		tex = ImageTexture.create_from_image(img)
		cache[sheet] = tex
	var tr := TextureRect.new()
	tr.texture = AtlasTexture.new()
	(tr.texture as AtlasTexture).atlas = tex
	(tr.texture as AtlasTexture).region = Rect2(rect)
	tr.position = Vector2(at)
	tr.size = Vector2(rect.size)
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(tr)
	drawn += 1


## The day/night disc is a whole texture rather than a table rect.
func _disc(tex_pak) -> void:
	var id: int = Sacred.TextureFormat.find_model_texture(tex_pak, DISC)
	if id < 0:
		missing.append(DISC)
		return
	var img := Sacred.decode_texture(tex_pak, id)
	if img == null:
		missing.append(DISC)
		return
	var tr := TextureRect.new()
	tr.texture = ImageTexture.create_from_image(img)
	tr.position = Vector2(DISC_AT)
	tr.size = Vector2(DISC_SIZE, DISC_SIZE)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(tr)
	drawn += 1


## The console's text area. Retail's `UI_WND_CONSOLE` is {256, 640, 512, 128};
## this uses the same rect so quest-log lines land where retail puts them.
func _build_text() -> void:
	_text = Label.new()
	_text.position = Vector2(256, 596)
	_text.size = Vector2(512, 80)
	_text.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# ponytail: THE ONE CHOSEN NUMBER IN THIS FILE, and it is chosen against the
	# wrong typeface -- Godot's bundled default, not retail's. Every other
	# constant here carries an address in the binary; this one carries nothing.
	# It also decides where AUTOWRAP_WORD_SMART breaks, so the console will wrap
	# in different places than retail until both the font and this are
	# recovered from the same cUI_ code that gave up the rects.
	_text.add_theme_font_size_override(&"font_size", 13)
	_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_text)


## Shows a quest-log line. Retail's own marker for a break is `<n>`.
func show_line(text: String) -> void:
	if _text != null:
		_text.text = text.replace("<n>", "\n")


## Scales the fixed 1024x768 canvas to the window, letterboxing rather than
## stretching -- the HUD's own arithmetic assumes that aspect and nothing in
## the recovered layout re-anchors to a screen edge.
func _rescale() -> void:
	var win := Vector2(get_viewport().get_visible_rect().size)
	if win.x <= 0.0 or win.y <= 0.0:
		return
	var s := minf(win.x / float(CANVAS.x), win.y / float(CANVAS.y))
	_root.scale = Vector2(s, s)
	_root.position = Vector2(
		(win.x - float(CANVAS.x) * s) * 0.5,
		(win.y - float(CANVAS.y) * s) * 0.5)


## The two ornamental rails, tiled from their anchors outward. See WING_LEFT.
func _wings(tex_pak, cache: Dictionary) -> void:
	var i := 0
	var x := WING_LEFT_X
	while x < WING_LEFT_END:
		var p: Dictionary = WING_LEFT[0] if i == 0 else WING_LEFT[1 + (i % 2)]
		_blit(tex_pak, cache, WING_SHEET, p["rect"], Vector2i(x, int(p["y"])))
		x += SLOT_STEP
		i += 1
	i = 0
	x = WING_RIGHT_X
	while x > WING_RIGHT_END:
		var p2: Dictionary = WING_RIGHT[0] if i == 0 else WING_RIGHT[1 + (i % 2)]
		_blit(tex_pak, cache, WING_SHEET, p2["rect"], Vector2i(x, int(p2["y"])))
		x -= SLOT_STEP
		i += 1
