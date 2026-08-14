extends SceneTree
## Probe: OBSERVED vs RANGE-MATCHED EXPECTED for both halves of floor.pak +0x04.
##
## Raw set-membership is worthless here: creature ids cluster at low indices and
## .grn items cluster in bands, so a field that merely LANDS in a dense band
## looks like a hit. This computes the background rate per 1024-wide bucket of
## items.pak record index, then weights it by the observed value distribution to
## get an expectation, and compares. A real link should beat its own bucket
## background by a wide margin; a coincidence should match it. Read-only.
##   godot --headless --path godot-port --script res://floor_stat_probe.gd
const CDATA := 256
const CREC := 86
const BUCKET := 1024

func _init() -> void:
	var install := Sacred.find_install()
	var fp := Sacred.Pak.new(install.path_join("world/floor.pak"))
	var items_pak := Sacred.Pak.new(install.path_join("pak/items.pak"))
	var items := Sacred.Items.new(items_pak)
	var cb := FileAccess.get_file_as_bytes(install.path_join("pak/creature.pak"))
	var is_creature: Dictionary = {}
	for i in cb.decode_u32(4):
		is_creature[cb.decode_u32(CDATA + i * CREC)] = true

	# Background rates per bucket over the whole items.pak index space.
	var nbuckets := int(ceil(float(items_pak.count()) / float(BUCKET)))
	var bk_grn: Array = []
	var bk_cre: Array = []
	for _b in nbuckets:
		bk_grn.append(0.0)
		bk_cre.append(0.0)
	for rec in items_pak.count():
		var b := rec / BUCKET
		if items.name_of(rec).to_lower().ends_with(".grn"):
			bk_grn[b] += 1.0
		if is_creature.has(rec):
			bk_cre[b] += 1.0
	for b in nbuckets:
		bk_grn[b] /= float(BUCKET)
		bk_cre[b] /= float(BUCKET)

	for half in ["lo16", "hi16"]:
		var n := 0
		var obs_grn := 0
		var obs_cre := 0
		var exp_grn := 0.0
		var exp_cre := 0.0
		var out_of_range := 0
		for i in range(1, fp.count(), 977):
			var r := fp.blob(i)
			if r.size() < 16:
				continue
			var v := r.decode_u32(4)
			var x := (v & 0xffff) if half == "lo16" else ((v >> 16) & 0xffff)
			n += 1
			if x >= items_pak.count():
				out_of_range += 1
				continue
			var b := x / BUCKET
			exp_grn += bk_grn[b]
			exp_cre += bk_cre[b]
			if items.name_of(x).to_lower().ends_with(".grn"):
				obs_grn += 1
			if is_creature.has(x):
				obs_cre += 1
		print("%s\tn=%d\tout_of_range=%d\tgrn obs=%d exp=%.1f ratio=%.2f\tcreature obs=%d exp=%.1f ratio=%.2f" % [
			half, n, out_of_range, obs_grn, exp_grn, obs_grn / maxf(exp_grn, 0.001),
			obs_cre, exp_cre, obs_cre / maxf(exp_cre, 0.001)])
	quit()
