extends RefCounted
## bin/TYPE_NPC_*/startcode.bin -- the per-class WORLD BOOTSTRAP script: every
## fixed NPC and object the world starts with, and where it stands.
##
## Framing is the same as funkcode.bin (autoresearch row 711, confirmed against
## the interpreter's own `movsx eax, WORD PTR [ebx+0x2]` at 0x0826af24): u16
## opcode, u16 length counting those four bytes, then a tagged argument list.
##
## THREE OPCODES ARE READ HERE, and the rest are skipped by their length field:
##   23  declares a NAMED POSITION: tag 0x01 label, then two tag 0x0b ints.
##    1  CreateNPC (the handler names itself in its own debug strings).
##    8  CreateOBJ.
##
## WHAT AN op1 RECORD SAYS, and how each field was pinned (rows 831-833, 835):
##
##   tag 0x02, occurrence 0  the BODY, as an items.pak RECORD INDEX whose name
##       field is a Granny model. 51,373 of 51,373 records over all 16 files
##       carry one; 331 of 331 distinct ids resolve to a .grn. This is the same
##       id space creature.pak indexes -- see checks/creature_check.gd, which
##       reached "a creature's id IS an items.pak record index" independently.
##   tag 0x02, occurrences 1 and 2  MAIN HAND and OFF HAND, same id space.
##   tag 0x04  the POSITION. A VARIANT: either three i32 (cell_x, cell_y, layer)
##       or, behind the 0xfffffffe sentinel, the NAME of an opcode-23 position.
##       Never both -- that is what the variant is for.
##   tag 0x01  a `res:N` global.res slot: the NPC's display name.
##   tags 0x09/0x05/0x60/0x67  quest hook, quest state, on-sight script, combat
##       art. Read as raw strings here; nothing consumes them yet.
##
## THE CONTROL ARM THAT PROVES THE BODY SLOT, because a rate on its own proved
## nothing and the first attempt at this got it wrong: within the SAME records,
## the items.pak join scores 100.0% on tag 0x02 and 0.0% on tags 0x04, 0x20 and
## 0x15. Slot, not vocabulary. The earlier "100% versus an 8.7% random-id
## baseline" was invalid -- operand 0 of an unrelated opcode scores 63.2% on
## that instrument (row 833). And the body/main-hand name sets intersect in
## ZERO names, which no positional or chance join produces.
##
## ponytail: startcode only, not funkcode. Placement in startcode.bin is closed
## -- 18,586 of 18,586 records across the eight classes resolve to a world cell
## (row 832). funkcode.bin's op1/op8 records are script-driven spawns whose
## geography comes from EXECUTION, which nothing here emulates; Sacred.Funk's
## header says the same thing about its spawn tables. Upgrade path is an
## interpreter, not a wider reader.

const STR := -1        ## payload is a NUL-terminated string
const VARIANT := -2    ## u32 sentinel 0xfffffffe -> string, else a fixed payload

const OP_NPC := 1
const OP_OBJ := 8
const OP_PLACE := 23

const SENTINEL := 0xfffffffe
const NO_CELL := Vector2i(-1, -1)

