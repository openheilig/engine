extends SceneTree
## Is the Seraphim's walk a SCALED copy of her idle's skeleton?
##
##   godot --headless --path . --script res://probes/sera_scale_probe.gd
##
## sera_rig_probe reported the median |clip origin| / |mesh origin| ratio as
## exactly 0.9718 for SERA_WALK_1H and SERA_RUN_1H, and exactly 1.0000 for
## SERA_IDLE_1H and SERA_FIDLE_1H. A median hides its own spread, so this
## measures the spread: a uniform scale is one tight cluster, a different
## skeleton is a smear, and the two are being told apart here rather than
## assumed apart.
##
## THE TEST THAT DECIDES IT: rescore each clip against the mesh with the
## best-fit uniform scale divided out. If `within` jumps from 14/55 to most of
## 55, the cause is a scale and Rigs is comparing unnormalised lengths; if it
## does not move, the skeletons genuinely differ and the scale was a
## coincidence of two similar bodies.
const WITHIN := 0.01
const CLIPS := ["SERA_IDLE_1H.GRN", "SERA_FIDLE_1H.GRN", "SERA_WALK_1H.GRN",
	"SERA_RUN_1H.GRN", "SERA_TALK_A.GRN", "SERA_HIT_A.GRN", "SERA_DEFEND_1H.GRN",
	"SERA_ACTIVATE.GRN", "SERA_CAST_MAGIC10.GRN", "SERA_DYING_C.GRN"]
## The equipment pieces the walk scored 0.796/0.768 against -- higher than it
## scored against the body itself, which is the fact that needs explaining.
const MESHES := ["SERAPHIM.GRN", "SERAWINGS02.GRN", "SERAHELMET02.GRN", "SERABOOTS01.GRN"]

func _init() -> void:
	var install := Sacred.find_install()
	var pak := Sacred.Pak.new(install.path_join("pak/models.pak"))
	var models := Sacred.Models.new(pak)
	for mesh_name in MESHES:
		var me := models.index_of(mesh_name)
		if me < 0:
			continue
		var mesh: Dictionary = {}
		for b in models.bones(me):
			var nm: String = (b["name"] as PackedByteArray).get_string_from_utf8()
			if nm != "" and not mesh.has(nm):
				mesh[nm] = (b["rest"] as Transform3D).origin
		for cname in CLIPS:
			var ci := models.index_of(cname)
			if ci < 0:
				continue
			var cn := models.clip_bone_names(ci)
			var cb := models.clip_bones(ci)
			# Least-squares uniform scale s minimising |c - s*m|^2 over the
			# shared bones: s = sum(c.m) / sum(m.m). Origin-anchored, so it is
			# a pure scale and not a scale-plus-offset fit.
			var num := 0.0
			var den := 0.0
			var ratios: Array[float] = []
			var shared := 0
			for j in cn.size():
				var o: Variant = mesh.get(cn[j])
				if o == null:
					continue
				shared += 1
				var m: Vector3 = o
				var c: Vector3 = (cb[j]["rest"] as Transform3D).origin
				num += c.dot(m)
				den += m.dot(m)
				if m.length() >= 1.0:
					ratios.append(c.length() / m.length())
			if shared < 20:
				continue
			var s := num / den if den > 0.0 else 1.0
			ratios.sort()
			var lo := ratios[int(0.1 * float(ratios.size()))] if not ratios.is_empty() else NAN
			var hi := ratios[int(0.9 * float(ratios.size()))] if not ratios.is_empty() else NAN
			var raw := 0
			var scaled := 0
			for j in cn.size():
				var o: Variant = mesh.get(cn[j])
				if o == null:
					continue
				var m: Vector3 = o
				var c: Vector3 = (cb[j]["rest"] as Transform3D).origin
				if c.distance_to(m) <= WITHIN:
					raw += 1
				if (c / s).distance_to(m) <= WITHIN:
					scaled += 1
			print("%s\t%s\tshared=%d\traw=%d (%.3f)\tscaled=%d (%.3f)\ts=%.5f\tratio_p10=%.4f\tp90=%.4f\tn=%d" % [
				mesh_name, cname, shared, raw, float(raw) / float(shared),
				scaled, float(scaled) / float(shared), s, lo, hi, ratios.size()])
	quit()
