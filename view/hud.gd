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
## THE LIFE GAUGE IS THE PORTRAIT RING, and this file draws it (row 1039).
## All 46 functions of cUI_Taskbar2 were enumerated and the class references no
## orb, globe or fill-bar art and computes no fraction or scissor rect -- which
## is not a gap in the enumeration but the answer to it. The gauge was never in
## the taskbar. It is the portrait window, and its art is the pair below:
## GUI_MAIN_02's 95x107 block at (0,0) is the FULL state and (95,0) the EMPTY
## one. An earlier draft of this header assigned those two to the mercenary
## window; that is RETRACTED and the pixels say so.
##
## THERE IS NO MANA GAUGE, and that is retail's design rather than a gap in
## this file (row 1042). Sacred has no mana pool: its six attributes are
## Strength, Endurance, Dexterity, PHYSICAL REGENERATION, MENTAL REGENERATION
## and Charisma, and what a spell costs is TIME, not points. The element table
## names 1446 pieces and not one of them is a mana anything; the resource shows
## up on the combat-art slots instead, as UI_ACTION_GRAYED while an art
## regenerates against UI_ACTION / UI_ACTION_BRIGHT when it is ready. So an orb
## here would not be a missing feature -- it would be an invented one.
##
## Nothing here reads a simulation type (R10.2): the caller pushes values in.

## The virtual canvas the whole interface is authored against.
const UiElements := preload("res://formats/ui_elements.gd")

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
	# Single-player's collect toggle.
	{"id": 135, "sheet": "GUI_MAIN_01", "rect": Rect2i(184, 230, 35, 25), "at": Vector2i(496, 743)},
	# GONE: id 82, a 33x33 button this file placed at (898, 686) and called
	# "the unnamed static at the right edge". Retail's spawn frame draws bare
	# cobblestones there -- the button belongs to some other window's state,
	# not to the taskbar at rest, and 33x33 of interface over open ground is a
	# thing the two-engine compare charges for. Put back only with a retail
	# frame that shows it.
	# The two small icons flanking the console.
	{"id": 40, "sheet": "GUI_MAIN_03", "rect": Rect2i(240, 201, 15, 17), "at": Vector2i(424, 690)},
	{"id": 41, "sheet": "GUI_MAIN_03", "rect": Rect2i(238, 183, 17, 17), "at": Vector2i(586, 690)},
]

## THE PORTRAIT WINDOW, top right -- the hero's frame and the bar under it.
##
## Not from the gfx table but from a PIXEL MATCH, and it is exact: the whole
## 95x107 block at GUI_MAIN_02's own origin, laid at (928, 17), reproduces
## retail's frame ring, its horned finial and the leafwork down its right side
## to the pixel. 95x107 is the size this file's header already named as the
## two "orb-looking" elements of that sheet -- it was right about the size and
## wrong about the window.
##
## THE INTERIOR IS TRANSPARENT AND STAYS THAT WAY. Retail renders the hero's
## bust live inside the ring; the port has no render-to-texture for it yet, so
## the frame is drawn and the middle shows the world through. That is the
## honest partial: the frame is transcribed, the portrait is missing, and
## nothing here invents a face.
const PORTRAIT := [
	{"sheet": "GUI_MAIN_02", "rect": Rect2i(0, 0, 95, 107), "at": Vector2i(932, 15)},
]

