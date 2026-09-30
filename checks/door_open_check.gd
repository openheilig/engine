extends "res://checks/check.gd"
## door_open_check.gd -- W2: the door open/close mutation, transcribed from
## the use-object executors (open = setState(state|1), close = resetState(1),
## on the door static's own trigger). Doors are item category 10 (119 types
## in items.pak); the authored trigger table carries no locked door (no
## flags&0x44 record with a nonzero prerequisite), so the locked-refusal
## branch is transcribed but unexercised against real data.

func _init() -> void:
	super()
	var fails := 0
	var install := Sacred.find_install()
	assert(not install.is_empty(), "retail install is required")
	var triggers: Object = preload("res://formats/triggers.gd").new(
		install.path_join("world/triggers.pak"))

	# Category 10 (door) types exist in items.pak.
	var doors := 0
	for i in items_category_doors(triggers, install):
		doors += 1
	expect(doors > 0, "items.pak must carry category-10 door types")

	# Open/close on a plain zero-state trigger: bit 0 is "open".
	var t := 0
	expect(triggers.state(t) == 0, "trigger 0 starts closed")
	expect(triggers.open_door(t), "open_door must succeed")
	expect(triggers.state(t) & 1 != 0, "open sets bit 0")
	expect(triggers.open_door(t), "open on an open door is a no-op success")
	expect(triggers.close_door(t), "close_door must succeed")
	expect(triggers.state(t) & 1 == 0, "close clears bit 0")
	expect(triggers.close_door(t), "close on a closed door is a no-op success")

	# Unknown trigger: refusal, not a crash.
	expect(not triggers.open_door(99999), "unknown trigger refuses")

	print("door_open_check\tOK")
	finish(1 if fails > 0 else 0)


## Count items.pak types in category 10 (doors) -- the same predicate
## ItemTypeMgr::getDoorDirection opens with.
func items_category_doors(_triggers: Object, install: String) -> Array:
	var items := Sacred.Items.new(Sacred.Pak.new(install.path_join("pak/items.pak")))
	var out: Array = []
	for i in items.record_count():
		if items.category_of(i) == 10:
			out.append(i)
	return out
