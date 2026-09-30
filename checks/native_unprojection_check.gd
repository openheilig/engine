extends "res://checks/check.gd"

const Native = preload("res://view/native_actor_shadow.gd")

func _init() -> void:
	super()
	# LGP 0x080D78BA multiplies by the float32 reciprocal of 768.
	# Replacing it with a double division changes large-coordinate rounding,
	# which also rotates the difference between two nearby projected points.
	var point := Vector2(173474, 134834)
	var origin := Native.lattice_to_native(point)
	expect(origin == Vector2(18022.82421875, 160577.09375),
		"native unprojection lost its float32 reciprocal rounding")
	var heading := Native.heading_from_degrees(-30.0)
	var basis := Native.actor_basis(Vector2(3232.5, 2512.5), heading, Vector3.ONE)
	expect(basis.x.distance_to(Vector3(0.60335255, -0.79747456, 0)) < 0.000001,
		"large-coordinate cancellation rotated the native object heading")
	finish()
