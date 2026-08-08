extends SceneTree
## Tag-walk dumper for one Granny .GRN entry in pak/models.pak.
##
##   godot --headless --path godot-port --script res://grnwalk.gd -- --grn-index=589
##   godot --headless --path godot-port --script res://grnwalk.gd -- --census=589
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
	for a in argv:
		if a.begins_with("--grn-index="):
			grn_index = int(a.trim_prefix("--grn-index="))
		elif a.begins_with("--census="):
			census_index = int(a.trim_prefix("--census="))

	if grn_index < 0 and census_index < 0:
		printerr("usage: grnwalk.gd -- --grn-index=N | --census=N")
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
	quit(0)


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
