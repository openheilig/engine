extends SceneTree
## Probe: print sector 50,39's region class grid as ASCII, marking the pinned
## Seraphim spawn cell. Read-only.
##   godot --headless --path godot-port --script res://kapelle_grid_probe.gd
const GX := 50
const GY := 39
const SPAWN := Vector2i(3236, 2511)

func _init() -> void:
	var install := Sacred.find_install()
	var world := Sacred.World.new(install.path_join("world"))
	for gy in range(GY - 1, GY + 2):
		for gx in range(GX - 1, GX + 2):
			if not world.has_sector(gx, gy):
				continue
			var regions := Sacred.Regions.new(world.sector(gx, gy), gx, gy)
			for ri in regions.list.size():
				var r: Dictionary = regions.list[ri]
				var a: Vector2i = r["cell"]
				var s: Vector2i = r["size"]
				print("region\t%d,%d,%d\tanchor=%s\tsize=%s\trect=%d..%d,%d..%d" % [
					gx, gy, ri, a, s, a.x, a.x + s.x - 1, a.y, a.y + s.y - 1])
				if gx != GX or gy != GY:
					continue
				var grid: PackedByteArray = r["grid"]
				var raw_counts: Dictionary = {}
				for y in s.y:
					var row := ""
					for x in s.x:
						var b := grid[(y * s.x + x) * Sacred.CELL + 31]
						raw_counts[b] = int(raw_counts.get(b, 0)) + 1
						var ch := "?"
						match b:
							0x00: ch = " "
							0xd0: ch = "d"
							0xe0: ch = "e"
							0xd1: ch = "#"
							0xd2: ch = "."
							0xe2: ch = ","
							0xd9: ch = "D"
							0xe9: ch = "E"
							0xda: ch = "S"
						if a + Vector2i(x, y) == SPAWN:
							ch = "@"
						row += ch
					print("row\t%4d\t%s" % [a.y + y, row])
				print("raw_at_spawn=0x%02x" % grid[((SPAWN.y - a.y) * s.x + (SPAWN.x - a.x)) * Sacred.CELL + 31])
				var bs: Array = raw_counts.keys(); bs.sort()
				for b: int in bs:
					print("rawcount\t0x%02x\t%d" % [b, raw_counts[b]])
	print("spawn_local=%s" % [SPAWN - Vector2i(3213, 2502)])
	quit()
