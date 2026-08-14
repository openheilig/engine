extends "res://checks/check.gd"
## Parity check for Sacred.Pax against the eight-hero corpus in
## unpack-tools/Chars (TSV rows 525/530/531).
##
##   SACRED_CHARS=/path/to/Chars \
##     godot --headless --path godot-port --script res://checks/pax_check.gd
##
## Every section must inflate to exactly its declared size -- Sacred.Pax
## already push_error()s when it does not, so a silent run with matching
## totals is the pass condition.

## The corpus is NOT part of the retail install and is not shipped here.
## ponytail: env var, no CLI flag. These are probes, not a product.
var DIR := OS.get_environment("SACRED_CHARS")


func _init() -> void:
	super()
	if DIR == "":
		push_error("pax_check: set SACRED_CHARS to the directory holding Hero00.pax")
		quit(1)
		return
	print("file\tsections\ttypes\ttotal_decoded")
	for i in 8:
		var path := "%s/Hero%02d.pax" % [DIR, i]
		var pax := Sacred.Pax.new(path)
		if not pax.is_open():
			printerr("could not open ", path)
			continue
		var total := 0
		var names := PackedStringArray()
		for t in pax.types:
			var b := pax.section(t)
			total += b.size()
			names.append("%X:%d" % [t, b.size()])
		print("Hero%02d\t%d\t%s\t%d" % [i, pax.count(), " ".join(names), total])
	finish()
