extends SceneTree
## Probe: the region cell class along swap_walk.sh's supported-in-out route,
## to tell a stale gate apart from a port defect. Read-only.
##   godot --headless --path godot-port --script res://route_class_probe.gd
const OUTSIDE := Vector2i(3420, 1826)
const INTERIOR := Vector2i(3420, 1840)

func _init() -> void:
	var world := Sacred.World.new(Sacred.find_install().path_join("world"))
	var walk := Walkable.new(world)
	var names := {0: "EMPTY", 1: "WALL", 2: "FLOOR", 9: "DOOR", 0xa: "STEP", 0x10: "OPEN"}
	print("route\toutside=%s\tinterior=%s" % [OUTSIDE, INTERIOR])
	# The straight line the route walks, plus a margin either side.
	for y in range(OUTSIDE.y - 2, INTERIOR.y + 3):
		var c := walk.class_at(OUTSIDE.x, y)
		var mark := ""
		if y == OUTSIDE.y:
			mark = "  <-- route OUTSIDE endpoint"
		elif y == INTERIOR.y:
			mark = "  <-- route INTERIOR endpoint"
		print("cell\t%d,%d\tclass=%d\t%s\topen=%s%s" % [
			OUTSIDE.x, y, c, names.get(c, "?"), Walkable.class_is_open(c), mark])
	if OS.get_environment("STEP") == "1":
		var regions := Sacred.Regions.new(world.sector(53, 28), 53, 28)
		for ri in regions.list.size():
			var r: Dictionary = regions.list[ri]
			var a: Vector2i = r["cell"]
			var sz: Vector2i = r["size"]
			var hist: Dictionary = {}
			var steps: Array = []
			for y in sz.y:
				for x in sz.x:
					var c := Sacred.Regions.cell_class(r, x, y)
					hist[c] = int(hist.get(c, 0)) + 1
					if c == Sacred.Regions.STEP and steps.size() < 12:
						steps.append(a + Vector2i(x, y))
			print("region53_28\t%d\tanchor=%s\tsize=%s\tclasses=%s\tstep_cells=%s" % [ri, a, sz, hist, steps])
	quit()

## Second pass (STEP=1): does the OZELT1 tent at region 53,28,2 have an
## authored STEP exit cell at all? Without one, the retail model has no way to
## restore the building and swap_walk's two-line expectation is unreachable.
