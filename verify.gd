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
