extends SceneTree
## Tag-walk dumper for one Granny .GRN entry, or a corpus-wide sweep, in
## pak/models.pak.
##
##   godot --headless --path godot-port --script res://grnwalk.gd -- --grn-index=589
##   godot --headless --path godot-port --script res://grnwalk.gd -- --census=589
##   godot --headless --path godot-port --script res://grnwalk.gd -- --corpus
##   godot --headless --path godot-port --script res://grnwalk.gd -- --falsify=1
##
## Prints, tab-separated:
##   grn    <index>  name=...  kind=...  true_len=...  magic_off=...  magic_ok=...
##   tag    <index>  <ordinal>  <entry-relative offset, decimal>  <tag, 0x%08x>  <length, decimal>
##   grnend <index>  tags=<count>  consumed=<entry-relative bytes>  md5=<hex>
##          h1=confirmed|refuted  objects=<count>  h1_bytes=<sum of H1 object lengths>  true_len=<n>
##   census <index>  <entry-relative offset, decimal>  <u32 value, decimal>
##          -- one line per u32 word inside every header/leaf chunk walk() recognises,
##          only emitted with --census=N, for finding the untagged bulk-region length
##          field by elimination if H1 is refuted (03-01-PLAN.md Task 2).
##   corpus entries=<n>  walkable=<n>  skipped=<n>  walked_mesh=<n>  walked_motion=<n>
##          [falsify=<N>, only when --falsify=N was passed, including N=0]
##   skip   <index>  name=...  kind=...  reason=...
##          -- one line per entry Models.magic_ok() rejects; the reason is derived
##          from the same two checks magic_ok() itself performs, never from an
##          index literal or a size cutoff (03-02-PLAN.md Task 1).
##   legend -- explains that the root tag's files= count is definitional (equal
##          to walkable= by construction) and carries no independent signal.
##   tagcount 0x<tag,%08x>  files=<distinct entries containing it>  total=<occurrences>
##          definitional=true|false -- the four documented tags first in ascending
##          tag order, then every other tag discovered, also ascending.
##   invariant walkable_eq_4991=<bool>  files_eq_4991_tags=<n>  total_eq_4991_tags=<n>
##          verdict=PASS|FAIL -- verdict driven solely by walkable==4991 and skipped==2.
## --corpus sweeps every entry once; --falsify=N repeats the identical sweep with
## every per-chunk advance offset by N extra bytes, desynchronising the walk
## exactly as a real off-by-N bug would, to prove the corpus invariant can fail
## (03-02-PLAN.md "the central trap this plan exists to defeat"). --falsify=0
## must reproduce --corpus's numbers exactly, marker aside.
##
## Never reads Iris1 (GPL) or the statically-linked Granny runtime -- every
## offset comes from .planning/phases/03-granny-grn-tag-walk-then-posed-mesh/03-RESEARCH.md.
## See Sacred.Models in godot-port/sacred.gd for the actual walk.

func _init() -> void:
	var install := Sacred.find_install()
	if install == "":
		printerr("no install found; pass --install=/path/to/install")
		quit(1)
		return

	var argv := OS.get_cmdline_user_args() + OS.get_cmdline_args()
	var grn_index := -1
	var census_index := -1
	var do_corpus := false
	var has_falsify := false
	var falsify_offset := 0
	var has_meshdump := false
	var meshdump_index := -1
	for a in argv:
		if a.begins_with("--grn-index="):
			grn_index = int(a.trim_prefix("--grn-index="))
		elif a.begins_with("--census="):
			census_index = int(a.trim_prefix("--census="))
		elif a == "--corpus":
			do_corpus = true
		elif a.begins_with("--falsify="):
			has_falsify = true
			falsify_offset = int(a.trim_prefix("--falsify="))
		elif a.begins_with("--meshdump="):
			has_meshdump = true
			meshdump_index = int(a.trim_prefix("--meshdump="))

	if grn_index < 0 and census_index < 0 and not do_corpus and not has_falsify and not has_meshdump:
		printerr("usage: grnwalk.gd -- --grn-index=N | --census=N | --meshdump=N | --corpus | --falsify=N")
		quit(1)
		return

	var pak := Sacred.Pak.new(install.path_join("pak/models.pak"))
	if not pak.is_open():
		quit(1)
		return

	var models := Sacred.Models.new(pak)
	if grn_index >= 0:
		_dump(models, grn_index)
	if census_index >= 0:
		_census(pak, models, census_index)
	if do_corpus or has_falsify:
		_corpus(pak, models, falsify_offset, has_falsify)
	if has_meshdump:
		_meshdump(models, meshdump_index)
	quit(0)