## THE RING IS THE LIFE GAUGE. The block above is its FULL state; the block
## beside it on the sheet, (95,0,95,107), is the EMPTY one. Diffing the two
## gives 3814 pixels that differ -- the band -- against 236 that are identical,
## so the two blocks are the same frame painted red and grey and the band is
## the gauge.
##
## THE BOUNDARY IS SYMMETRIC AND HORIZONTAL. Classifying every band pixel of a
## retail frame as nearer the red art or the grey art puts red below y 54 and
## grey above it, on BOTH sides at the same height. Row 1039 described this as
## "an arc anchored at about +32 degrees from bottom-centre whose far end
## sweeps away"; that is wrong. Nothing is anchored off-centre and no single
## end moves -- the two ends move together, mirrored about bottom-centre.
##
## ponytail: the fill LAW is undetermined and this takes the simpler half.
## Red area is very nearly linear in the hit-point fraction (measured 0.541
## 0.371 0.200 0.000 against 0.529 0.345 0.210 0.042), and BOTH a height-
## proportional waterline and an arc-proportional sweep reproduce that series
## to a mean error of 0.026 -- the SAME error, to three places. The band is
## near-uniform per angle (395..471 px in six 30-degree bins), which is why:
## over a uniform annulus, arc length and height are nearly the same function.
## This slices by HEIGHT because a slice is two rects and a sweep is a shader.
## If a frame ever separates them, only `split` below changes.
## `UI_CHR_HEALTH_02` -- x 96, NOT 95. Retail's own element table gives
## (96,0)-(191,107) and the one-pixel error is worth the note: aligning the two
## blocks at 95 shifts the empty ring against the full one, which invents a
## differing pixel at every edge in the art and drops the agreement with
## retail's frame from 97.3% to 87.5%.
const RING_EMPTY := Rect2i(96, 0, 95, 107)
## The band's own extent inside the 107-tall block, measured off the art: the
## two blocks differ on 2580 pixels and agree on 1618, and the differing set
## spans rows 10..102 and columns 0..84 ONLY. The finial and the leafwork down
## the right side are identical in both, so they are frame, not gauge -- the
## waterline runs between these rows and nowhere near the block's own 0..107.
const RING_TOP := 10
const RING_BOTTOM := 102

## The five potion slots, ids 177..181. They form a shallow arc dipping UP at
## the centre, and the centre one sits at x 497 + 15 = 512, which is exactly
## half of 1024 -- the arithmetic checks itself.
##
## THE RECT IS THE SLOT'S CONTENTS, NOT THE SLOT. Column 129 of GUI_MAIN_05
## holds five DIFFERENT potions stacked vertically -- red, blue, green, purple,
## amber -- and taking one per slot down the column drew the belt as though the
## hero carried a full rainbow of them. Retail's spawn frame carries ONE, and
## the four it does not carry show a single shared EMPTY flask at (195, 65).
##
## Measured, not guessed: matching retail's own 31x31 at each of these five
## screen positions against every GUI sheet returns (129,65) for the first and
## (195,65) for all four others, at a mean per-channel error under 1.0 -- which
## is the art, not a resemblance. The positions above are confirmed by the same
## match.
const POTION_EMPTY := Rect2i(195, 65, 31, 31)
const ART_SLOTS := [
	{"id": 177, "rect": Rect2i(129, 65, 31, 31), "at": Vector2i(435, 667)},
	{"id": 178, "rect": POTION_EMPTY, "at": Vector2i(465, 653)},
	{"id": 179, "rect": POTION_EMPTY, "at": Vector2i(497, 649)},
	{"id": 180, "rect": POTION_EMPTY, "at": Vector2i(530, 653)},
	{"id": 181, "rect": POTION_EMPTY, "at": Vector2i(560, 667)},
]
const ART_SHEET := "GUI_MAIN_05"

## THE TWO WINGS -- the ornamental rail the skill and spell slots sit on. Each
## side starts with its own anchor piece and then TILES outward, and retail
## alternates the follow-on pieces with `rand() & 1` so the ornament does not
## visibly repeat. This alternates deterministically instead: a recorded run
## has to replay identically, and a HUD that reshuffles its own woodwork every
## launch cannot be compared frame to frame.
##
## THE RAIL IS AS LONG AS THERE ARE SLOTS TO CARRY. Each side BUTTS AGAINST
## THE CONSOLE and tiles outward one piece per slot at the slot pitch -- it is
## not a full-width border. Retail's spawn frame is the measurement: the right
## rail ends at 732 and this rule puts it at 627 + 104 = 731, to the pixel.
## Tiling from a fixed x 32 / x 890 instead drew ten spurious pieces across
## bare terrain, which the two-engine compare charged 13% of the whole frame
## delta to (row 1015).
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
const CONSOLE_LEFT := 397         ## the console's left edge -- left rail butts here
const CONSOLE_RIGHT := 627        ## 397 + 230 -- right rail starts here

