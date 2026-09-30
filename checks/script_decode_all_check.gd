extends "res://checks/check.gd"
## script_decode_all_check.gd -- the widened ScriptVM decoder must consume
## the WHOLE Seraphim funkcode.bin record by record, exactly, with zero
## refusals: 125055 records / 102 distinct opcodes, matching the Python
## reference decode (analysis/tools/formats/startcode.py, finding 1293).
##
## THE METRIC IS CONSUMPTION, not a rate: the cursor must land exactly on
## EOF. A parse percentage would be the hollow metric again -- garbage
## absorbs silently through zero-width markers unless the LENGTHS are right,
## and only exact consumption proves them.
##
## Bug-compatibility notes the decoder implements (each found by a real
## record this file's history refused or mis-read):
##   * unlisted sub-0xa2 tags are zero-width markers; 0xa2+ ends the record
##   * VARIANT: sentinel-string vs fixed payload; a shorter tail than the
##     selector falls through to the fixed read; an overrunning fixed
##     payload is a silent break (engine reads on)
##   * NUMSTR: u32 + string (+ conditional second string behind the
##     negative-u32 gate, never on 0x7a); ANY truncation here is a silent
##     break, never a record failure
##   * only the STR families treat a missing NUL as invalid (ok=false)

const TREE := "type_npc_seraphim"
const WANT_RECORDS := 125055
const WANT_OPS := 102


func _init() -> void:
	super()
	var install := Sacred.find_install()
	assert(not install.is_empty(), "retail install is required")
	var code := FileAccess.get_file_as_bytes(
		install.path_join("bin").path_join(TREE).path_join("funkcode.bin"))
	assert(code.size() > 0, "funkcode.bin must exist")
	var vm := ScriptVM.new()
	var p := 0
	var total := 0
	var bad := 0
	var ops := {}
	while p + 4 <= code.size():
		var l := code.decode_u16(p + 2)
		if l < 4 or p + l > code.size():
			bad += 1
			printerr("record at %d declares length %d" % [p, l])
			break
		var args: Variant = vm._args(code, p + 4, p + l)
		if args == null:
			bad += 1
			printerr("decode refused the record at %d (op %d)" % [p, code.decode_u16(p)])
			break
		var op := code.decode_u16(p)
		ops[op] = int(ops.get(op, 0)) + 1
		total += 1
		p += l
	expect(p == code.size(), "the cursor must consume the file exactly (stopped at %d of %d)" % [p, code.size()])
	expect(bad == 0, "no record may be refused")
	expect(total == WANT_RECORDS, "record count must be %d, got %d" % [WANT_RECORDS, total])
	expect(ops.size() == WANT_OPS, "distinct opcode count must be %d, got %d" % [WANT_OPS, ops.size()])
	print("script_decode_all_check\tOK\trecords=%d\tops=%d" % [total, ops.size()])
	finish(0)
