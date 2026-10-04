extends "res://checks/check.gd"
## D1 regression: real synthetic whole-file archives, never retail extracts.
const Profile := preload("res://formats/mod_manifest.gd")
const Pak := preload("res://formats/pak.gd")

func _init() -> void:
	super()
	var root := ProjectSettings.globalize_path("user://_mod_profile_%d" % Time.get_ticks_usec())
	var base := root.path_join("base")
	var a := root.path_join("a")
	var b := root.path_join("b")
	_write_pak(base.path_join("pak/items.pak"), 11)
	_write_pak(base.path_join("pak/mixed.pak"), 22)
	_write_pak(a.path_join("pak/items.pak"), 33)
	_write_pak(b.path_join("pak/items.pak"), 44)
	# Retail lib/ soname links are unused by this port, not mod inputs.
	DirAccess.make_dir_recursive_absolute(base.path_join("lib"))
	var libraries := DirAccess.open(base.path_join("lib"))
	expect(libraries.create_link("../pak/items.pak", "libsynthetic.so.0") == OK,
		"unused native-library symlink fixture creates")
	_manifest(a, "a", [], {"pak/items.pak": "pak/items.pak"})
	_manifest(b, "b", [{"id": "a", "version": "1"}], {"pak/items.pak": "pak/items.pak"})
	var vanilla := Profile.new(base)
	var p := Profile.new(base, [b, a])
	if not expect(vanilla.ok() and p.ok(), "valid vanilla and dependency profile compose: %s" % p.error_text()):
		_remove_tree(root)
		finish(1)
		return
	expect(p.package_order() == PackedStringArray(["a", "b"]), "dependencies load first even when selection order is reversed")
	expect(p.resolve(base.path_join("pak/items.pak")) == b.path_join("pak/items.pak"), "later dependent wins conflict")
	var trace: Array = p.provenance("pak/items.pak")
	expect(trace.size() == 3 and trace[0]["package"] == "vanilla" and trace[1]["package"] == "a" and trace[2]["package"] == "b", "provenance exposes base, loser and winner in order")
	expect(p.resolve(base.path_join("pak/mixed.pak")) == base.path_join("pak/mixed.pak"), "unreplaced logical sibling falls through")
	expect(p.resolve(base + "-backup/pak/items.pak") == base + "-backup/pak/items.pak", "root prefix is not a directory boundary")
	expect(Pak.configure_profile(p) == "", "valid profile mounts before opening archives")
	var archive := Pak.new(base.path_join("pak/items.pak"))
	expect(archive.is_open() and archive.from_mod and archive.requested_path == base.path_join("pak/items.pak") and archive.blob(0)[0] == 44, "reader opens winner but preserves logical requested path")
	expect(Pak.resolve(archive.requested_path.get_base_dir().path_join("mixed.pak")) == base.path_join("pak/mixed.pak"), "logical sibling routing survives mount")
	var identity: Dictionary = p.identity()
	var repeat := Profile.new(base, [b, a])
	expect(identity == repeat.identity(), "same composition has deterministic exact identity")
	_manifest(b, "b", [], {"pak/items.pak": "pak/items.pak"})
	expect(Profile.new(base, [a, b]).resolve(base.path_join("pak/items.pak")) == b.path_join("pak/items.pak")
		and Profile.new(base, [b, a]).resolve(base.path_join("pak/items.pak")) == a.path_join("pak/items.pak"), "independent conflicts use explicit selection order")
	_manifest(b, "b", [{"id": "a", "version": "2"}], {"pak/items.pak": "pak/items.pak"})
	expect(not Profile.new(base, [a, b]).ok(), "dependency exact-version mismatch is refused")
	_manifest(b, "b", [{"id": "a", "version": "1"}], {"pak/items.pak": "pak/items.pak"})
	_write_pak(b.path_join("pak/items.pak"), 45)
	var changed := Profile.new(base, [b, a])
	expect(identity != changed.identity(), "same path, length and version with different bytes changes identity")
	_write_pak(base.path_join("pak/mixed.pak"), 23)
	expect(changed.identity() != Profile.new(base, [b, a]).identity(), "base sibling bytes also belong to resolved identity")

	# Wrong content must be rejected before actors/items/triggers mutate.
	var session := _session()
	expect(session.bind_content_profile(p) == "", "session binds only a validated profile")
	var snap := session.snapshot()
	var decoded: Variant = JSON.parse_string(JSON.stringify(snap))
	expect(decoded is Dictionary and session.restore(decoded) == "", "identity survives disk JSON number conversion")
	var before := session.snapshot()
	var malformed: Dictionary = snap.duplicate(true)
	malformed["content_identity"]["schema"] = 1.5
	expect(session.restore(malformed) != "" and session.snapshot() == before,
		"fractional profile schema must refuse without mutating live state")
	malformed = snap.duplicate(true)
	malformed["content_identity"]["packages"] = ["not a package record"]
	expect(session.restore(malformed) != "" and session.snapshot() == before,
		"malformed package metadata must refuse without mutating live state")
	var wrong := _session()
	expect(wrong.bind_content_profile(changed) == "", "second session binds changed profile")
	wrong.registry.get_actor(wrong.player_id).hp = 1
	wrong.hero_gold = 999
	wrong.items.spawn(99, Vector2i(100, 100)) # Synthetic definition, no retail ID claim.
	expect(session.restore(wrong.snapshot()) != "" and session.snapshot() == before, "wrong-profile restore leaves complete live session unchanged")
	var absent: Dictionary = snap.duplicate(true)
	absent.erase("content_identity")
	expect(session.restore(absent) != "" and session.snapshot() == before, "unidentified old save cannot silently acquire current numeric items")
	absent = snap.duplicate(true)
	absent["schema"] = GameSession.SCHEMA - 1
	expect(session.restore(absent) != "" and session.snapshot() == before, "old session schema cannot migrate unidentified numeric item definitions")
	var unbound := _session()
	expect(unbound.restore(snap) != "", "restore requires explicit current content identity")
	expect(session.bind_content_profile(changed) != "", "live session cannot be rebound to a different content set")
	var missing := Profile.new(base, [b])
	expect(not missing.ok() and missing.error_text().contains("dependency"), "missing required package is refused")
	expect(Pak.configure_profile(missing) != "" and Pak.resolve(base.path_join("pak/items.pak")) == b.path_join("pak/items.pak"), "invalid profile cannot replace mounted profile")
	_manifest(a, "a", [{"id": "b", "version": "1"}], {"pak/items.pak": "pak/items.pak"})
	expect(not Profile.new(base, [a, b]).ok(), "dependency cycle is refused")
	_manifest(a, "a", [], {"pak/items.pak": "../b/pak/items.pak"})
	expect(not Profile.new(base, [a]).ok(), "source path escape is refused")
	_manifest(a, "a", [], {"../pak/items.pak": "pak/items.pak"})
	expect(not Profile.new(base, [a]).ok(), "logical path escape is refused")
	_manifest(a, "a", [], {"pak/items.pak": "pak/items.pak"})
	var plugin := FileAccess.open(a.path_join("plugin.gd"), FileAccess.WRITE)
	plugin.store_string("extends RefCounted\n")
	plugin.close()
	expect(not Profile.new(base, [a]).ok(), "script accompanying a data package is refused even when not listed")
	DirAccess.remove_absolute(a.path_join("plugin.gd"))
	var native := FileAccess.open(a.path_join("plugin.dll"), FileAccess.WRITE)
	native.store_buffer(PackedByteArray([77, 90, 0, 0]))
	native.close()
	expect(not Profile.new(base, [a]).ok(), "native DLL accompanying a data package is refused")
	DirAccess.remove_absolute(a.path_join("plugin.dll"))
	native = FileAccess.open(a.path_join("plugin.pck"), FileAccess.WRITE)
	native.store_buffer(PackedByteArray([71, 68, 80, 67]))
	native.close()
	expect(not Profile.new(base, [a]).ok(), "Godot resource pack accompanying a data package is refused")
	DirAccess.remove_absolute(a.path_join("plugin.pck"))
	var directory := DirAccess.open(a)
	if expect(directory.create_link(b, "linked") == OK, "synthetic package symlink fixture creates"):
		expect(not Profile.new(base, [a]).ok(), "symlink escaping a package is refused")
		DirAccess.remove_absolute(a.path_join("linked"))
	_manifest(a, "a", [], {"pak/items.pak": "pak/items.pak"}, "native")
	expect(not Profile.new(base, [a]).ok(), "executable support class is refused")
	_manifest(a, "a", [], {"pak/items.pak": "pak/items.pak"})
	var data := FileAccess.open(a.path_join("pak/items.pak"), FileAccess.READ_WRITE)
	data.seek(260)
	data.store_32(1000000)
	data.close()
	expect(not Profile.new(base, [a]).ok(), "out-of-file index is refused before any archive mounts")
	DirAccess.remove_absolute(b.path_join("mod.json"))
	var bare := Profile.new(base, [b])
	expect(bare.ok() and bare.package_order().size() == 1 and bare.provenance("pak/items.pak").back()["package"].begins_with("directory-"), "bare --mod directory becomes explicit content-identified package")
	expect(vanilla.identity() != bare.identity(), "missing required bare mod cannot bind a mod save to vanilla")
	# Raw retail-bytecode inputs use the same resolver. These synthetic bytes
	# are not an executable script/opcode witness, only whole-file routing.
	DirAccess.make_dir_recursive_absolute(a.path_join("bin"))
	var raw := FileAccess.open(a.path_join("bin/rules.bin"), FileAccess.WRITE)
	raw.store_buffer(PackedByteArray([1, 0, 0, 0]))
	raw.close()
	_manifest(a, "a", [], {"bin/rules.bin": "bin/rules.bin"})
	var data_profile := Profile.new(base, [a])
	expect(data_profile.ok() and data_profile.resolve(base.path_join("bin/rules.bin")) == a.path_join("bin/rules.bin"), "admitted .bin data routes through the single whole-file resolver")
	raw = FileAccess.open(a.path_join("bin/rules.bin"), FileAccess.WRITE)
	raw.store_buffer(PackedByteArray([77, 90, 0, 0]))
	raw.close()
	expect(not Profile.new(base, [a]).ok(), "native binary renamed .bin is refused")
	# Sparse fixture: one byte past the documented 64 MiB script budget;
	# composition must refuse before hashing or bulk-reading this input.
	raw = FileAccess.open(a.path_join("bin/funkcode.bin"), FileAccess.WRITE)
	raw.seek(64 * 1024 * 1024)
	raw.store_8(1)
	raw.close()
	_manifest(a, "a", [], {"bin/type_npc_synthetic/funkcode.bin": "bin/funkcode.bin"})
	var oversized := Profile.new(base, [a])
	expect(not oversized.ok() and oversized.error_text().contains("budget"), "oversized retail bytecode input is refused before any archive mounts")
	Pak.clear_profile()
	_remove_tree(root)
	print("mod_profile_check\tOK")
	finish()

