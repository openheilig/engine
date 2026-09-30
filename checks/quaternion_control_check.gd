extends "res://checks/check.gd"
## Control-point magnitudes affect the evaluated orientation; normalizing
## them before the quadratic blend changes the curve (native finding 1251).

func _init() -> void:
	super()
	var data := PackedByteArray()
	data.resize(52 + 4 * 20)
	data.encode_u32(16, 2)
	data.encode_u32(28, 4)
	for i in 4:
		data.encode_float(52 + i * 4, float(i - 1))
	var controls := [Quaternion(0, 0, 0, 1), Quaternion(0, 0, 0, 2),
		Quaternion(0, 0, 1, 0), Quaternion(0, 0, 1, 0)]
	for i in 4:
		var offset := 68 + i * 16
		data.encode_float(offset, controls[i].x)
		data.encode_float(offset + 4, controls[i].y)
		data.encode_float(offset + 8, controls[i].z)
		data.encode_float(offset + 12, controls[i].w)
	var models := Sacred.Models.new(null)
	var directory: Array[Dictionary] = [{"rel": 0}]
	var record := models._clip_ordinary_record(0, data, directory, 0, 0, 0, 0)
	assert(not record.is_empty())
	var view := ModelView.new()
	var samples := view._resample_quad_rot(record["times_rot"], record["rotations"])
	var matched := false
	for pair: Array in samples:
		if is_equal_approx(float(pair[0]), 0.5):
			# At t=.5 the three coefficients are 1/8, 3/4, 1/8.
			# Raw magnitudes therefore give z:w=1:13, not 1:7.
			var expected := Quaternion(0, 0, 1, 13).normalized()
			expect((pair[1] as Quaternion).angle_to(expected) < 0.0007,
				"quaternion control normalization changed the sampled orientation")
			matched = true
	expect(matched, "mid-span orientation was not sampled")
	view.free()
	finish()
