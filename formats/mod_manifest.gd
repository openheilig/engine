extends RefCounted
## D1 support class: DATA-ONLY whole-file data and retail bytecode.
## mod.json schema 1:
## {"schema":1,"type":"data-only","id":"my-package","version":"1",
##  "dependencies":[{"id":"other-package","version":"1"}],
##  "files":{"pak/items.pak":"pak/items.pak"}}
## Dependencies require exact versions. Selection order breaks independent
## ties; dependencies precede dependents; the last package wins a whole file.
## No record merging, new record namespace, native plugins or Godot resources.
## Bare --mod directories are explicit content-addressed packages, not ignored.
##
## Identity is SHA-256 over sorted runtime base files, ordered package metadata
## and every selected package file. Full bytes are streamed ONCE at composition,
## including same-size changes, never per image. Runtime data directories and
## retail executable tables are covered; saves/config, derived caches and
## unused retail native lib/ shared libraries are not engine inputs.
## This conservative boot IO is unbenchmarked and may be expensive (movie/mp3).
## The mounted input tree must remain unchanged for the lifetime of a session;
## changing content requires restart/recomposition, not live file hot-reloading.

const Pak := preload("res://formats/pak.gd")
const MANIFEST := "mod.json"
const SCHEMA := 1
const POLICY := "whole-file-data-v1"
const HASH_CHUNK := 1024 * 1024
const MAX_MANIFEST_BYTES := 1024 * 1024
## Conservative admission budget, not a retail format maximum. Parent's
## observed Dwarf funkcode is about 4 MiB, startcode below 1 MiB. All .bin
## replacements (including start/funk/quest/questpool/vectoren bytecode)
## are capped at 64 MiB before any bulk reader allocates their contents.
const MAX_BIN_BYTES := 64 * 1024 * 1024
const RUNTIME_DIRS := ["pak", "world", "bin", "scripts", "templates", "movie", "mp3"]
const CODE_EXTENSIONS := ["gd", "gdc", "cs", "dll", "so", "dylib", "exe", "pck", "gdextension", "gdnlib", "gdns", "tscn", "scn", "tres", "wasm", "py", "sh", "bat", "com", "jar"]

var _root: String = ""
var _errors: PackedStringArray = []
var _packages: Array[Dictionary] = []
var _files: Dictionary = {}
var _identity: Dictionary = {}

## Construct completely before Pak.configure_profile() or gameplay readers.
## Call through preload("res://formats/mod_manifest.gd").new(install, roots);
## fresh headless starts must not depend on an editor-generated class cache.
## package_roots is the explicit enabled selection, not a directory search path.
func _init(install_path: String, package_roots: Array = []) -> void:
	var p := self
	if install_path.is_empty():
		p._errors.append("install root is empty")
		return
	p._root = _absolute(install_path)
	if not DirAccess.dir_exists_absolute(p._root):
		p._errors.append("install root does not exist: %s" % p._root)
		return
	var base_files: Dictionary = {}
	var dir := DirAccess.open(p._root)
	if dir == null:
		p._errors.append("cannot enumerate install root: %s" % p._root)
		return
	dir.include_hidden = true
	for name in dir.get_directories():
		if name.to_lower() in RUNTIME_DIRS:
			if dir.is_link(name):
				p._errors.append("runtime directory symlink is refused: %s" % name)
			else:
				p._scan(p._root, name, base_files, false)
	for name in dir.get_files():
		if name.to_lower() in ["sacred", "sacred.exe"]:
			if dir.is_link(name):
				p._errors.append("retail executable symlink is refused: %s" % name)
			else:
				p._add_file(base_files, name.to_lower(), p._root.path_join(name))
	if not p._errors.is_empty():
		return
	var selected: Dictionary = {}
	var selected_ids: Array[String] = []
	for value: Variant in package_roots:
		if not value is String:
			p._errors.append("package root is not a string")
			continue
		var package := p._read_package(_absolute(value))
		if package.is_empty():
			continue
		var id: String = package["id"]
		if selected.has(id):
			p._errors.append("duplicate package id: %s" % id)
			continue
		selected[id] = package
		selected_ids.append(id)
	if not p._errors.is_empty():
		return
	var marks: Dictionary = {}
	for id in selected_ids:
		p._visit(id, selected, marks, [])
	if not p._errors.is_empty():
		return
	for logical: String in _sorted_keys(base_files):
		var source: String = base_files[logical]
		var entry := p._fingerprint(logical, source, "vanilla", "")
		if not entry.is_empty():
			p._files[logical] = [entry]
	if not p._errors.is_empty():
		return
	for package: Dictionary in p._packages:
		for logical: String in _sorted_keys(package["files"]):
			var entry: Dictionary = package["files"][logical]
			if not p._files.has(logical):
				p._files[logical] = []
			p._files[logical].append(entry)
	# No filesystem paths or timestamps in identity: moving an identical
	# corpus/profile is safe, replacing equal-length bytes is not.
	var contract: Dictionary = {"schema": SCHEMA, "policy": POLICY, "base": [], "packages": []}
	for logical: String in _sorted_keys(base_files):
		if p._files.has(logical):
			contract["base"].append(_identity_file(p._files[logical][0]))
	var package_ids: Array[Dictionary] = []
	for package: Dictionary in p._packages:
		var files: Array = []
		for logical: String in _sorted_keys(package["files"]):
			files.append(_identity_file(package["files"][logical]))
		contract["packages"].append({"id": package["id"], "version": package["version"],
			"dependencies": package["dependencies"], "files": files})
		package_ids.append({"id": package["id"], "version": package["version"]})
	p._identity = {"schema": SCHEMA, "policy": POLICY,
		"sha256": JSON.stringify(contract).sha256_text(), "packages": package_ids}