## The skill and spell wings, 63x63 each, from gfx id 103 (empty).
## `x = 394 + 66*(i - n)` and `x = 640 + 66*i` with n the visible slot count,
## both at window y 15 -> screen 691.
const SLOT_EMPTY := {"id": 103, "sheet": "GUI_MAIN_01", "rect": Rect2i(19, 169, 63, 63)}

## HOW MANY SLOTS ARE DRAWN, and it is the ASSIGNED count rather than a fixed
## five. `x = 394 + 66*(i - n)` makes n readable straight off a frame: retail's
## spawn capture puts the leftmost skill slot at 328, and 394 - 66n = 328 gives
## n = 1. The spell side agrees independently -- `640 + 66*i` would put a
## second spell slot at 706 and retail draws bare wall there. Five empty rings
## a side was eight sprites of 63x63 painted over open terrain, 4% of the whole
## screen (row 1015).
##
## ponytail: a constant, not a query against the hero's art list, because
## nothing in the port assigns arts yet. When it does, this reads from there.
const SLOTS := 1
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
## Kept so element-table draws can share the sheets _init already decoded.
var _tex_pak
var _tex_cache: Dictionary = {}
## The two halves of the life gauge: the red block sliced to the bottom
## `health` of the band, the grey one filling the drained top.
var _ring_full: TextureRect = null
var _ring_empty: TextureRect = null


func _init(tex_pak) -> void:
	layer = 1
	_tex_pak = tex_pak
	_root = Control.new()
	_root.name = "Taskbar"
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	if tex_pak == null or not tex_pak.is_open():
		push_warning("Hud: texture.pak is not open -- no interface drawn")
		return
	var cache: Dictionary = {}
	_tex_cache = cache
	for p in PIECES:
		_blit(tex_pak, cache, p["sheet"], p["rect"], p["at"])
	for w in PORTRAIT:
		_ring_full = _blit(tex_pak, cache, w["sheet"], w["rect"], w["at"])
	# The drained half. NOT counted in `drawn` and starts hidden: at full
	# health retail shows the red block alone, so a fresh run must put the same
	# pixels on screen as before this gauge existed -- the capture runbooks
	# assert an md5 of the frame.
	if _ring_full != null:
		_ring_empty = _blit(tex_pak, cache, PORTRAIT[0]["sheet"], RING_EMPTY,
			PORTRAIT[0]["at"], false)
		if _ring_empty != null:
			_ring_empty.visible = false
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
func _blit(tex_pak, cache: Dictionary, sheet: String, rect: Rect2i, at: Vector2i,
		count := true) -> TextureRect:
	var tex: Texture2D = cache.get(sheet)
	if tex == null:
		var id: int = Sacred.TextureFormat.find_model_texture(tex_pak, sheet)
		if id < 0:
			if not missing.has(sheet):
				missing.append(sheet)
			return null
		var img := Sacred.decode_texture(tex_pak, id)
		if img == null:
			if not missing.has(sheet):
				missing.append(sheet)
			return null
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
	if count:
		drawn += 1
	return tr


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
	# RESIZE THE IMAGE, DO NOT ASK THE CONTROL TO SHRINK. `tr.size = 56` loses:
	# a TextureRect's minimum size comes from its texture and the recalculation
	# is DEFERRED, so the assignment is clamped straight back up to the
	# texture's own 128x128 -- which drew the dial as a 128px night-sky annulus
	# across the whole console, five times its area. Measured, not reasoned:
	# the live node read size=(128,128) while this file said 56, and it still
	# did with the assignment moved after add_child. Baking the size into the
	# image leaves the layout nothing to override.
	img.resize(DISC_SIZE, DISC_SIZE, Image.INTERPOLATE_BILINEAR)
	var tr := TextureRect.new()
	tr.texture = ImageTexture.create_from_image(img)
	tr.position = Vector2(DISC_AT)
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
	for i in SLOTS:
		var p: Dictionary = WING_LEFT[0] if i == 0 else WING_LEFT[1 + (i % 2)]
		var pw: int = (p["rect"] as Rect2i).size.x
		_blit(tex_pak, cache, WING_SHEET, p["rect"],
			Vector2i(CONSOLE_LEFT - pw - SLOT_STEP * i, int(p["y"])))
		var q: Dictionary = WING_RIGHT[0] if i == 0 else WING_RIGHT[1 + (i % 2)]
		_blit(tex_pak, cache, WING_SHEET, q["rect"],
			Vector2i(CONSOLE_RIGHT + SLOT_STEP * i, int(q["y"])))


