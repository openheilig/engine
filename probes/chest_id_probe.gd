extends SceneTree
## chest_id_probe.gd -- READ-ONLY. Identify the chapel chest.
##   godot --headless --path godot-port --script res://probes/chest_id_probe.gd
## Writes PNGs to user:// (NOT into the repo).

const CHAPEL := Rect2i(3213, 2502, 34, 30)

var install: String
var tex_pak: Sacred.Pak
var mixed: Sacred.Mixed

func _init() -> void:
	install = Sacred.find_install()
	var world := Sacred.World.new(install.path_join("world"))
	var static_pak := Sacred.Pak.new(install.path_join("world/static.pak"))
	var items_pak := Sacred.Pak.new(install.path_join("pak/items.pak"))
	var items := Sacred.Items.new(items_pak)
	mixed = Sacred.Mixed.new(Sacred.Pak.new(install.path_join("pak/mixed.pak")))
	tex_pak = Sacred.Pak.new(install.path_join("pak/texture.pak"))

	# --- 1. unnamed statics in sector 50,39 ---
	print("-- sector 50,39: statics whose items record has NO name --")
	var stream := world.sector(50, 39)
	var seen := {}
	var unnamed := {}
	var all: Array = []
	for c in Sacred.SECT * Sacred.SECT:
		var cur := stream.decode_u32(Sacred.NAME + c * Sacred.CELL + 4)
		var guard := {}
		while cur > 0 and cur < static_pak.count() and not guard.has(cur):
			guard[cur] = true
			if not seen.has(cur):
				seen[cur] = true
				var r := static_pak.blob(cur)
				var t := r.decode_u32(4)
				var pos := Vector2(r.decode_s32(0x0e), -r.decode_s32(0x12))
				var d := {"rec": cur, "type": t, "name": items.name_of(t),
					"sprite": items.sprite_of(t), "pos": pos,
					"cell": Sacred.Footprints._object_cell(pos), "f8": r.decode_u32(8)}
				all.append(d)
				if d["name"] == "":
					unnamed[t] = int(unnamed.get(t, 0)) + 1
			cur = static_pak.blob(cur).decode_u32(0x1f)
	print("   distinct unnamed types: %d, placements: %d" % [unnamed.size(),
		unnamed.values().reduce(func(a, b): return a + b, 0)])
	for t in unnamed:
		print("     type=%d sprite=%d x%d" % [t, items.sprite_of(t), unnamed[t]])

	# --- 2. every items.pak record named like a chest, anywhere ---
	print("\n-- ALL items.pak records with chest-ish names --")
	for i in items_pak.count():
		var nm := items.name_of(i).to_lower()
		if nm.begins_with("chest") or nm.contains("truhe") or nm.contains("kiste") \
				or nm.contains("coffer") or nm.contains("schatz"):
			var sp := mixed.sprite(items.sprite_of(i))
			print("   rec=%-6d sprite=%-6d tiles=%-3d size=%-10s  %s" % [
				i, items.sprite_of(i), 0 if sp.is_empty() else (sp["tiles"] as Array).size(),
				"-" if sp.is_empty() else str(sp["size"]), items.name_of(i)])

	# --- 3. the NW quadrant of the chapel nave, everything, sorted by screen y ---
	print("\n-- chapel statics sorted by screen pos (iso north-west first) --")
	var inch: Array = []
	for d in all:
		if CHAPEL.has_point(d["cell"]):
			inch.append(d)
	inch.sort_custom(func(a, b): return (a["pos"] as Vector2).y > (b["pos"] as Vector2).y)
	var shown := 0
	for d in inch:
		var sp := mixed.sprite(d["sprite"])
		var nm: String = d["name"]
		if nm.begins_with("KLOSTER_KAPELLE01"):
			continue
		shown += 1
		if shown > 70:
			break
		print("   scr=(%7d,%7d) cell=%s tiles=%-3d %s" % [
			int((d["pos"] as Vector2).x), int(-(d["pos"] as Vector2).y), str(d["cell"]),
			0 if sp.is_empty() else (sp["tiles"] as Array).size(), nm])

	# --- 4. render candidate sprites ---
	for pair in [[666, "chest2"], [634, "cabinet3"], [677, "crates2"], [680, "crates5"],
			[789, "sack2"], [711, "panel"], [21211, "mini_blue_1"], [21214, "mini_blue_4"],
			[671, "coalpot1"], [2111, "grave16"]]:
		_render(pair[0], pair[1])
	print("\nPNGs written to: %s" % ProjectSettings.globalize_path("user://"))
	quit(0)


func _render(sid: int, tag: String) -> void:
	var sp := mixed.sprite(sid)
	if sp.is_empty():
		print("   sprite %d (%s): no art" % [sid, tag])
		return
	var size: Vector2i = sp["size"]
	var img := Image.create(maxi(size.x, 1), maxi(size.y, 1), false, Image.FORMAT_RGBA8)
	for tile: Dictionary in sp["tiles"]:
		var tex := Sacred.decode_texture(tex_pak, tile["tex"], false)
		if tex == null:
			continue
		var src: Rect2 = tile["src"]
		var dst: Rect2i = tile["dst"]
		var sr := Rect2i(int(round(src.position.x * tex.get_width())),
			int(round(src.position.y * tex.get_height())),
			maxi(dst.size.x, 1), maxi(dst.size.y, 1))
		img.blit_rect(tex, sr, dst.position)
	var p := "user://sprite_%d_%s.png" % [sid, tag]
	img.save_png(p)
	print("   wrote %s (%dx%d, %d tiles)" % [p, size.x, size.y, (sp["tiles"] as Array).size()])