## Geometry report for one entry (Plan 05). Always exits 0, including for an
## entry with no decodable mesh -- a malformed entry is a fact to print, not a
## crash, and index 0 (INVALID_MODEL) and 1572 (INVALID_MOTION) are the
## standing proof that the reject path is reached by the reader's own checks.
func _meshdump(models: Sacred.Models, idx: int) -> void:
	var name := models.entry_name(idx)
	var basis := models.coordinate_basis(idx)
	var basis_status := "located" if models.last_basis_located else "unlocated"
	var arrays := models.mesh_arrays(idx)
	if arrays.is_empty():
		print("meshdump\t%d\tname=%s\tok=false\treason=no-decodable-mesh\tverts=0\ttris=0\tbasis=%s" % [
			idx, name, basis_status])
		return
	var indices: PackedInt32Array = arrays["indices"]
	print("meshdump\t%d\tname=%s\tok=true\tverts=%d\ttris=%d\tindices=%d\tidx_max=%d\tmeshes=%d\tsrc_pos=%d\tsrc_nrm=%d\tuvs=%d\tbasis=%s\tbasis_row0=(%f,%f,%f)" % [
		idx, name, arrays["vertex_count"], arrays["triangle_count"], indices.size(),
		arrays["index_max"], arrays["meshes"], arrays["source_positions"],
		arrays["source_normals"], (arrays["uvs"] as PackedVector2Array).size(),
		basis_status, basis.x.x, basis.x.y, basis.x.z])


func _dump(models: Sacred.Models, idx: int) -> void:
	var kind := models.kind_of(idx)
	var magic_off := models.magic_offset(idx)
	var ok := models.magic_ok(idx)
	print("grn\t%d\tname=%s\tkind=%d\ttrue_len=%d\tmagic_off=%d\tmagic_ok=%s" % [
		idx, models.entry_name(idx), kind, models.true_length(idx), magic_off,
		"true" if ok else "false"])

	var triples := models.walk(idx)
	for j in triples.size():
		var t: Dictionary = triples[j]
		print("tag\t%d\t%d\t%d\t0x%08x\t%d" % [idx, j, t["off"], t["tag"], t["len"]])

	var meta := models.last_walk_meta
	var consumed: int = meta.get("consumed", magic_off)
	var h1_verdict := "confirmed" if meta.get("h1_confirmed", false) else "refuted"
	var object_lengths: Array = meta.get("object_lengths", [])
	print("grnend\t%d\ttags=%d\tconsumed=%d\tmd5=%s\th1=%s\tobjects=%d\th1_bytes=%d\ttrue_len=%d" % [
		idx, triples.size(), consumed, _triples_md5(triples, object_lengths),
		h1_verdict, meta.get("objects", 0), meta.get("h1_bytes", 0), models.true_length(idx)])


