extends "res://checks/check.gd"
## Preserve actual authored shear through the render-pose consumer. This does
## not prove the decoder by comparing it with itself: native 0x08074996 was
## independently exercised on these local transforms (private evidence).

func _init() -> void:
	super()
	var models := Sacred.Models.new(Sacred.Pak.new(Sacred.find_install().path_join("pak/models.pak")))
	var entry := models.index_of("WOLF.GRN")
	assert(entry >= 0)
	var view := ModelView.new()
	root.add_child(view)
	assert(view.setup(models, entry, false))
	view.prepare_render()
	var skeleton: Skeleton3D = view.get_node("Skeleton")
	var names := models.bone_names(entry)
	var source := models.bones(entry)
	for name in ["Bip01 Neck1", "Bip01 Head", "Bip01 L Clavicle", "Bip01 R Clavicle"]:
		var source_index := names.find(name)
		var bone := skeleton.find_bone(name)
		assert(source_index >= 0 and bone >= 0)
		var expected: Transform3D = source[source_index]["rest"]
		var parent := skeleton.get_bone_parent(bone)
		var actual: Transform3D = view.affine_global_poses[parent].affine_inverse() * view.affine_global_poses[bone]
		var error := 0.0
		var lossy_error := 0.0
		for point in [Vector3.ZERO, Vector3.RIGHT, Vector3.UP, Vector3.BACK]:
			error = maxf(error, (actual * point).distance_to(expected * point))
			lossy_error = maxf(lossy_error,
				(skeleton.get_bone_pose(bone) * point).distance_to(expected * point))
		assert(error < 0.00005, "%s: authored affine pose collapsed (%f)" % [name, error])
		assert(lossy_error > 0.01, "%s no longer distinguishes full shear from TRS" % name)
	view.free()
	print("affine_skin_check\tOK\tfull wolf neck/head/clavicle transforms survive")
	finish()