func _write_pak(path: String, byte: int) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var bytes := PackedByteArray()
	bytes.resize(269)
	bytes[0] = 73 # ITM, synthetic one-byte payload (not a retail item record).
	bytes[1] = 84
	bytes[2] = 77
	bytes[3] = 5
	bytes.encode_u32(4, 1)
	bytes.encode_u32(256, 0)
	bytes.encode_u32(260, 268)
	bytes.encode_u32(264, 1)
	bytes[268] = byte
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()

func _manifest(root: String, id: String, dependencies: Array, files: Dictionary,
		kind: String = "data-only") -> void:
	var f := FileAccess.open(root.path_join("mod.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({"schema": 1, "type": kind, "id": id,
		"version": "1", "dependencies": dependencies, "files": files}))
	f.close()

func _session() -> GameSession:
	var s := GameSession.new()
	s.registry = ActorRegistry.new()
	s.player_id = s.registry.spawn(1, Vector2(2.5, 3.5), 10, 10)
	s.quest_log = QuestCast.new()
	s.items = ItemInstances.new()
	s.sim = Sim.new()
	return s

func _remove_tree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.include_hidden = true
	for name in dir.get_files():
		DirAccess.remove_absolute(path.path_join(name))
	for name in dir.get_directories():
		_remove_tree(path.path_join(name))
	DirAccess.remove_absolute(path)