## Prints every u32 word inside every header/leaf chunk walk() recognises for
## entry idx -- the header chain's own fields plus both u32s of every 12-byte
## leaf payload -- so the field encoding the untagged bulk region's length can
## be found by elimination across entries of different true_length, per H1's
## refutation path (03-RESEARCH.md "Chunk stream structure", Assumption A3).
## Silently does nothing for an entry that fails magic_ok().
##
## Plan 05 Task 1 extension: also dumps the shape of the untagged BULK region
## -- everything after the last object's terminator and before the entry's
## own end -- since that region is where the mesh geometry must live (the
## header/leaf chunks above are fixed-size and too small to hold it). Prints
## one `bulk` summary line (region start/end, byte length) and one
## `bulkfloat`/`bulkrun` line per stated hypothesis's raw measurement, so the
## hypotheses below can be verified or refuted by a human reading the output,
## not asserted from code that already assumes the answer.
func _census(pak: Sacred.Pak, models: Sacred.Models, idx: int) -> void:
	var triples := models.walk(idx)
	for t: Dictionary in triples:
		var off: int = t["off"]
		var size: int = t["len"]
		var word := off
		while word + 4 <= off + size:
			var buf := pak.read_at(pak.entry_offset(idx) + word, 4)
			if buf.size() < 4:
				break
			print("census\t%d\t%d\t%d" % [idx, word, buf.decode_u32(0)])
			word += 4

	if triples.is_empty():
		return
	var last: Dictionary = triples[triples.size() - 1]
	var header_end: int = int(last["off"]) + int(last["len"])   # start of the terminator tag
	var bulk_start := header_end + 4                             # skip the 4-byte terminator itself
	var true_len := models.true_length(idx)
	if bulk_start >= true_len:
		print("bulk\t%d\tstart=%d\tend=%d\tlen=0" % [idx, bulk_start, true_len])
		return
	var bulk_len := true_len - bulk_start
	print("bulk\t%d\tstart=%d\tend=%d\tlen=%d" % [idx, bulk_start, true_len, bulk_len])

	var buf := pak.read_at(pak.entry_offset(idx) + bulk_start, bulk_len)

	# Hypothesis F1 (stated before measuring): a plausible model-space float32
	# magnitude sits in [1e-6, 1e4) or is exactly 0.0 -- refuted for a given
	# alignment if the count of words in-band is small relative to bulk_len/4,
	# since real per-vertex data (positions/normals/UVs, all small numbers)
	# should dominate a correctly-aligned float stream.
	var float_words := bulk_len / 4
	var in_band := 0
	for w in float_words:
		var f := buf.decode_float(w * 4)
		if f == 0.0 or (absf(f) >= 1e-6 and absf(f) < 1e4):
			in_band += 1
	print("bulkfloat\t%d\twords=%d\tin_band=%d" % [idx, float_words, in_band])

	# Hypothesis I1/I2 (stated before measuring): if the tail of the bulk
	# region is a triangle index list, u16 runs (or u32 runs) with every value
	# below some candidate vertex count V should exist. Rather than guess V,
	# report the max u16 and max u32 value across the whole region so a human
	# can compare it against whatever vertex count the leaf-chunk census (or a
	# later small-leading-header read) turns up.
	var u16_words := bulk_len / 2
	var max_u16 := 0
	for w in u16_words:
		max_u16 = maxi(max_u16, buf.decode_u16(w * 2))
	var max_u32 := 0
	for w in float_words:
		max_u32 = maxi(max_u32, buf.decode_u32(w * 4))
	print("bulkrun\t%d\tu16_words=%d\tmax_u16=%d\tu32_words=%d\tmax_u32=%d" % [
		idx, u16_words, max_u16, float_words, max_u32])


