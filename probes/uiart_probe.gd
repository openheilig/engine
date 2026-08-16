extends SceneTree
## What UI art does texture.pak carry, and how big is each piece?
##
##   godot --headless --path . --script res://probes/uiart_probe.gd
##
## The HUD is the largest single thing the port does not draw, and the first
## question is whether retail's own art is reachable. cursor.gd already pulls
## MOUSE_MAIN.TGA out of this pak by name, so the mechanism is proven; what was
## missing is the NAMES and the SIZES.
##
## Answer: the whole HUD is here under a `GUI_` prefix -- GUI_MAIN_01..20 for
## the frame, GUI_HERO_<class>1..3 for the eight class portraits, GUI_BOOK_* for
## the quest log, GUI_DAYNIGHT* for the dial, plus a spell and combat-art icon
## per skill. This probe reports each piece's decoded dimensions, which is what
## a layout has to be built from.
const HUD := [
	"GUI_MAIN_01", "GUI_MAIN_02", "GUI_MAIN_03", "GUI_MAIN_04", "GUI_MAIN_05",
	"GUI_MAIN_06", "GUI_MAIN_07", "GUI_MAIN_08", "GUI_MAIN_09", "GUI_MAIN_10",
	"GUI_MAIN_11", "GUI_MAIN_12", "GUI_MAIN_13", "GUI_MAIN_14", "GUI_MAIN_15",
	"GUI_MAIN_16", "GUI_MAIN_17", "GUI_MAIN_18", "GUI_MAIN_19", "GUI_MAIN_20",
	"GUI_MAIN_ICONS", "GUI_MAIN_LOGO", "GUI_MAIN_ORNAMENT", "GUI_MAIN_ORNAMENT1",
	"GUI_HERO_SERA1", "GUI_HERO_SERA2", "GUI_HERO_SERA3",
	"GUI_HERO_GLAD1", "GUI_HERO_MAGE1", "GUI_HERO_DELF1", "GUI_HERO_WELF1",
	"GUI_HERO_DWA1", "GUI_HERO_VAMP1", "GUI_HERO_DAE1",
	"GUI_QBP_SERA", "GUI_BOOK_BASE1", "GUI_BOOK_TABS", "GUI_BOOK_CIRCLE",
	"GUI_DAYNIGHTDISC", "GUI_DAYNIGHTALPHA", "GUI_DAYNIGHTGLOW",
	"GUI_SPELL01", "GUI_MOVE_ATTACKE", "GUI_PORTRAIT00",
]


func _init() -> void:
	var install := Sacred.find_install()
	var pak := Sacred.Pak.new(install.path_join("pak/texture.pak"))
	if not pak.is_open():
		push_error("uiart_probe: texture.pak did not open")
		quit(1)
		return
	print("texture.pak\tentries=%d" % pak.count())
	print("name\tid\tw\th")
	var found := 0
	for nm in HUD:
		var id := Sacred.TextureFormat.find_model_texture(pak, nm)
		if id < 0:
			print("%s\t-1\t-\t-" % nm)
			continue
		var img := Sacred.decode_texture(pak, id)
		if img == null:
			print("%s\t%d\tundecoded" % [nm, id])
			continue
		found += 1
		print("%s\t%d\t%d\t%d" % [nm, id, img.get_width(), img.get_height()])
	print("uiart_probe\tresolved=%d/%d" % [found, HUD.size()])
	quit()