func ok() -> bool:
	return _errors.is_empty() and not _identity.is_empty()

func error_text() -> String:
	return "\n".join(_errors)

func install_root() -> String:
	return _root

func matches_install(install_path: String) -> bool:
	return not install_path.is_empty() and _absolute(install_path) == _root

func identity() -> Dictionary:
	return _identity.duplicate(true)

func package_order() -> PackedStringArray:
	var ids := PackedStringArray()
	for package: Dictionary in _packages:
		ids.append(package["id"])
	return ids

## Ordered provenance: vanilla first (when present), conflict winner last.
func provenance(logical_path: String) -> Array:
	return _files.get(logical_path.to_lower(), []).duplicate(true)

func diagnostics() -> PackedStringArray:
	var lines := PackedStringArray(["profile\tDATA-ONLY\tsha256=%s\torder=%s" % [
		_identity.get("sha256", "invalid"), ",".join(package_order())]])
	for logical: String in _sorted_keys(_files):
		var chain: Array = _files[logical]
		if chain.size() > 1 or chain[0]["package"] != "vanilla":
			var candidates := PackedStringArray()
			for entry: Dictionary in chain:
				candidates.append("%s@%s:%s" % [entry["package"], entry["version"], entry["source"]])
			lines.append("profile_file\t%s\twinner=%s\tprovenance=%s" % [logical,
				chain.back()["package"], " -> ".join(candidates)])
	return lines

func resolve(archive_path: String) -> String:
	var requested := _absolute(archive_path)
	if not ok() or not requested.begins_with(_root + "/"):
		return archive_path
	var logical := requested.substr(_root.length() + 1).to_lower()
	if _files.has(logical):
		return _files[logical].back()["source"]
	return archive_path

func is_mod_archive(archive_path: String) -> bool:
	var requested := _absolute(archive_path)
	if not requested.begins_with(_root + "/"):
		return false
	var logical := requested.substr(_root.length() + 1).to_lower()
	return _files.has(logical) and _files[logical].back()["package"] != "vanilla"

static func same_identity(saved: Variant, current: Dictionary) -> bool:
	if not saved is Dictionary or current.is_empty() or saved.size() != current.size():
		return false
	var schema: Variant = saved.get("schema")
	if not (schema is int or schema is float) or schema != current.get("schema"):
		return false
	for key in ["policy", "sha256"]:
		if not saved.get(key) is String or saved[key] != current.get(key):
			return false
	var packages: Variant = saved.get("packages")
	var active: Variant = current.get("packages")
	if not packages is Array or not active is Array or packages.size() != active.size():
		return false
	# JSON turns typed arrays into ordinary arrays. Compare package values,
	# not container types; schema equality above also admits JSON's exact 1.0.
	for i in packages.size():
		if not packages[i] is Dictionary or packages[i] != active[i]:
			return false
	return true