## Push the hero's life fraction in, 0.0..1.0. THE CALLER SUPPLIES IT: nothing
## here reads a simulation type or owns a frame loop (R10.2), and this class
## has no opinion about which hit-point slot the number came from -- retail's
## own choice between creature +0x4C8 and +0x4D0 is still unsettled (row 1038).
##
## Defaults to full and stays there until called, which is both what retail
## draws at spawn and a no-op against every frame captured so far.
## The hero's assigned-art slot, rendered with the art's own element triple
## (row 1043 / sub_85E676A): EMPTY fills the top of the waterline, LOAD the
## bottom, and a ready+selected slot draws FULL whole. WHICH side the slot
## sits on comes from retail's own element names: a UI_SPELL_* triple goes to
## the spell column at SPELL_X0, anything else to the skill column at
## SKILL_X0. An art with no triple draws no slot at all -- art 18 is one.
var _art_clip: Control = null
var _art_icon_rect: TextureRect = null
var _ui: UiElements = null
var _art_elements: Array = []
var _art_selected := false
var _slot_rects: Array[TextureRect] = []

## One element table per Hud, built on demand -- main.gd never names the
## class, so no second preload site exists.
func ui_elements(install: String, tex_pak) -> UiElements:
	if _ui == null:
		_ui = UiElements.new(install, tex_pak)
	return _ui

func set_art_slot(ui: UiElements, elements: Array, fraction: float) -> void:
	print("articon\thud set_art_slot elements=", elements, " root=", _root != null)
	if _root == null or ui == null or not ui.found() or elements.is_empty():
		return
	if _art_clip != null:
		_art_clip.queue_free()
		_art_clip = null
	# The side is retail's own naming, not a choice: any UI_SPELL_ element
	# marks the spell column.
	var spell := false
	for e in elements:
		if ui.name(int(e)).begins_with("UI_SPELL"):
			spell = true
			break
	var x0 := SPELL_X0 if spell else SKILL_X0
	_art_elements = elements
	_ui = ui
	# One assigned art IS the selected slot (there is nothing else to select);
	# sub_85E676A draws element[2] whole only for the selected one.
	_art_selected = true
	_draw_art_slot(Vector2i(x0, SLOT_Y), clampf(fraction, 0.0, 1.0))

func _draw_art_slot(at: Vector2i, f: float) -> void:
	var ready := f >= 1.0 and _art_selected
	var wanted: Array = []
	if ready and _art_elements.size() >= 3:
		# Ready AND selected draws element[2] whole (sub_85E676A's f>=1 branch).
		wanted = [[int(_art_elements[2]), Rect2i(0, 0, 63, 63), Vector2i.ZERO]]
	elif _art_elements.size() >= 2:
		var split := int(round(63.0 * (1.0 - f)))
		if split > 0:
			wanted.append([int(_art_elements[0]),
				Rect2i(0, 0, 63, split), Vector2i.ZERO])
		if split < 63:
			wanted.append([int(_art_elements[1]),
				Rect2i(0, split, 63, 63 - split), Vector2i(0, split)])
	# Reuse nodes across frames: _sync_hud_health calls in every frame, and
	# stacking fresh TextureRects per frame would leak them.
	if _slot_rects.size() != wanted.size():
		for tr in _slot_rects:
			tr.queue_free()
		_slot_rects.clear()
		for piece in wanted:
			var tr := _blit_element(_ui, piece[0], at + piece[2])
			if tr != null:
				_slot_rects.append(tr)
	for i in mini(_slot_rects.size(), wanted.size()):
		var tr: TextureRect = _slot_rects[i]
		_slice(tr, Rect2i(ui_element_rect(wanted[i][0]).position + (wanted[i][1] as Rect2i).position, (wanted[i][1] as Rect2i).size), at + (wanted[i][2] as Vector2i))

func ui_element_rect(id: int) -> Rect2i:
	return _ui.rect(id)

