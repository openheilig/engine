extends "res://checks/check.gd"
## Native producer admission uses cTrigger's lowest-set-bit index, not raw!=0.
## Real chapel support: no rectangle/family substitute, and no GPU needed.

func _init() -> void:
	super()
	var install := Sacred.find_install()
	var world := Sacred.World.new(install.path_join("world"))
	var statics := Sacred.Statics.new(Sacred.Pak.new(install.path_join("world/static.pak")))
	var triggers := Interior.Triggers.new(install.path_join("world/triggers.pak"))
	var interior := Interior.new(world, statics, triggers)
	var cell := Vector2i(3232, 2512)
	var support := interior.initial_support_ref(cell, 5201, 1)
	assert(support != 0, "chest support must resolve from authored records")
	var parent := interior.parent_for_cell(cell)
	assert(not parent.is_empty() and (parent["flags"] & 0x400) == 0,
		"chapel must exercise trigger-selected support, not all-child admission")
	var trigger: int = parent["trigger"]
	assert(interior.replace_state(trigger, 2))
	assert(interior.dynamic_support_orders(cell, support) == PackedInt32Array([0]),
		"bit1 must admit the first authored support grid")
	assert(interior.replace_state(trigger, 3))
	assert(interior.dynamic_support_orders(cell, support).is_empty(),
		"bit0 takes precedence over bit1; nonzero raw state is not admission")
	assert(interior.replace_state(trigger, 6))
	assert(interior.dynamic_support_orders(cell, support) == PackedInt32Array([0]),
		"bit1 takes precedence over bit2; raw state is not a layer index")
	assert(interior.replace_state(trigger, 0))
	assert(interior.dynamic_support_orders(cell, support).is_empty(),
		"raw zero must not retain a previously admitted child grid")
	assert(interior.dynamic_support_orders(cell, 0) == PackedInt32Array([-1]),
		"support hiding must not discard the independent base-cell dynamic phase")
	assert(interior.replace_state(trigger, 2))
	var region := interior.support_region(support)
	var outside: Vector2i = region["cell"] + region["size"]
	assert(interior.dynamic_support_orders(outside, support).is_empty(),
		"support identity does not admit positions outside its authored grid")
	print("dynamic_support_check\tOK\ttrigger=%d\tsupport=%d" % [trigger, support])
	finish()