func _read_package(root: String) -> Dictionary:
	if not DirAccess.dir_exists_absolute(root) or _path_has_link(root):
		_errors.append("package root is missing or symlinked: %s" % root)
		return {}
	var inventory: Dictionary = {}
	_scan(root, "", inventory, true)
	if not _errors.is_empty():
		return {}
	var manifest_path := root.path_join(MANIFEST)
	var declared: Dictionary = {}
	var id := ""
	var version := ""
	var dependencies: Array = []
	if FileAccess.file_exists(manifest_path):
		var f := FileAccess.open(manifest_path, FileAccess.READ)
		if f == null or f.get_length() > MAX_MANIFEST_BYTES:
			_errors.append("cannot read bounded manifest: %s" % manifest_path)
			return {}
		var value: Variant = JSON.parse_string(f.get_as_text())
		f.close()
		if not value is Dictionary:
			_errors.append("manifest is not a JSON object: %s" % manifest_path)
			return {}
		for key: Variant in value:
			if key not in ["schema", "type", "id", "version", "dependencies", "files"]:
				_errors.append("unsupported manifest field %s (DATA-ONLY whole-file schema)" % str(key))
		if value.get("schema") != SCHEMA or value.get("type") != "data-only":
			_errors.append("manifest requires schema 1 and type data-only: %s" % manifest_path)
			return {}
		if not value.get("id") is String or not value.get("version") is String \
				or not _valid_id(value["id"]) or String(value["version"]).is_empty():
			_errors.append("manifest requires a stable id and nonempty string version: %s" % manifest_path)
			return {}
		id = value["id"]
		version = value["version"]
		if not value.get("dependencies") is Array or not value.get("files") is Dictionary:
			_errors.append("manifest requires dependencies array and whole-file files object: %s" % manifest_path)
			return {}
		dependencies = value["dependencies"]
		declared = value["files"]
	else:
		for logical: String in _sorted_keys(inventory):
			if logical == MANIFEST or logical.get_extension().to_lower() in ["txt", "md", "json"]:
				continue
			declared[logical] = inventory[logical].substr(root.length() + 1)
	var dependency_ids: Dictionary = {}
	for dependency: Variant in dependencies:
		if not dependency is Dictionary or dependency.size() != 2 \
				or not dependency.get("id") is String or not dependency.get("version") is String:
			_errors.append("dependency must contain exactly string id/version: %s" % root)
			continue
		if not _valid_id(dependency["id"]) or String(dependency["version"]).is_empty() \
				or dependency_ids.has(dependency["id"]):
			_errors.append("invalid or duplicate dependency: %s" % str(dependency))
		dependency_ids[dependency["id"]] = true
	var files: Dictionary = {}
	for logical: Variant in declared:
		var relative: Variant = declared[logical]
		if not logical is String or not relative is String \
				or not _safe_relative(logical) or not _safe_relative(relative):
			_errors.append("escaping/invalid whole-file path in %s: %s -> %s" % [root, str(logical), str(relative)])
			continue
		var key := String(logical).to_lower()
		if not _admitted_data_path(key):
			_errors.append("unsupported data-only/retail-bytecode replacement: %s" % key)
			continue
		if files.has(key):
			_errors.append("case-fold logical collision in package: %s" % key)
			continue
		var source := root.path_join(relative)
		if not FileAccess.file_exists(source) or _path_has_link(source):
			_errors.append("missing or symlinked package file: %s" % source)
			continue
		var validation := _validate_replacement(key, source)
		if validation != "":
			_errors.append(validation)
			continue
		var entry := _fingerprint(key, source, id, version)
		if not entry.is_empty():
			files[key] = entry
	if files.is_empty():
		_errors.append("data package has no supported whole-file replacements: %s" % root)
	if not _errors.is_empty():
		return {}
	if id.is_empty():
		var contract: Array = []
		for logical: String in _sorted_keys(files):
			contract.append(_identity_file(files[logical]))
		var digest := JSON.stringify(contract).sha256_text()
		id = "directory-" + digest
		version = digest
		for logical: String in files:
			files[logical]["package"] = id
			files[logical]["version"] = version
	return {"id": id, "version": version, "dependencies": dependencies, "files": files}

func _visit(id: String, selected: Dictionary, marks: Dictionary, stack: Array) -> void:
	if int(marks.get(id, 0)) == 2:
		return
	if int(marks.get(id, 0)) == 1:
		_errors.append("dependency cycle: %s -> %s" % [" -> ".join(stack), id])
		return
	marks[id] = 1
	var package: Dictionary = selected[id]
	var next_stack := stack.duplicate()
	next_stack.append(id)
	for dependency: Dictionary in package["dependencies"]:
		var other: String = dependency["id"]
		if not selected.has(other):
			_errors.append("package %s requires missing dependency %s@%s" % [id, other, dependency["version"]])
		elif selected[other]["version"] != dependency["version"]:
			_errors.append("package %s requires dependency %s@%s, selected %s" % [id, other,
				dependency["version"], selected[other]["version"]])
		else:
			_visit(other, selected, marks, next_stack)
	marks[id] = 2
	_packages.append(package)

