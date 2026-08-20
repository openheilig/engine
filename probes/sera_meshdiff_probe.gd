extends SceneTree
## WHICH bones differ between the Seraphim's two rigs, and by how much?
##
##   godot --headless --path . --script res://probes/sera_meshdiff_probe.gd
##
## sera_bind_probe put the split entirely in bone LENGTH: direction agrees at
## ~0.89 for every pair, matched and mismatched alike, while length agrees at
## 0.85..0.93 within a family and 0.26..0.28 across it. So the two rigs share
## a skeleton and differ in proportions. This compares the two mesh exports
## directly -- no clip in the way -- and sorts by RELATIVE difference, because
## Rigs' own tolerance is an ABSOLUTE 0.01 in a rig whose root bone is 41 units
## long, and that ratio is itself a candidate explanation.
const MESHES := ["SERAPHIM.GRN", "SERAWINGS02.GRN"]

func _init() -> void:
	var install := Sacred.find_install()
	var pak := Sacred.Pak.new(install.path_join("pak/models.pak"))
	var models := Sacred.Models.new(pak)
	var a: Dictionary = {}
	var b: Dictionary = {}
	var into := [a, b]
	for i in 2:
		var e := models.index_of(MESHES[i])
		for bo in models.bones(e):
			var nm: String = (bo["name"] as PackedByteArray).get_string_from_utf8()
			if nm != "" and not (into[i] as Dictionary).has(nm):
				(into[i] as Dictionary)[nm] = (bo["rest"] as Transform3D).origin
	var rows: Array = []
	var same := 0
	var shared := 0
	for k: String in a:
		if not b.has(k):
			continue
		shared += 1
		var va: Vector3 = a[k]
		var vb: Vector3 = b[k]
		var d := va.distance_to(vb)
		if d <= 0.01:
			same += 1
		var rel := d / maxf(1e-6, va.length())
		rows.append([rel, k, va.length(), vb.length(), d, rad_to_deg(va.angle_to(vb)) if va.length() > 0.0 and vb.length() > 0.0 else 0.0])
	rows.sort_custom(func(x, y): return x[0] > y[0])
	print("%s vs %s\tshared=%d\twithin0.01=%d (%.3f)" % [
		MESHES[0], MESHES[1], shared, same, float(same) / maxf(1.0, float(shared))])
	var n_diff := 0
	for r in rows:
		if r[4] > 0.01:
			n_diff += 1
	print("differing (>0.01 abs)\t%d of %d" % [n_diff, shared])
	for i in mini(14, rows.size()):
		print("  %-24s\trel=%.4f\tlen_a=%9.4f\tlen_b=%9.4f\tdist=%.4f\tangle=%.2fdeg" % [
			rows[i][1], rows[i][0], rows[i][2], rows[i][3], rows[i][4], rows[i][5]])
	quit()