## Payload width per tag, for the tags opcodes 1, 8 and 23 ACTUALLY USE -- a
## census over all 16 files, not the full 162-entry interpreter table. A tag
## outside this set inside one of those three records is a parse error and not
## a shrug, which is the same refusal Sacred.Funk makes: an unlisted tag shifts
## the cursor, and a shifted cursor turns model ids into plausible nonsense.
##
## Zero-width entries are real. 66 tags fall through to the interpreter's
## default handler at 0x0826e0bc (`inc [esi]; jmp epilogue`), so they are
## MARKERS carrying no payload; omitting them was what made an earlier
## engine-derived table score worse than a fitted one (row 720).
const WIDTH := {
	0x01: STR, 0x02: 4, 0x03: 2, 0x04: VARIANT, 0x05: STR, 0x07: 0, 0x08: 0,
	0x09: STR, 0x0a: 2, 0x0b: 4, 0x0c: VARIANT, 0x0e: 0, 0x11: 4, 0x12: 0,
	0x13: 0, 0x14: 0, 0x15: 8, 0x1a: 0, 0x1b: 0, 0x1f: 3, 0x20: 12, 0x23: 0,
	0x24: 0, 0x25: 0, 0x29: STR, 0x2b: 0, 0x2e: 0, 0x2f: 0, 0x30: 0, 0x31: 0,
	0x32: 0, 0x36: 4, 0x3c: VARIANT, 0x3f: 0, 0x41: STR, 0x42: 0, 0x43: 0,
	0x44: 0, 0x45: 0, 0x46: 0, 0x4b: VARIANT, 0x4c: 0, 0x54: 4, 0x60: STR,
	0x61: 0, 0x62: 0, 0x64: 0, 0x67: STR, 0x6b: 2, 0x72: 0, 0x73: 4, 0x74: 0,
	0x79: 8, 0x7e: 4, 0x83: STR, 0x85: 0, 0x8d: 0, 0x8e: 0, 0x90: 4, 0x9d: STR,
	0x9e: 0,
}

## The fixed payload each VARIANT tag takes when its u32 is NOT the sentinel.
const VARIANT_WIDTH := {0x04: 12, 0x0c: 12, 0x3c: 12, 0x4b: 1}

## An END tag stops the record; 0x00 is the only one these three opcodes hit.
const END_TAGS := {0x00: true, 0x17: true, 0x18: true, 0x21: true, 0x22: true}

## Label -> world cell, from opcode 23. Every one of these also exists in the
## same directory's DefPos.bin with byte-identical coordinates (11,454 labels
## across the eight classes, zero disagreements, row 832), so startcode.bin is
## self-contained and DefPos is not needed to resolve a position.
var places: Dictionary[String, Vector2i] = {}

## One per opcode-1 record: {body:int, main:int, off:int, cell:Vector2i,
## layer:int, place:String, name:String}. `cell` is already resolved -- a named
## position is looked up in `places` -- and is NO_CELL only if the name is not
## declared in this file.
var npcs: Array[Dictionary] = []

## One per opcode-8 record: {model:int, cell:Vector2i, layer:int, place:String,
## trigger:String, kind:String}. `model` is an items.pak index like an NPC's,
## but the two populations are DISJOINT: op1 uses 331 ids in 1..6114, op8 uses
## 363 in 768..7919, and they share no id (row 833). In startcode.bin 99.35% of
## them name a .grn prop -- chests, barrels, doors. The FX handles that make up
## most of funkcode's op8 records are not here.
var objects: Array[Dictionary] = []

var _unresolved := 0


## `dir` is one bin/TYPE_NPC_* directory.
func _init(dir: String) -> void:
	var b := FileAccess.get_file_as_bytes(dir.path_join("startcode.bin"))
	if b.is_empty():
		push_error("Startcode: cannot read startcode.bin in %s" % dir)
		return
	# Two passes: an opcode-1 record may name a position declared later in the
	# file, so every label has to exist before any of them is resolved.
	var pending: Array[Dictionary] = []
	var off := 0
	while off + 4 <= b.size():
		var opcode := b.decode_u16(off)
		var length := b.decode_u16(off + 2)
		if length < 4 or off + length > b.size():
			push_error("Startcode: bad record length %d at %d" % [length, off])
			return
		if opcode == OP_PLACE or opcode == OP_NPC or opcode == OP_OBJ:
			var args := _read_args(b, off + 4, off + length)
			if args.is_empty():
				return          # _read_args already reported why
			match opcode:
				OP_PLACE: _read_place(args)
				_: pending.append({"op": opcode, "args": args})
		off += length
	for rec in pending:
		if rec["op"] == OP_NPC:
			npcs.append(_read_npc(rec["args"]))
		else:
			objects.append(_read_obj(rec["args"]))


## Number of created NPCs and objects whose named position is not declared in
## this file. Kept as a counter rather than a push_error: it is 0 today for all
## eight classes, and a check asserting 0 is a better alarm than a log line.
func unresolved() -> int:
	return _unresolved