func _scan(root: String, relative: String, files: Dictionary, package: bool) -> void:
	var dir := DirAccess.open(root.path_join(relative))
	if dir == null:
		_errors.append("cannot enumerate content directory: %s" % root.path_join(relative))
		return
	dir.include_hidden = true
	for name in dir.get_files():
		var path := relative.path_join(name) if relative != "" else name
		if dir.is_link(name):
			_errors.append("content symlink is refused: %s" % root.path_join(path))
		elif package and (name.to_lower().get_extension() in CODE_EXTENSIONS \
				or name.to_lower().contains(".so.") or name.to_lower() == "project.godot"):
			_errors.append("executable/Godot plugin content is refused in DATA-ONLY package: %s" % path)
		else:
			_add_file(files, path.to_lower(), root.path_join(path))
	for name in dir.get_directories():
		var path := relative.path_join(name) if relative != "" else name
		if dir.is_link(name):
			_errors.append("content directory symlink is refused: %s" % root.path_join(path))
		else:
			_scan(root, path, files, package)

func _add_file(files: Dictionary, logical: String, source: String) -> void:
	if files.has(logical):
		_errors.append("case-fold content collision: %s and %s" % [files[logical], source])
	else:
		files[logical] = source

func _fingerprint(logical: String, source: String, package: String, version: String) -> Dictionary:
	var f := FileAccess.open(source, FileAccess.READ)
	if f == null:
		_errors.append("cannot hash content: %s" % source)
		return {}
	var length := f.get_length()
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	var remaining := length
	while remaining > 0:
		var chunk := f.get_buffer(mini(HASH_CHUNK, remaining))
		if chunk.is_empty():
			_errors.append("content truncated while hashing: %s" % source)
			f.close()
			return {}
		context.update(chunk)
		remaining -= chunk.size()
	if f.get_length() != length:
		_errors.append("content length changed while hashing: %s" % source)
		f.close()
		return {}
	f.close()
	return {"path": logical, "source": source, "package": package, "version": version,
		"size": length, "sha256": context.finish().hex_encode()}