func _blit_element(ui: UiElements, id: int, at: Vector2i) -> TextureRect:
	if not ui.has(id):
		missing.append("element %d" % id)
		return null
	var sname := ui.sheet_name(id)
	var key := sname.get_basename()
	if not _tex_cache.has(key):
		var tex := ui.sheet(id, _tex_pak, _tex_cache)
		if tex == null:
			missing.append(sname)
			return null
		_tex_cache[key] = tex
	return _blit(_tex_pak, _tex_cache, key, ui.rect(id), at, false)

func _blit_element_slice(ui: UiElements, id: int, at: Vector2i,
		src: Rect2i, dst: Vector2i) -> TextureRect:
	if not ui.has(id):
		missing.append("element %d" % id)
		return null
	var sname := ui.sheet_name(id)
	var key := sname.get_basename()
	if not _tex_cache.has(key):
		var tex := ui.sheet(id, _tex_pak, _tex_cache)
		if tex == null:
			missing.append(sname)
			return null
		_tex_cache[key] = tex
	var piece := ui.rect(id)
	return _blit(_tex_pak, _tex_cache, key,
		Rect2i(piece.position + src.position, src.size), at + dst, false)

## Legacy single-texture entry point, kept for the one caller that has no
## element table -- it draws the skill side as before.
func set_art_icon(tex: Texture2D) -> void:
	print("articon\thud set_art_icon tex=", tex, " root=", _root != null)
	if tex == null or _root == null:
		return
	if _art_clip != null:
		_art_clip.queue_free()
		_art_clip = null
	_art_clip = Control.new()
	_art_clip.clip_contents = true
	_art_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_art_clip.position = Vector2(SKILL_X0, SLOT_Y)
	_art_clip.size = Vector2(63, 63)
	_root.add_child(_art_clip)
	_art_icon_rect = TextureRect.new()
	_art_icon_rect.texture = tex
	_art_icon_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_art_icon_rect.size = Vector2(63, 63)
	_art_icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_art_clip.add_child(_art_icon_rect)
	_art_icon_rect.position = Vector2.ZERO
	print("articon\tclip at ", _art_clip.position, " size ", _art_clip.size)

## The regenerated fraction, 0..1: the slot refills bottom-up. At 1.0 the
## whole LOAD state shows (retail's spawn frame state — the art is ready).
func set_art_fraction(f: float) -> void:
	if _ui == null or _art_elements.is_empty():
		return
	var spell := false
	for e in _art_elements:
		if _ui.name(int(e)).begins_with("UI_SPELL"):
			spell = true
			break
	_draw_art_slot(Vector2i(SPELL_X0 if spell else SKILL_X0, SLOT_Y),
		clampf(f, 0.0, 1.0))


func set_health(frac: float) -> void:
	if _ring_full == null:
		return
	var f := clampf(frac, 0.0, 1.0)
	var rect: Rect2i = PORTRAIT[0]["rect"]
	var at: Vector2i = PORTRAIT[0]["at"]
	# The waterline, in the block's own rows. f = 1 puts it at the band's top
	# edge and f = 0 at its bottom, so the slice is never inverted.
	# The span is one row LONGER than the band so the ends are exact: f = 1 puts
	# the waterline at the band's first row and f = 0 one past its last, which
	# is the difference between an empty gauge and an empty gauge with one lit
	# row left in it.
	var split := RING_TOP + roundi((1.0 - f) * float(RING_BOTTOM + 1 - RING_TOP))
	_slice(_ring_full, Rect2i(rect.position.x, rect.position.y + split,
		rect.size.x, rect.size.y - split), Vector2i(at.x, at.y + split))
	if _ring_empty == null:
		return
	# Nothing drained -> draw no grey at all rather than a zero-height rect
	# under the red, which would blend the red's soft edge against grey instead
	# of against the world and move pixels at full health.
	_ring_empty.visible = split > RING_TOP
	if _ring_empty.visible:
		_slice(_ring_empty, Rect2i(RING_EMPTY.position.x, RING_EMPTY.position.y,
			RING_EMPTY.size.x, split), at)


## Repoint one already-placed piece at a sub-rect of its own sheet.
func _slice(tr: TextureRect, region: Rect2i, at: Vector2i) -> void:
	(tr.texture as AtlasTexture).region = Rect2(region)
	tr.position = Vector2(at)
	tr.size = Vector2(region.size)
