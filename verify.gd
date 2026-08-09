extends SceneTree
## Parity harness: prints the same facts analysis/tools/verify_ref.py prints,
## so the Godot readers can be diffed against the Python decode byte-for-byte.
##
##   godot --headless --path godot-port --script res://verify.gd
##
## This is the project's only test. It is deliberately a printout plus a diff
## rather than a framework -- see AGENTS.md "Build, test, and deployment".

const SECTORS := [[49, 49], [50, 50], [51, 51], [0, 15], [14, 19], [31, 24], [99, 99]]
## Deviation from 04-01-PLAN.md Task 3's literal text (documented in
## 04-01-SUMMARY.md): the task says to sample SECTORS directly, but every
## one of its 7 entries carries zero regions (measured, not assumed), which
## would leave the acceptance criteria "at least one sampled sector reports
## a non-zero region count" and "the md5 column discriminates" impossible
## to satisfy simultaneously with reusing SECTORS unmodified. Follows this
## file's own existing convention instead -- SECTORS/TEXTURES/MODELS are
## already three independent per-layer sample lists, mirrored verbatim on
## analysis/tools/verify_ref.py -- rather than mutating the pre-existing
## SECTORS list and touching the `sector` fact line Phase 1-3 already rely
## on. 64,39 is the four-co-located-region landmark sacred.gd:389 and
## walkable.gd:35-36 already document; 4,37 and 52,51 (near the Task 1
## derived spawn) were found by scanning real sector data, not guessed;
## 0,15 / 14,19 / 31,24 / 99,99 are carried over from SECTORS to keep the
## zero-region/zero-signal path genuinely exercised too.
const WALKABLE_SECTORS := [[64, 39], [4, 37], [52, 51], [0, 15], [14, 19], [31, 24], [99, 99]]
const TEXTURES := [0, 1, 2, 1000, 5000, 20000]
## BAT.GRN, GLADIATOR.GRN, GLAD_SA5_SHOULDER.GRN -- mirrored verbatim in
## analysis/tools/verify_ref.py's MODELS constant, 03-PATTERNS.md's sample.
const MODELS := [1, 589, 203]

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
	var models_pak := Sacred.Pak.new(install.path_join("pak/models.pak"))
	var world := Sacred.World.new(install.path_join("world"))
	if not (tiles_pak.is_open() and tex_pak.is_open() and models_pak.is_open() and world.is_open()):
		quit(1)
		return

	_pak_facts("tiles.pak", tiles_pak)
	_pak_facts("texture.pak", tex_pak)
	_pak_facts("models.pak", models_pak)
	print("world\tcount=%d\tgrid=%dx%d" % [world.count(), world.size.x, world.size.y])

	for s: Array in SECTORS:
		var d := world.sector(s[0], s[1])
		print("sector\t%d,%d\tlen=%d\tmd5=%s" % [s[0], s[1], d.size(), _md5(d)])

	# Walkability layer -- one fact line per sampled sector, between the sector
	# block and the tiles block on BOTH sides of the harness (04-01-PLAN.md
	# Task 3). Reads through Sacred.Regions and Walkable.class_is_open(), the
	# same allowlist Task 1 introduced -- never a second copy of it written
	# for this harness (the same "reimplementing the thing it tests only ever
	# agrees with itself" posture the bones block above already documents).
	# An absent/undersized sector's stream still runs through Sacred.Regions,
	# whose own _init() degrades it to an empty list -- so this loop needs no
	# special case for "sector missing" versus "sector present, no regions":
	# both produce regions=0 cells=0 open=0 and the md5 of the empty string.
	for s: Array in WALKABLE_SECTORS:
		var stream := world.sector(s[0], s[1])
		var regions := Sacred.Regions.new(stream, s[0], s[1])
		var cells := 0
		var open_cells := 0
		var text := ""
		for r: Dictionary in regions.list:
			var anchor: Vector2i = r["cell"]
			var size: Vector2i = r["size"]
			text += "%d,%d,%d,%d" % [anchor.x, anchor.y, size.x, size.y]
			for cy in size.y:
				for cx in size.x:
					cells += 1
					if Walkable.class_is_open(Sacred.Regions.cell_class(r, cx, cy)):
						open_cells += 1
						text += "1"
					else:
						text += "0"
			text += "\n"
		print("walkable\t%d,%d\tregions=%d\tcells=%d\topen=%d\tmd5=%s" % [
			s[0], s[1], regions.list.size(), cells, open_cells, _md5(text.to_utf8_buffer())])

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

	# Tag-walk layer only -- kind, derived length, tag count, triples md5.
	# Never a hash of decoded mesh data (03-04-PLAN.md, Pitfall 8). The
	# triples md5 is the simple tag,offset,length format Plan 03 specified
	# (analysis/tools/grn_tagwalk.py's triples_md5 docstring), not
	# grnwalk.gd's own richer _triples_md5 (which also hashes each object's
	# H1-declared length) -- that richer hash is grnwalk.gd's own diagnostic
	# tool and is left untouched; this fact line is new code with its own,
	# simpler, plan-specified definition. Sacred.Models.walk() never appends
	# the terminator tag itself as a triple, matching this line's Python
	# counterpart, which filters the terminator out before hashing.
	var models := Sacred.Models.new(models_pak)
	for idx: int in MODELS:
		if models.magic_ok(idx):
			var triples := models.walk(idx)
			var text := ""
			for t: Dictionary in triples:
				text += "%d,%d,%d\n" % [t["tag"], t["off"], t["len"]]
			print("models\t%d\tname=%s\tkind=%d\tlen=%d\ttags=%d\tmd5=%s" % [
				idx, models.entry_name(idx), models.kind_of(idx), models.true_length(idx),
				triples.size(), _md5(text.to_utf8_buffer())])
		else:
			print("models\t%d\tname=%s\tkind=%d\tlen=%d\ttags=0\tmd5=d41d8cd98f00b204e9800998ecf8427e" % [
				idx, models.entry_name(idx), models.kind_of(idx), models.true_length(idx)])

	# Skeleton layer. Two facts per sampled model, between the models block and
	# the layer check on BOTH sides of the harness.
	#
	# The md5 is over the RAW STORED BONE BYTES -- parent indices, translations,
	# rotations and scale-shears exactly as they sit in the file -- not over
	# constructed Transform3D values. Both sides therefore compute it from
	# offsets, and neither needs the other's matrix decoder to be identical for
	# the hash to mean anything (03-04-PLAN.md, Pitfall 8).
	#
	# The facts come from ModelView.rig_facts(), i.e. from the PRODUCTION rig
	# builder, not from a second skeleton implementation written for this
	# harness. A harness that reimplements the thing it tests only ever agrees
	# with itself.
	#
	# The `rest_eq_bind` fact line that stood beside `bones` has been removed
	# from BOTH sides of the harness, because the assertion behind it was
	# circular and could not fail. Removing it from one side only would have
	# broken parity, and keeping it would have kept a green light that meant
	# nothing. `bones` stays: its md5 is over the raw stored bone bytes, which
	# is a real cross-implementation comparison.
	for idx: int in MODELS:
		var mv := ModelView.new()
		var f := mv.rig_facts(models, idx)
		mv.free()
		if f.is_empty() or int(f["count"]) == 0:
			print("bones\t%d\tcount=0\troots=0\tbinds=0\tsanitised=0\tmd5=%s" % [
				idx, _md5(PackedByteArray())])
			continue
		print("bones\t%d\tcount=%d\troots=%d\tbinds=%d\tsanitised=%d\tmd5=%s" % [
			idx, int(f["count"]), int(f["roots"]), int(f["binds"]), int(f["sanitised"]),
			_md5(models.bone_bytes(idx))])

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
