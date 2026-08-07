extends SceneTree
## Parity harness: prints the same facts analysis/tools/verify_ref.py prints,
## so the Godot readers can be diffed against the Python decode byte-for-byte.
##
##   godot --headless --path godot-port --script res://verify.gd
##
## This is the project's only test. It is deliberately a printout plus a diff
## rather than a framework -- see AGENTS.md "Build, test, and deployment".

const SECTORS := [[49, 49], [50, 50], [51, 51], [0, 15], [14, 19], [31, 24], [99, 99]]
const TEXTURES := [0, 1, 2, 1000, 5000, 20000]

## world/ never touches the scene tree/threads; view/ never names a world
## type or defines its own per-frame entry point -- checked, not just written.
const LAYER_RULES := {
	"res://world": ["Node3D", "MeshInstance3D", "add_child", "get_tree", "queue_free",
		"SectorView", "IsoCamera", "Thread", "WorkerThreadPool", "call_deferred"],
	"res://view": ["ActorRegistry", "ActorState", "RecordStore", "Sim.",
		"func _process(", "func _physics_process("],
}

func _init() -> void:
	var install := Sacred.find_install()
	if install == "":
		printerr("no install found; pass --install=/path/to/install")
		quit(1)
		return
	print("install\t%s" % install)

	var tiles_pak := Sacred.Pak.new(install.path_join("pak/tiles.pak"))
	var tex_pak := Sacred.Pak.new(install.path_join("pak/texture.pak"))
	var world := Sacred.World.new(install.path_join("world"))
	if not (tiles_pak.is_open() and tex_pak.is_open() and world.is_open()):
		quit(1)
		return

	_pak_facts("tiles.pak", tiles_pak)
	_pak_facts("texture.pak", tex_pak)
	print("world\tcount=%d\tgrid=%dx%d" % [world.count(), world.size.x, world.size.y])

	for s: Array in SECTORS:
		var d := world.sector(s[0], s[1])
		print("sector\t%d,%d\tlen=%d\tmd5=%s" % [s[0], s[1], d.size(), _md5(d)])

	var tiles := Sacred.Tiles.new(tiles_pak)
	print("tiles\tcount=%d\ttex0=%d\ttexlast=%d" % [
		tiles.count(), tiles.texture_id(0), tiles.texture_id(tiles.count() - 1)])

	for id: int in TEXTURES:
		var t0 := Time.get_ticks_usec()
		var img := Sacred.decode_texture(tex_pak, id)
		if img == null:
			print("texture\t%d\tERROR" % id)
			continue
		print("texture\t%d\t%dx%d\tmd5=%s\t%d us" % [
			id, img.get_width(), img.get_height(), _md5(img.get_data()),
			Time.get_ticks_usec() - t0])

	_layer_check()
	quit(0)


func _pak_facts(label: String, p: Sacred.Pak) -> void:
	var n := p.count()
	print("pak\t%s\tcount=%d\tfirst=%d,%d\tlast=%d,%d" % [
		label, n, p.offsets[0], p.sizes[0], p.offsets[n - 1], p.sizes[n - 1]])


func _md5(b: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	ctx.update(b)
	return ctx.finish().hex_encode()


## Forbidden-token scan; violations print file:line:token on stderr, last
## stdout line is always "layer\tfiles=<n>\tviolations=<n>".
func _layer_check() -> void:
	var files := 0
	var violations := 0
	var dirs := LAYER_RULES.keys()
	dirs.sort()
	for dir_path: String in dirs:
		var forbidden: Array = LAYER_RULES[dir_path]
		var names := DirAccess.get_files_at(dir_path)
		names.sort()
		for name: String in names:
			if not name.ends_with(".gd"):
				continue
			files += 1
			var path := dir_path.path_join(name)
			var lines := _strip_comments(FileAccess.get_file_as_string(path)).split("\n")
			for i in lines.size():
				for token: String in forbidden:
					if token in lines[i]:
						violations += 1
						printerr("%s:%d:%s" % [path, i + 1, token])
	print("layer\tfiles=%d\tviolations=%d" % [files, violations])


## Blanks comment-only lines, truncates inline ones -- preserves line count.
func _strip_comments(src: String) -> String:
	var out: Array[String] = []
	for line: String in src.split("\n"):
		if line.strip_edges().begins_with("#"):
			out.append("")
			continue
		var hash_idx := line.find("#")
		out.append(line if hash_idx == -1 else line.substr(0, hash_idx))
	return "\n".join(out)
