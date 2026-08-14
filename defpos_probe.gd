extends SceneTree
## Probe: decode bin/TYPE_NPC_*/DefPos.bin. Names sit at file offsets 12, 112,
## 212, ... so the shape is a 12-byte header then 100-byte records with the
## name at +0. Tests whether +68/+72 are WORLD CELL COORDINATES, which is what
## record 0 ("hauptmann3" at 3349, 2534) looks like next to the known Seraphim
## start at cell 3236,2511. Read-only.
##   godot --headless --path godot-port --script res://defpos_probe.gd
const HEADER := 12
const REC := 100
const NAME_LEN := 64        ## upper bound; the real field is measured below

func _init() -> void:
	var install := Sacred.find_install()
	var which := OS.get_environment("CLASS")
	if which == "":
		which = "type_npc_seraphim"
	var b := FileAccess.get_file_as_bytes(install.path_join("bin/%s/defpos.bin" % which))
	print("file\t%s\tsize=%d\thdr=%d,%d,%d" % [
		which, b.size(), b.decode_u32(0), b.decode_u32(4), b.decode_u32(8)])
	var n := (b.size() - HEADER) / REC
	print("records\t%d\ttail_bytes=%d" % [n, b.size() - HEADER - n * REC])

	# Name field length: distance from name start to the first field that is
	# clearly not text, measured as the longest name actually present.
	var longest := 0
	for i in n:
		var o := HEADER + i * REC
		var s := b.slice(o, o + NAME_LEN).get_string_from_ascii()
		longest = maxi(longest, s.length())
	print("name\tlongest=%d" % longest)

	# Coordinate pair at +64/+68.
	var in_world := 0
	var lo := Vector2i(1 << 30, 1 << 30)
	var hi := Vector2i(-1, -1)
	var sectors: Dictionary = {}
	for i in n:
		var o := HEADER + i * REC
		var cx := b.decode_u32(o + 64)
		var cy := b.decode_u32(o + 68)
		if cx < 6400 and cy < 6400:
			in_world += 1
			lo.x = mini(lo.x, cx); lo.y = mini(lo.y, cy)
			hi.x = maxi(hi.x, cx); hi.y = maxi(hi.y, cy)
			sectors[(cy / Sacred.SECT) * 100 + (cx / Sacred.SECT)] = true
	print("coords\tin_world_range=%d of %d\tmin=%s\tmax=%s\tdistinct_sectors=%d" % [
		in_world, n, lo, hi, sectors.size()])

	# First records in full, so the field layout is visible rather than asserted.
	for i in range(0, mini(n, 6)):
		var o := HEADER + i * REC
		var parts: Array = []
		for f in range(12, REC, 4):
			parts.append("+%d=%d" % [f, b.decode_u32(o + f)])
		print("rec\t%d\tname=%s\t%s" % [
			i, b.slice(o, o + 24).get_string_from_ascii(), " ".join(parts)])

	# Is the chapel sector represented? The Seraphim starts at cell 3236,2511.
	var near := 0
	for i in n:
		var o := HEADER + i * REC
		var cx := b.decode_u32(o + 64)
		var cy := b.decode_u32(o + 68)
		if absi(cx - 3236) < 40 and absi(cy - 2511) < 40:
			near += 1
			if near <= 12:
				print("near_start\t%s\tcell=%d,%d" % [
					b.slice(o, o + 24).get_string_from_ascii(), cx, cy])
	print("near_start_total=%d" % near)
	quit()