## Sweeps every entry of models.pak in ascending index order and prints a
## tab-separated corpus report. Classification uses Models.magic_ok() alone --
## the single exclusion predicate for the whole phase, per sacred.gd's own
## header comment on that method; this loop adds no second skip rule of its
## own. When an entry is skipped, the printed reason is derived from the same
## two checks magic_ok() performs internally (offset reachability, then the
## magic value itself), not from a separate condition.
##
## offset is the falsify desync in bytes, applied to every per-chunk advance
## inside the walk (0 for a clean sweep). explicit_falsify controls only
## whether the trailing `falsify=<offset>` marker is printed on the `corpus`
## line -- plain --corpus (no --falsify flag at all) always sweeps at offset 0
## and never prints the marker, so its output is byte-identical to
## `--falsify=0`'s once the marker is stripped.
func _corpus(pak: Sacred.Pak, models: Sacred.Models, offset: int, explicit_falsify: bool) -> void:
	var n := models.count()
	var walkable := 0
	var skipped := 0
	var walked_mesh := 0
	var walked_motion := 0
	var skip_lines: Array[String] = []
	var files := {}   # tag (int) -> distinct entries containing it
	var total := {}   # tag (int) -> total occurrences across the corpus

	for i in n:
		if models.magic_ok(i):
			walkable += 1
			var result := _walk_report(pak, models, i, offset)
			var triples: Array[Dictionary] = result["triples"]
			var meta: Dictionary = result["meta"]
			var seen := {}   # tags already counted toward files= for this entry
			for t: Dictionary in triples:
				var tag: int = t["tag"]
				total[tag] = int(total.get(tag, 0)) + 1
				if not seen.has(tag):
					seen[tag] = true
					files[tag] = int(files.get(tag, 0)) + 1
			var stop_reason: String = meta.get("stop_reason", "")
			if stop_reason != "unknown-tag" and stop_reason != "budget":
				var kind := models.kind_of(i)
				if kind == Sacred.Models.KIND_MESH:
					walked_mesh += 1
				elif kind == Sacred.Models.KIND_MOTION:
					walked_motion += 1
		else:
			skipped += 1
			var off := models.magic_offset(i)
			var length := models.true_length(i)
			var reason: String
			if length < off + 4:
				reason = "the derived length is too small to reach the kind's magic offset"
			else:
				reason = "the bytes at the magic offset are not the magic value"
			skip_lines.append("skip\t%d\tname=%s\tkind=%d\treason=%s" % [
				i, models.entry_name(i), models.kind_of(i), reason])

	var corpus_line := "corpus\tentries=%d\twalkable=%d\tskipped=%d\twalked_mesh=%d\twalked_motion=%d" % [
		n, walkable, skipped, walked_mesh, walked_motion]
	if explicit_falsify:
		corpus_line += "\tfalsify=%d" % offset
	print(corpus_line)

	for line in skip_lines:
		print(line)

	print("legend\tdefinitional=true means this tag's files= count equals walkable= by construction (magic_ok IS \"root tag present at the kind-appropriate offset\") and carries no independent signal; only definitional=false tags are reached by advancing through declared chunk lengths and are the falsifiable part of the invariant")

	var documented: Array[int] = [Sacred.Models.MAGIC, 0xCA5E0101, 0xCA5E0102, 0xCA5E0103]
	var discovered: Array[int] = []
	for k in files.keys():
		discovered.append(int(k))
	discovered.sort()
	var ordered: Array[int] = []
	for tag in documented:
		if files.has(tag) or total.has(tag):
			ordered.append(tag)
	for tag in discovered:
		if not documented.has(tag):
			ordered.append(tag)

	var files_eq_4991 := 0
	var total_eq_4991 := 0
	for tag in ordered:
		var f: int = int(files.get(tag, 0))
		var t: int = int(total.get(tag, 0))
		if f == 4991:
			files_eq_4991 += 1
		if t == 4991:
			total_eq_4991 += 1
		print("tagcount\t0x%08x\tfiles=%d\ttotal=%d\tdefinitional=%s" % [
			tag, f, t, "true" if tag == Sacred.Models.MAGIC else "false"])

	var walkable_eq_4991 := walkable == 4991
	var verdict := "PASS" if (walkable_eq_4991 and skipped == 2) else "FAIL"
	print("invariant\twalkable_eq_4991=%s\tfiles_eq_4991_tags=%d\ttotal_eq_4991_tags=%d\tverdict=%s" % [
		"true" if walkable_eq_4991 else "false", files_eq_4991, total_eq_4991, verdict])


## {triples, meta} for entry idx at the given falsify offset. offset==0
## delegates to Models.walk() itself (the trusted single implementation), so
## a clean --corpus sweep and a --falsify=0 sweep read from the exact same
## code path and cannot diverge. A non-zero offset reimplements the same
## per-tag dispatch here, in this file only (Models.walk() in sacred.gd is
## untouched by this plan), injecting the desync into the per-chunk advance.
func _walk_report(pak: Sacred.Pak, models: Sacred.Models, idx: int, offset: int) -> Dictionary:
	if offset == 0:
		var triples := models.walk(idx)
		return {"triples": triples, "meta": models.last_walk_meta}
	return _walk_offset(pak, models, idx, offset)


