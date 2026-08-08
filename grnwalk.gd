extends SceneTree
## Tag-walk dumper for one Granny .GRN entry in pak/models.pak.
##
##   godot --headless --path godot-port --script res://grnwalk.gd -- --grn-index=589
##
## Prints, tab-separated:
##   grn    <index>  name=...  kind=...  true_len=...  magic_off=...  magic_ok=...
##   tag    <index>  <ordinal>  <entry-relative offset, decimal>  <tag, 0x%08x>  <length, decimal>
##   grnend <index>  tags=<count>  consumed=<entry-relative bytes>  md5=<hex>
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
	for a in argv:
		if a.begins_with("--grn-index="):
			grn_index = int(a.trim_prefix("--grn-index="))

	if grn_index < 0:
		printerr("usage: grnwalk.gd -- --grn-index=N")
		quit(1)
		return

	var pak := Sacred.Pak.new(install.path_join("pak/models.pak"))
	if not pak.is_open():
		quit(1)
		return

	_dump(Sacred.Models.new(pak), grn_index)
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

	var consumed := magic_off
	if not triples.is_empty():
		var last: Dictionary = triples[-1]
		consumed = int(last["off"]) + int(last["len"])
	print("grnend\t%d\ttags=%d\tconsumed=%d\tmd5=%s" % [
		idx, triples.size(), consumed, _triples_md5(triples)])


## MD5 of the UTF-8 text formed by joining, in emission order, one line per
## triple of the form "decimal-tag,decimal-entry-relative-offset,decimal-length"
## separated by commas and terminated by a newline. Defined here, precisely,
## so Plan 03's independent Python walker can reproduce it from this comment
## alone -- never by translating this function's body.
func _triples_md5(triples: Array[Dictionary]) -> String:
	var text := ""
	for t: Dictionary in triples:
		text += "%d,%d,%d\n" % [t["tag"], t["off"], t["len"]]
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	if not text.is_empty():
		ctx.update(text.to_utf8_buffer())  # HashingContext.update() errors on a zero-length buffer
	return ctx.finish().hex_encode()
