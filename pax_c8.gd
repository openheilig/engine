extends SceneTree
## Do the 0xC8 record type ids live in the items.pak id space? (TSV row 533)
## Control arm: the same lookup over 70 RANDOM ids in the same numeric range.
## Without it a hit rate means nothing.
## The eight-hero .pax corpus. NOT part of the retail install and not shipped
## here -- point SACRED_CHARS at your own copy.
## ponytail: env var, no CLI flag. These are probes, not a product.
var DIR := OS.get_environment("SACRED_CHARS")

func _init() -> void:
	if DIR == "":
		push_error("pax_c8: set SACRED_CHARS to the directory holding Hero00.pax")
		quit(1)
		return
	var install := Sacred.find_install()
	var items := Sacred.Items.new(Sacred.Pak.new(install.path_join("pak/items.pak")))
	var pax := Sacred.Pax.new("%s/Hero00.pax" % DIR)
	var b := pax.section(0xC8)
	var ids: Dictionary[int, int] = {}
	var o := 4
	while o + 8 <= b.size():
		if b.decode_u32(o + 4) != 0xFEEDF00D:
			break
		var t := b.decode_u32(o)
		ids[t] = ids.get(t, 0) + 1
		# walk to the next FEEDF00D rather than assuming 398
		var nxt := o + 12
		while nxt + 4 <= b.size() and b.decode_u32(nxt) != 0xFEEDF00D:
			nxt += 1
		o = nxt - 4
		if nxt + 4 > b.size():
			break
	var hit := 0
	var lo := 1 << 30
	var hi := 0
	for t in ids:
		lo = mini(lo, t)
		hi = maxi(hi, t)
		var nm := items.name_of(t)
		if nm != "":
			hit += 1
	print("distinct ids=%d range=%d..%d  named=%d (%.0f%%)" % [ids.size(), lo, hi, hit, 100.0 * hit / ids.size()])
	var ctrl := 0
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	for i in ids.size():
		if items.name_of(rng.randi_range(lo, hi)) != "":
			ctrl += 1
	print("CONTROL random ids in same range: named=%d (%.0f%%)" % [ctrl, 100.0 * ctrl / ids.size()])
	var shown := 0
	for t in ids:
		if shown >= 12:
			break
		print("  %d\tx%d\t%s" % [t, ids[t], items.name_of(t)])
		shown += 1
	quit()