## Structural preflight only; retail-bytecode semantic admission remains with
## the existing VM/readers. These files are never loaded as Godot resources.
static func _validate_replacement(logical: String, path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "cannot read replacement: %s" % path
	var head := f.get_buffer(268)
	var length := f.get_length()
	f.close()
	if length == 0:
		return "empty data replacement: %s" % path
	if logical.begins_with("bin/") and length > MAX_BIN_BYTES:
		return "retail bytecode/data input exceeds %d-byte profile budget: %s" % [MAX_BIN_BYTES, path]
	if head.size() >= 4 and (head.decode_u32(0) == 0x464c457f \
			or head.decode_u16(0) == 0x5a4d or head.slice(0, 4).get_string_from_ascii() == "RSRC"):
		return "native executable/Godot resource disguised as data: %s" % path
	if logical == "pak/creature.pak":
		if head.size() < 256 or head.slice(0, 3).get_string_from_ascii() != "CIF" \
				or (length - 256) % 86 != 0:
			return "invalid flat CIF creature table: %s" % path
		return ""
	if logical == "pak/weapon.pak":
		if head.size() < 256 or head.slice(0, 3).get_string_from_ascii() != "WPN" or head[3] < 8:
			return "unsupported weapon parallel-table header: %s" % path
		if head.decode_u32(4) > (length - 256) / 322:
			return "truncated weapon parallel tables: %s" % path
		return ""
	if logical == "world/triggers.pak":
		if head.size() < 268 or head.decode_u32(0) != 0x01475254:
			return "invalid TRG v1 header: %s" % path
		return "" if head.decode_u32(4) <= (length - 268) / 16 else "truncated trigger table: %s" % path
	if logical.get_extension() == "pak":
		return Pak.validate_archive(path, "ISO" if logical == "pak/tiles.pak" else "")
	if logical.get_extension() == "res":
		return _validate_text_resource(path, head, length)
	if logical.get_extension() in ["ptx", "pax"]:
		return _validate_pax(path, head, length)
	# Raw .bin/.keyx/.wldx are data inputs to dedicated decoders, not plugins.
	return ""

static func _validate_text_resource(path: String, head: PackedByteArray, length: int) -> String:
	if head.size() < 12:
		return "truncated retail resource header: %s" % path
	var count := head.decode_u32(0)
	if count == 0 or count * 16 > Pak.MAX_INDEX_BYTES or 4 + count * 16 > length \
			or head.decode_u32(8) != count * 16:
		return "retail resource index exceeds file/resource bounds: %s" % path
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "cannot reopen retail resource: %s" % path
	f.seek(4)
	for i in count:
		var entry := f.get_buffer(16)
		if entry.size() != 16:
			f.close()
			return "truncated retail resource index: %s" % path
		var offset := entry.decode_u32(4)
		var size := entry.decode_u32(12)
		if offset < count * 16 or offset > length - 4 or size > length - offset - 4:
			f.close()
			return "retail resource entry %d exceeds file bounds: %s" % [i, path]
	f.close()
	return ""

static func _validate_pax(path: String, head: PackedByteArray, length: int) -> String:
	if head.size() < 256 or head.decode_u32(0) != 0x1b484d41:
		return "unsupported AMH v27 template/hero header: %s" % path
	var count := head.decode_u32(4)
	if count * 12 > Pak.MAX_INDEX_BYTES or 256 + count * 12 > length:
		return "AMH section index exceeds file/resource bounds: %s" % path
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "cannot reopen AMH template: %s" % path
	for i in count:
		f.seek(256 + i * 12)
		var entry := f.get_buffer(12)
		if entry.size() != 12:
			f.close()
			return "truncated AMH section index: %s" % path
		var type := entry.decode_u32(0)
		if type == 0:
			continue
		var offset := entry.decode_u32(4)
		var size := entry.decode_u32(8)
		if offset < 256 + count * 12 or offset > length - 4:
			f.close()
			return "AMH section offset exceeds file bounds: %s" % path
		f.seek(offset)
		var signature := f.get_32()
		if signature == 0xbaadc0de:
			var compressed_size := f.get_32()
			if offset + 32 > length or compressed_size > length - offset - 32 or size > 128 * 1024 * 1024:
				f.close()
				return "AMH compressed section exceeds file/resource bounds: %s" % path
		elif (64 if type == 0xc4 else size) > length - offset:
			f.close()
			return "AMH raw section exceeds file bounds: %s" % path
	f.close()
	return ""

static func _admitted_data_path(path: String) -> bool:
	var extension := path.get_extension()
	if path.begins_with("pak/"):
		return extension == "pak"
	if path.begins_with("world/"):
		return extension in ["pak", "keyx", "wldx"]
	if path.begins_with("bin/"):
		return extension == "bin"
	if path.begins_with("scripts/"):
		return extension == "res"
	if path.begins_with("templates/"):
		return extension in ["ptx", "pax"]
	return false

static func _identity_file(entry: Dictionary) -> Dictionary:
	return {"path": entry["path"], "size": entry["size"], "sha256": entry["sha256"]}

static func _absolute(path: String) -> String:
	if path.begins_with("user://") or path.begins_with("res://"):
		return ProjectSettings.globalize_path(path).simplify_path().trim_suffix("/")
	if not path.is_absolute_path():
		path = OS.get_environment("PWD").path_join(path)
	return path.simplify_path().trim_suffix("/")

static func _safe_relative(path: String) -> bool:
	if path.is_empty() or path.is_absolute_path() or path.contains("\\") or path.contains(":"):
		return false
	for i in path.length():
		if path.unicode_at(i) < 32 or path.unicode_at(i) == 127:
			return false
	for part: String in path.split("/", true):
		if part.is_empty() or part in [".", ".."]:
			return false
	return true

static func _path_has_link(path: String) -> bool:
	var current := path
	while current != "" and current != current.get_base_dir():
		var parent := DirAccess.open(current.get_base_dir())
		if parent != null and parent.is_link(current.get_file()):
			return true
		current = current.get_base_dir()
	return false

static func _valid_id(id: String) -> bool:
	if id.is_empty() or id == "vanilla":
		return false
	for i in id.length():
		if not id.substr(i, 1) in "abcdefghijklmnopqrstuvwxyz0123456789._-":
			return false
	return true

static func _sorted_keys(dict: Dictionary) -> Array:
	var keys := dict.keys()
	keys.sort()
	return keys