## Reimplementation of Sacred.Models.walk()'s per-tag dispatch with every
## per-chunk advance (`pos += size`) offset by `offset` extra bytes, so the
## second tag read lands `offset` bytes into the first chunk's payload
## instead of at the true next tag -- exactly the desync an off-by-N bug in
## the real walker would produce. Only used for offset != 0; see
## _walk_report(). Bounds-checked identically to Models.walk(): every
## decode_u32 is guarded by a buffer-size check first.
func _walk_offset(pak: Sacred.Pak, models: Sacred.Models, entry: int, offset: int) -> Dictionary:
	var triples: Array[Dictionary] = []
	var object_lengths: Array[int] = []
	var meta := {
		"h1_confirmed": false, "objects": 0, "h1_bytes": 0,
		"object_lengths": object_lengths, "consumed": 0,
		"stop_reason": "", "stop_tag": 0, "stop_off": 0,
	}
	if not models.magic_ok(entry):
		return {"triples": triples, "meta": meta}
	var length := models.true_length(entry)
	var buf := pak.read_at(pak.entry_offset(entry), length)
	var pos := models.magic_offset(entry)
	meta["consumed"] = pos
	var objects := 0
	var h1_total := 0
	var confirmed := true
	while pos + 4 <= buf.size() and buf.decode_u32(pos) == Sacred.Models.MAGIC:
		var root_off := pos
		var h1_len := 0
		if root_off + Sacred.Models.H1_LEN_OFF + 4 <= buf.size():
			h1_len = buf.decode_u32(root_off + Sacred.Models.H1_LEN_OFF)
		var terminated := false
		while pos + 4 <= buf.size():
			if triples.size() >= Sacred.Models.WALK_BUDGET:
				meta["stop_reason"] = "budget"
				confirmed = false
				break
			var tag := buf.decode_u32(pos)
			if tag == Sacred.Models.TERMINATOR:
				terminated = true
				break
			if not Sacred.Models.TAG_SIZES.has(tag):
				meta["stop_reason"] = "unknown-tag"
				meta["stop_tag"] = tag
				meta["stop_off"] = pos
				confirmed = false
				break
			var size: int = Sacred.Models.TAG_SIZES[tag]
			if pos + size > buf.size():
				meta["stop_reason"] = "truncated"
				confirmed = false
				break
			triples.append({"tag": tag, "off": pos, "len": size})
			pos += size + offset   # the injected desync -- every chunk advance offset by N bytes
		if not terminated:
			meta["consumed"] = pos
			break
		objects += 1
		h1_total += h1_len
		object_lengths.append(h1_len)
		var predicted := root_off + h1_len
		if predicted == length:
			meta["consumed"] = predicted
			meta["stop_reason"] = "end-of-entry"
			break
		if predicted + 4 <= buf.size() and buf.decode_u32(predicted) == Sacred.Models.MAGIC:
			pos = predicted
			meta["consumed"] = predicted
			continue
		confirmed = false
		meta["stop_reason"] = "h1-mismatch"
		meta["stop_off"] = predicted
		meta["consumed"] = pos
		break
	meta["h1_confirmed"] = confirmed and objects > 0
	meta["objects"] = objects
	meta["h1_bytes"] = h1_total
	return {"triples": triples, "meta": meta}


## MD5 of the UTF-8 text formed by joining, in emission order:
##   1. one line per triple, "decimal-tag,decimal-entry-relative-offset,decimal-length\n"
##   2. one line per top-level object, "obj,decimal-ordinal,decimal-h1-declared-length\n"
## both blocks terminated by a newline per line, block 2 appended after every
## triple line.
##
## [Corrected during 03-01 Task 2 execution, TSV row 383] Block 1 alone was
## Task 1's original spec, and it does not discriminate between entries: the
## header-plus-early-leaf-tag prefix this phase's samples terminate on is
## structurally identical (same tag ids, offsets, declared sizes) across
## every kind=64 mesh checked, so triples-only hashed to the same md5 for
## GLADIATOR.GRN, BAT.GRN and GLAD_SA5_SHOULDER.GRN despite their true
## lengths differing by 5x. Block 2 fixes this without decoding payload
## content -- object_lengths is Sacred.Models.walk()'s own H1-declared
## per-object byte length, a fact the tag walk already establishes, not a
## geometry field. Defined here, precisely, so Plan 03's independent Python
## walker can reproduce it from this comment alone -- never by translating
## this function's body.
func _triples_md5(triples: Array[Dictionary], object_lengths: Array) -> String:
	var text := ""
	for t: Dictionary in triples:
		text += "%d,%d,%d\n" % [t["tag"], t["off"], t["len"]]
	for j in object_lengths.size():
		text += "obj,%d,%d\n" % [j, int(object_lengths[j])]
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	if not text.is_empty():
		ctx.update(text.to_utf8_buffer())  # HashingContext.update() errors on a zero-length buffer
	return ctx.finish().hex_encode()
