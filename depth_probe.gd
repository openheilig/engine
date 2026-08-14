extends SceneTree
## Verify per-run depth keys are unique within each band (no more mixed
## buildings sharing a sorting_offset).

var _world: Sacred.World
var _statics: Sacred.Statics
var _items: Sacred.Items
var _footprints: Sacred.Footprints
var _mixed: Sacred.Mixed

func _init() -> void:
	var install := Sacred.find_install()
	_world = Sacred.World.new(install.path_join("world"))
	_statics = Sacred.Statics.new(Sacred.Pak.new(install.path_join("world/static.pak")))
	_items = Sacred.Items.new(Sacred.Pak.new(install.path_join("pak/items.pak")))
	_footprints = Sacred.Footprints.new(_statics, _items)
	_mixed = Sacred.Mixed.new(Sacred.Pak.new(install.path_join("pak/mixed.pak")))
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
		if _items.family_of(obj["type"]) == "":
			continue
		objs.append(obj)
	objs.sort_custom(func(a, b):
		var pa: Vector2 = a["pos"]
		var pb: Vector2 = b["pos"]
		return pa.y > pb.y if not is_equal_approx(pa.y, pb.y) else pa.x < pb.x)
	var n := objs.size()
	const BAND_COUNT := 16
	var band_repr: Array[float] = []
	for _b in BAND_COUNT:
		band_repr.append(0.0)
	for i in n:
		var b := _band_of(i, n, BAND_COUNT)
		if band_repr[b] == 0.0:
			band_repr[b] = _ground_depth(objs[i]["pos"])
	for b in range(1, BAND_COUNT):
		if band_repr[b] <= band_repr[b - 1]:
			band_repr[b] = band_repr[b - 1] + 0.001
	# build runs with the new tie-break
	var runs: Array = []
	var prev := ""
	var run: Dictionary = {}
	var run_tie := 0.0
	var tie_band := -1
	for i in n:
		var obj: Dictionary = objs[i]
		var b := _band_of(i, n, BAND_COUNT)
		var fam := _items.family_of(obj["type"])
		var cls := "EXTERIOR"
		if _items.is_top_level(obj["type"]):
			cls = "INTERIOR"
		elif _items.levels(obj["type"]) != 0 and (_items.levels(obj["type"]) & (_items.levels(obj["type"]) - 1)) != 0:
			cls = "SHARED"
		var key := "%s|%s|%d" % [cls, fam, b]
		if key != prev:
			if not run.is_empty():
				runs.append(run)
			if b != tie_band:
				tie_band = b
				run_tie = 0.0
			run = {"key": key, "depth": band_repr[b] + run_tie, "fam": fam, "band": b}
			run_tie += 0.001
			prev = key
		else:
			run["key"] = key
	if not run.is_empty():
		runs.append(run)
	# check for duplicate depth keys
	var seen: Dictionary = {}
	var dups: Array = []
	for r in runs:
		var dk: float = r["depth"]
		if seen.has(dk):
			dups.append("%s vs %s @ %.4f" % [seen[dk], r["key"], dk])
		else:
			seen[dk] = r["key"]
	print("depth_probe\truns=%d\tduplicate_depth_keys=%d" % [runs.size(), dups.size()])
	for d in dups:
		print("depth_probe\tDUP %s" % d)
	print("depth_probe\tverdict=%s" % ("PASS" if dups.is_empty() else "FAIL"))
	quit(0)


static func _band_of(i: int, n: int, bands: int) -> int:
	return mini(int(floor(float(i) * bands / n)), bands - 1)


static func _ground_depth(p: Vector2) -> float:
	return (-p.y / 24.0) * 0.05 + 2.0
