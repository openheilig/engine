extends "res://checks/check.gd"
## item_state_check.gd -- C2 foundation: definition vs instance separation.
## The container must give every spawned item a unique, never-reused
## instance id, keep two instances of ONE definition distinct, track
## ownership/location transitions transactionally (an invalid transfer
## changes nothing), and roundtrip through the save snapshot (schema v2).
## Roll/pool semantics are the ITEM gate's -- deliberately absent here.

func _init() -> void:
	super()
	var fails := 0

	var items := ItemInstances.new()

	# --- unique ids; two instances of ONE definition stay distinct ---
	var a := items.spawn(4748, Vector2i(3232, 2512))
	var b := items.spawn(4748, Vector2i(3233, 2512))
	if a == b:
		fails += 1
		printerr("two spawns of definition 4748 must get distinct instance ids")
	if items.instance(a).definition_id != 4748 or items.instance(b).definition_id != 4748:
		fails += 1
		printerr("definition id must survive the spawn")
	if items.instance(a).cell == items.instance(b).cell:
		fails += 1
		printerr("the two instances must keep their own cells")

	# --- ownership transfer; hero picks up a, then b ---
	var hero_id := 1
	var err := items.transfer(a, ItemInstances.Location.INVENTORY, hero_id)
	if err != "" or items.instance(a).location != ItemInstances.Location.INVENTORY \
			or items.instance(a).owner_id != hero_id:
		fails += 1
		printerr("pickup failed: %s" % err)
	err = items.transfer(b, ItemInstances.Location.INVENTORY, hero_id)
	if err != "":
		fails += 1
		printerr("second pickup of the same definition must be independent: %s" % err)

	# --- invalid transfer changes NOTHING ---
	var before: Dictionary = items.instance(a).duplicate()
	err = items.transfer(a, ItemInstances.Location.EQUIPPED, 999)  # owner 9 has nothing; missing slot
	if err == "" or items.instance(a).location != int(before["location"]) \
			or items.instance(a).owner_id != int(before["owner_id"]):
		fails += 1
		printerr("a failed transfer must be refused without mutation")

	# --- despawned instances are gone and their id is never reused ---
	items.despawn(b)
	if items.instance(b) != null:
		fails += 1
		printerr("despawned instance must be gone")
	var c := items.spawn(5000, Vector2i(1, 1))
	if c <= b:
		fails += 1
		printerr("instance ids are monotonic -- despawn must not reissue %d" % b)

	# --- snapshot roundtrip (schema v2 carries items) ---
	var snap := {"schema": SaveState.SCHEMA, "actors": [], "quest_states": {},
		"quest_entered": [], "cast": [], "items": items.snapshot(),
		"next_item_id": items.next_id(), "tick": 0, "tick_hz": 30,
		"player_id": 0, "next_actor_id": 1}
	var restored := ItemInstances.from_snapshot(snap["items"])
	if restored.count() != items.count() or restored.instance(a) == null \
			or restored.instance(a).owner_id != hero_id \
			or restored.instance(c).definition_id != 5000:
		fails += 1
		printerr("item snapshot roundtrip lost state")

	print("item_state_check\tOK\tinstances=%d" % items.count())
	finish(1 if fails > 0 else 0)
