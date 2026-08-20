extends SceneTree
## WHAT differs between the Seraphim's two rigs -- lengths, or directions?
##
##   godot --headless --path . --script res://probes/sera_bind_probe.gd
##
## sera_scale_probe refuted a uniform scale (dividing the best fit out makes
## agreement WORSE, 0.255 -> 0.036) and found the two families are exactly
## complementary: SERAPHIM.GRN matches IDLE/FIDLE/DYING and not WALK/RUN/TALK/
## HIT/DEFEND/ACTIVATE/CAST, while SERAWINGS02/SERAHELMET02/SERABOOTS01 match
## precisely the reverse set.
##
## A bone's stored value here is its LOCAL rest origin -- its offset from its
## parent. Two quantities separate the possible causes:
##
##   LENGTH  |origin|, the bone's own length. Invariant to how the rig is
##           posed. If the lengths agree it is ONE skeleton.
##   ANGLE   between the two origin vectors. A parent rotated in the rest pose
##           swings its children's local offsets without changing their length.
##
## Lengths agree + directions differ = one skeleton stored in two different
## BIND POSES, and Rigs is comparing a quantity that the bind pose moves.
## Lengths differ too = genuinely two skeletons and no comparison will unite
## them.
const PAIRS := [
	["SERAPHIM.GRN", "SERA_IDLE_1H.GRN"],
	["SERAPHIM.GRN", "SERA_WALK_1H.GRN"],
	["SERAWINGS02.GRN", "SERA_WALK_1H.GRN"],
	["SERAWINGS02.GRN", "SERA_IDLE_1H.GRN"],
	["GLADIATOR.GRN", "GLAD_WALK_BH.GRN"],
]
const NEAR := 1e-3

func _init() -> void:
	var install := Sacred.find_install()
	var pak := Sacred.Pak.new(install.path_join("pak/models.pak"))
	var models := Sacred.Models.new(pak)
	for p in PAIRS:
		var me := models.index_of(p[0])
		var ci := models.index_of(p[1])
		if me < 0 or ci < 0:
			continue
		var mesh: Dictionary = {}
		for b in models.bones(me):
			var nm: String = (b["name"] as PackedByteArray).get_string_from_utf8()
			if nm != "" and not mesh.has(nm):
				mesh[nm] = (b["rest"] as Transform3D).origin
		var cn := models.clip_bone_names(ci)
		var cb := models.clip_bones(ci)
		var len_ok := 0        # bone length agrees within NEAR (absolute)
		var dir_ok := 0        # direction agrees within ~1 degree
		var both := 0
		var n := 0
		var worst: Array = []
		for j in cn.size():
			var o: Variant = mesh.get(cn[j])
			if o == null:
				continue
			var m: Vector3 = o
			var c: Vector3 = (cb[j]["rest"] as Transform3D).origin
			if m.length() < 0.05:
				continue               # root-adjacent stubs carry no direction
			n += 1
			var dl: float = absf(c.length() - m.length())
			var ang := rad_to_deg(c.angle_to(m)) if c.length() > 0.0 else 180.0
			if dl <= NEAR:
				len_ok += 1
			if ang <= 1.0:
				dir_ok += 1
			if dl <= NEAR and ang <= 1.0:
				both += 1
			worst.append([ang, cn[j], m.length(), c.length()])
		if n == 0:
			continue
		worst.sort_custom(func(a, b): return a[0] > b[0])
		print("%s\tvs\t%s\tn=%d\tlen_ok=%d (%.3f)\tdir_ok=%d (%.3f)\tboth=%d (%.3f)" % [
			p[0], p[1], n, len_ok, float(len_ok) / float(n),
			dir_ok, float(dir_ok) / float(n), both, float(both) / float(n)])
		for i in mini(4, worst.size()):
			print("   worst\t%-22s\tangle=%7.2fdeg\tmesh_len=%.4f\tclip_len=%.4f" % [
				worst[i][1], worst[i][0], worst[i][2], worst[i][3]])
	quit()
