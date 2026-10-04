class_name SaveStore
extends RefCounted
## P1: atomic, version-validated JSON persistence for session snapshots.
## Writes go to a temp file in the same directory, then rename — an
## interrupted write leaves the previous save intact. Reads validate the
## schema version and refuse corrupt/missing/unknown files with an EMPTY
## return + push_error; the caller treats empty as "no save", never as
## "fresh game" (that decision belongs to the boot flow, explicitly).

const SCHEMA_KEY := "schema"


## Atomic write. Returns "" on success, else the reason.
static func save(path: String, snap: Dictionary) -> String:
	var dir := path.get_base_dir()
	if DirAccess.make_dir_recursive_absolute(dir) != OK:
		return "cannot create %s" % dir
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return "cannot open %s (%s)" % [tmp, error_string(FileAccess.get_open_error())]
	f.store_string(JSON.stringify(snap, "\t"))
	f.close()
	# Rename is atomic on the same filesystem; a crash before it leaves the
	# previous save intact.
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var err := DirAccess.rename_absolute(tmp, path)
	if err != OK:
		return "rename %s -> %s failed (%s)" % [tmp, path, error_string(err)]
	return ""


## Read + validate. Returns the snapshot Dictionary, or {} on ANY failure
## (missing, corrupt, wrong schema) with push_error naming the reason.
## Empty is "no usable save" — the caller must not silently start fresh.
## The caller supplies its snapshot contract: GameSession uses its composite
## schema, while fragment checks use SaveState.SCHEMA.
static func load(path: String, expected_schema: int = SaveState.SCHEMA) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("SaveStore: no save at %s" % path)
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("SaveStore: cannot open %s (%s)" % [path,
			error_string(FileAccess.get_open_error())])
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("SaveStore: %s is not a JSON object" % path)
		return {}
	if int(parsed.get(SCHEMA_KEY, -1)) != expected_schema:
		push_error("SaveStore: %s has schema %s, engine speaks %d -- refusing"
			% [path, str(parsed.get(SCHEMA_KEY)), expected_schema])
		return {}
	return parsed


## Slot enumeration for a future save UI: every *.json in user://saves/,
## newest first.
static func list_slots() -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open("user://saves")
	if dir == null:
		return out
	var names: Array[String] = []
	for n in dir.get_files():
		if n.ends_with(".json"):
			names.append(n)
	names.sort_custom(func(a: String, b: String) -> bool:
		return FileAccess.get_modified_time("user://saves/" + a) \
			> FileAccess.get_modified_time("user://saves/" + b))
	for n in names:
		out.append("user://saves/" + n)
	return out
