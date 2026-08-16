extends SceneTree
## WHICH WAY DOES A MODEL FACE, in its own space?
##
##   godot --headless --path . --script res://probes/facing_probe.gd
##
## The port has never turned a character: PlayerView.set_yaw and
## rig_placement.yaw are built and every call site passes 0.0, because the
## cell-space-to-yaw convention was never established and inventing one risks
## being 180 degrees wrong on every body in the game.
##
## FIRST ROUTE, REFUTED. A locomotion clip's ROOT translation would give the
## forward axis with no convention assumed. Measured: Sacred's walk and run
## clips are IN PLACE. GLAD_WALK_BH's root carries three position keys and
## nets to exactly zero over the cycle -- it bobs, it does not travel -- and
## the same holds for every class body's WALK and RUN. Only 9 of 67 records
## net-move at all, and those are limbs. The engine moves the body; the clip
## does not. So this route cannot answer the question and is recorded here so
## nobody spends a day on it again.
##
## SECOND ROUTE, and it needs no convention either: the rig is standard 3ds Max
## Biped, so it has `Bip01 L Foot` and `Bip01 L Toe0`. THE TOE IS IN FRONT OF
## THE ANKLE. `Toe0 - Foot` in the model's own global rest space is therefore a
## forward vector, and its SIGN is fixed by anatomy rather than chosen -- which
## is the half a hip-axis cross product could not settle.
##
## THE CLAIM TO TEST is that every class body agrees. IT DOES NOT -- measured
## worst pairwise dot 0.4587 over the seven bodies that resolve, and the
## results fall into two families rather than scattering:
##
##   GLADIATOR, SERAPHIM, WALDELFE, DAEMONIA   forward lies in XZ, Y ~ 0
##   DUNKELELVE, MAGICIAN, DWARF               forward lies in YZ, X ~ 0
##
## A toe is both forward of and below its ankle, so a correct reading should
## have a small negative Y and a large horizontal part on EVERY body. Half of
## them put the whole magnitude in Y instead. That is two authoring frames, not
## two facings -- most likely the 90-degree-Z alignment bone rigs.gd names
## ("a mesh carries a 90-degree-Z alignment bone above Bip01 that a clip has no
## node for at all") being present in some chains and not others.
##
## SO FACING REMAINS OPEN, and deliberately: a single yaw convention picked
## from these numbers would be right for one family and 90 degrees wrong for
## the other. The next step is to resolve the alignment bone per mesh and
## re-run this, not to average the two answers.
const Main := preload("res://main.gd")
const FEET := [["Bip01 L Foot", "Bip01 L Toe0"], ["Bip01 R Foot", "Bip01 R Toe0"]]


func _init() -> void:
	var install := Sacred.find_install()
	var pak := Sacred.Pak.new(install.path_join("pak/models.pak"))
	var models := Sacred.Models.new(pak)
	print("mesh\tforward(global rest)\tyaw_deg\thip_axis_dot")
	var dirs: Array[Vector3] = []
	var meshes := PackedStringArray()
	for tree in Main.CLASS_MODEL:
		var mesh: String = Main.CLASS_MODEL[tree]
		var me := models.index_of(mesh)
		if me < 0:
			continue
		var g := _global_rest(models, me)
		var fwd := Vector3.ZERO
		var n := 0
		for pair in FEET:
			if g.has(pair[0]) and g.has(pair[1]):
				fwd += (g[pair[1]] as Vector3) - (g[pair[0]] as Vector3)
				n += 1
		if n == 0:
			print("%s\tno biped feet" % mesh)
			continue
		fwd /= float(n)
		# The HIP AXIS is the control: forward must be roughly PERPENDICULAR to
		# the line between the two thighs. A vector that is not is not forward.
		var hip := Vector3.ZERO
		if g.has("Bip01 L Thigh") and g.has("Bip01 R Thigh"):
			hip = (g["Bip01 L Thigh"] as Vector3) - (g["Bip01 R Thigh"] as Vector3)
		var dot := 0.0
		if hip.length() > 0.001 and fwd.length() > 0.001:
			dot = absf(fwd.normalized().dot(hip.normalized()))
		dirs.append(fwd.normalized())
		meshes.append(mesh)
		print("%s\t%s\t%.1f\t%.3f" % [
			mesh, fwd.normalized(), rad_to_deg(atan2(fwd.z, fwd.x)), dot])
	var worst := 1.0
	for i in dirs.size():
		for j in range(i + 1, dirs.size()):
			worst = minf(worst, dirs[i].dot(dirs[j]))
	print("bodies=%d  worst pairwise dot=%.4f" % [dirs.size(), worst])
	quit()


## Bone name -> GLOBAL rest origin, composing each bone's parent chain. Safe
## within ONE mesh: what rigs.gd forbids is composing across a MESH and a CLIP,
## which do not share a chain above Bip01.
func _global_rest(models, entry: int) -> Dictionary:
	var bones: Array = models.bones(entry)
	var xf: Array[Transform3D] = []
	var out: Dictionary = {}
	for i in bones.size():
		var local: Transform3D = bones[i]["rest"]
		var p: int = int(bones[i]["parent"])
		xf.append(local if p < 0 or p >= i else xf[p] * local)
		var nm: String = (bones[i]["name"] as PackedByteArray).get_string_from_utf8()
		if nm != "" and not out.has(nm):
			out[nm] = xf[i].origin
	return out
