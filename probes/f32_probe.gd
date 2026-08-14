extends SceneTree
## Read-only: at which sector gx does the region_key*2+class bucket stop
## surviving the float32 UV2 vertex attribute? (region_key = gx*1e6+gy*1e3+idx)
func _init() -> void:
	var a := PackedVector2Array()
	a.append(Vector2(0.0, 100078000.0)); a.append(Vector2(0.0, 100078001.0))
	print("sector50,39\text=%.1f int=%.1f collapsed=%s" % [a[0].y, a[1].y, a[0].y == a[1].y])
	for gx: int in [0, 4, 8, 9, 16, 17, 32, 50, 99]:
		var rk := gx * 1000000 + 39 * 1000
		var b := PackedVector2Array()
		b.append(Vector2(0.0, float(rk * 2))); b.append(Vector2(0.0, float(rk * 2 + 1)))
		print("gx=%d\trk=%d\text=%d\tint=%d\tcollapsed=%s" % [
			gx, rk, int(b[0].y + 0.5), int(b[1].y + 0.5), b[0].y == b[1].y])
	quit()
