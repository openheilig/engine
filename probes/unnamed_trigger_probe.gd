extends SceneTree
## unnamed_trigger_probe.gd -- READ-ONLY. The 490 live triggers whose target
## static names an UNNAMED items.pak record: what type ids are they, and are any
## near the Silver Creek chapel?
##   godot --headless --path godot-port --script res://probes/unnamed_trigger_probe.gd

const BASE := 0x10c
const STRIDE := 16

func _init() -> void:
	var install := Sacred.find_install()
	var static_pak := Sacred.Pak.new(install.path_join("world/static.pak"))
	var items_pak := Sacred.Pak.new(install.path_join("pak/items.pak"))
	var items := Sacred.Items.new(items_pak)
	var mixed := Sacred.Mixed.new(Sacred.Pak.new(install.path_join("pak/mixed.pak")))
	var tf := FileAccess.open(install.path_join("world/triggers.pak"), FileAccess.READ)
	tf.seek(4)
	var tn := tf.get_32()
	tf.seek(0)
	var t := tf.get_buffer(tf.get_length())

	var types := {}
	var chapel: Array = []
	for i in tn:
		var o := BASE + i * STRIDE
		if t.decode_u16(o + 4) != 16:
			continue
		var v := t.decode_u32(o + 6)
		if v <= 0 or v >= static_pak.count():
			continue
		var r := static_pak.blob(v)
		var typ := r.decode_u32(4)
		if items.name_of(typ) != "":
			continue
		types[typ] = int(types.get(typ, 0)) + 1
		var cell := Sacred.Footprints._object_cell(Vector2(r.decode_s32(0x0e), -r.decode_s32(0x12)))
		if absi(cell.x - 3230) <= 60 and absi(cell.y - 2517) <= 60:
			chapel.append([i, v, typ, cell])
	print("unnamed-target live triggers: %d, distinct types: %d" % [
		types.values().reduce(func(a, b): return a + b, 0), types.size()])
	var k: Array = types.keys()
	k.sort()
	print("  type ids: %s" % str(k))
	print("  type -> sprite/tiles:")
	for x: int in k:
		var sp := mixed.sprite(items.sprite_of(x))
		print("    type=%-6d count=%-4d sprite=%-6d tiles=%d  itemrec_bytes=%s" % [
			x, types[x], items.sprite_of(x),
			0 if sp.is_empty() else (sp["tiles"] as Array).size(),
			_hex(items_pak.blob(x).slice(0, 32))])
	print("  within 60 cells of the chapel: %d" % chapel.size())
	for c: Array in chapel:
		print("    trig=%-6d static=%-8d type=%-6d cell=%s" % [c[0], c[1], c[2], str(c[3])])
	quit(0)

func _hex(b: PackedByteArray) -> String:
	var s := ""
	for i in b.size():
		s += "%02x" % b[i]
		if i % 4 == 3:
			s += " "
	return s
