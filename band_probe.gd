extends SceneTree
## Show how the arena camp's three tents (OZELT1/2/3) interleave into bands:
## if different buildings share a band, they share a depth_key -> mixed render.

var _world: Sacred.World
var _statics: Sacred.Statics
var _items: Sacred.Items
var _footprints: Sacred.Footprints

func _init() -> void:
	var install := Sacred.find_install()
	_world = Sacred.World.new(install.path_join("world"))
	_statics = Sacred.Statics.new(Sacred.Pak.new(install.path_join("world/static.pak")))
	_items = Sacred.Items.new(Sacred.Pak.new(install.path_join("pak/items.pak")))
	_footprints = Sacred.Footprints.new(_statics, _items)
	var gx := 53
	var gy := 28
	var stream := _world.sector(gx, gy)
	var cells := stream.slice(32, 32 + 64*64*32)
	var regions := Sacred.Regions.new(stream, gx, gy)
	var objs: Array = []
	for i in 64*64:
		var o := _statics.get_object(cells.decode_u32(i*32+4))
		if o.is_empty():
			continue
		var obj: Dictionary = o
		var fam := _items.family_of(obj["type"])
		if fam == "":
			continue
		objs.append({"fam": fam, "pos": obj["pos"], "i": i})
	objs.sort_custom(func(a, b):
		var pa: Vector2 = a["pos"]
		var pb: Vector2 = b["pos"]
		return pa.y > pb.y if not is_equal_approx(pa.y, pb.y) else pa.x < pb.x)
	var n := objs.size()
	const BAND_COUNT := 16
	print("band_probe\ttotal_levelled=%d" % n)
	# per band: which families, how many
	for b in range(BAND_COUNT):
		var fams: Dictionary = {}
		for i in range(n):
			if _band_of(i, n, BAND_COUNT) != b:
				continue
			var f: String = objs[i]["fam"]
			fams[f] = int(fams.get(f, 0)) + 1
		if fams.size() > 1:
			print("band_probe\tband=%d MIXED %s" % [b, fams])
	quit(0)


static func _band_of(i: int, n: int, bands: int) -> int:
	return mini(int(floor(float(i) * bands / n)), bands - 1)
