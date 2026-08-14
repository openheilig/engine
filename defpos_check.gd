extends "res://check.gd"
## defpos_check.gd -- the ONE runnable check for bin/TYPE_NPC_*/DefPos.bin,
## the per-hero-class table of NAMED WORLD POSITIONS (quest markers, NPC spawn
## points, teleport sources and targets).
##
##   godot --headless --path godot-port --script defpos_check.gd
##
## Layout, measured 2026-08-13 for type_npc_seraphim (599,832 B):
##   12-byte header {u32 1234, u32 1908, u32 0}
##   then 5998 records of 100 bytes, 20 bytes of tail
##   +0x00 name, NUL-padded, longest observed 30 chars
##   +0x40 u32 world cell X    +0x44 u32 world cell Y
##   +0x48/+0x4c u32 0xFFFFFFFF on every record seen (unset/no parent)
##   +0x0c 4, +0x18 22, +0x50 22, +0x54 4096 -- constant across records
##   +0x10/+0x14/+0x1c.. hold POINTER-shaped values (0x00A184A8, 0x00BBA568,
##   and a +0x28 field rising by exactly 26 per record), i.e. this file is a
##   dumped in-memory struct array. Those are dead addresses, not data.
##
## Only the NAME and the CELL are usable, and they are enough: the file says
## WHERE things stand and what they are called. It does NOT carry a creature id
## or a model, so it does not by itself finish the NPC appearance question.
const HEADER := 12
const REC := 100
const CX := 0x40
const CY := 0x44

func _init() -> void:
	super()
	var install := Sacred.find_install()
	var path := install.path_join("bin/type_npc_seraphim/defpos.bin")
	var b := FileAccess.get_file_as_bytes(path)
	assert(b.size() == 599832, "defpos.bin size moved: %d" % b.size())
	assert(b.decode_u32(0) == 1234 and b.decode_u32(4) == 1908,
		"header moved: %d,%d" % [b.decode_u32(0), b.decode_u32(4)])
	var n := (b.size() - HEADER) / REC
	assert(n == 5998, "record count moved: %d" % n)

	# The stride is what fixes the layout: names must land on it.
	var named := 0
	var in_world := 0
	var by_name: Dictionary = {}
	for i in n:
		var o := HEADER + i * REC
		var nm := b.slice(o, o + 32).get_string_from_ascii()
		if nm != "":
			named += 1
			by_name[nm] = Vector2i(b.decode_u32(o + CX), b.decode_u32(o + CY))
		var cx := b.decode_u32(o + CX)
		var cy := b.decode_u32(o + CY)
		if cx < 6400 and cy < 6400:
			in_world += 1
	# MEASURED, not guessed: 4457 of 5998 records carry a name, so about a
	# quarter of the table is empty slots. What proves the stride is that the
	# names land ON it -- a wrong stride would score near zero here, not 74%.
	assert(named > 4000, "only %d of %d records carry a name -- the stride is wrong" % [named, n])
	assert(in_world > 3000,
		"only %d of %d records hold an in-world cell -- +0x40/+0x44 are not the coordinates" % [
			in_world, n])

	# Two anchors at the Seraphim start, which is cell 3236,2511 in the chapel
	# whose region rect is 3213..3246 x 2502..2531.
	assert(by_name.has("pos_seratelehier30"),
		"the Seraphim arrival marker is gone -- name field or stride moved")
	var tele: Vector2i = by_name["pos_seratelehier30"]
	assert(absi(tele.x - 3236) < 8 and absi(tele.y - 2511) < 8,
		"pos_seratelehier30 should sit beside the Seraphim spawn, got %s" % tele)
	assert(by_name.has("novizin1"), "the chapel novice is gone")
	var nov: Vector2i = by_name["novizin1"]
	assert(nov.x >= 3213 and nov.x <= 3246 and nov.y >= 2502 and nov.y <= 2531,
		"novizin1 should stand inside the chapel footprint, got %s" % nov)

	print("defpos_check\tOK\trecords=%d\tnamed=%d\tin_world=%d\ttele=%s\tnovizin1=%s" % [
		n, named, in_world, tele, nov])
	finish(0)