## Walks one record's tagged argument list into [[tag, value], ...]. Returns an
## empty array on an unknown tag, which the caller treats as fatal.
func _read_args(b: PackedByteArray, from: int, to: int) -> Array:
	var out: Array = []
	var p := from
	while p < to:
		var tag := b[p]
		p += 1
		if END_TAGS.has(tag):
			break
		if not WIDTH.has(tag):
			push_error("Startcode: unknown tag 0x%02x at %d" % [tag, p - 1])
			return []
		var w: int = WIDTH[tag]
		if w == STR:
			var e := _end_of_string(b, p, to)
			if e < 0:
				push_error("Startcode: unterminated string at %d" % p)
				return []
			out.append([tag, b.slice(p, e).get_string_from_ascii()])
			p = e + 1
		elif w == VARIANT:
			if p + 4 <= to and b.decode_u32(p) == SENTINEL:
				p += 4
				var e2 := _end_of_string(b, p, to)
				if e2 < 0:
					push_error("Startcode: unterminated variant string at %d" % p)
					return []
				out.append([tag, b.slice(p, e2).get_string_from_ascii()])
				p = e2 + 1
			else:
				var fw: int = VARIANT_WIDTH[tag]
				if p + fw > to:
					break       # payload overruns the record: the engine reads on
				out.append([tag, b.slice(p, p + fw)])
				p += fw
		else:
			if p + w > to:
				break
			out.append([tag, b.slice(p, p + w)])
			p += w
	return out


func _end_of_string(b: PackedByteArray, from: int, to: int) -> int:
	for i in range(from, to):
		if b[i] == 0:
			return i
	return -1


func _read_place(args: Array) -> void:
	var label := ""
	var xy: Array[int] = []
	for a in args:
		if a[0] == 0x01 and label == "":
			label = a[1]
		elif a[0] == 0x0b:
			xy.append((a[1] as PackedByteArray).decode_s32(0))
	# A handful of opcode-23 records carry a label and no coordinates (2 per
	# class). They are skipped rather than stored at (0,0), which would be a
	# position in the world and would resolve silently.
	if label != "" and xy.size() >= 2:
		places[label] = Vector2i(xy[0], xy[1])


func _read_npc(args: Array) -> Dictionary:
	var ids := _ids(args)
	var pos := _position(args)
	return {
		"body": ids[0] if ids.size() > 0 else 0,
		"main": ids[1] if ids.size() > 1 else 0,
		"off": ids[2] if ids.size() > 2 else 0,
		"cell": pos[0],
		"layer": pos[1],
		"place": pos[2],
		"name": _first(args, 0x01),
	}


func _read_obj(args: Array) -> Dictionary:
	var ids := _ids(args)
	var pos := _position(args)
	return {
		"model": ids[0] if ids.size() > 0 else 0,
		"cell": pos[0],
		"layer": pos[1],
		"place": pos[2],
		"trigger": _first(args, 0x29),
		"kind": _first(args, 0x41),
	}


## Every tag-0x02 value in record order: body, then main hand, then off hand.
func _ids(args: Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	for a in args:
		if a[0] == 0x02:
			out.append((a[1] as PackedByteArray).decode_u32(0))
	return out


## The tag-0x04 position, resolved. Returns [cell, layer, place_name].
##
## The three i32 are SIGNED: the "huge" decimal values every earlier dump
## showed were this struct printed as one integer, and 4294967073 is -223
## (row 835). Field 2 is a small 0..4 enum, NOT a third coordinate -- that
## much is solid; what it selects is not, so it is carried through unnamed.
func _position(args: Array) -> Array:
	for a in args:
		if a[0] != 0x04:
			continue
		if a[1] is String:
			var label: String = a[1]
			if places.has(label):
				return [places[label], 0, label]
			_unresolved += 1
			return [NO_CELL, 0, label]
		var raw: PackedByteArray = a[1]
		return [Vector2i(raw.decode_s32(0), raw.decode_s32(4)), raw.decode_s32(8), ""]
	return [NO_CELL, 0, ""]


func _first(args: Array, tag: int) -> String:
	for a in args:
		if a[0] == tag and a[1] is String:
			return a[1]
	return ""
