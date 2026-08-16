class_name ScriptVM
extends RefCounted
## The funkcode.bin bytecode interpreter, for the opcodes it can honestly
## execute and no others.
##
## Framing is the same everywhere in this format: `u16 opcode; u16 length`
## counting those four bytes, then a tagged argument list (row 711, confirmed
## against the interpreter's own `movsx eax, WORD PTR [ebx+0x2]`). Opcode NAMES
## come from retail's own script-compiler keyword tables, 120 of 141 (row 938).
##
## WHY THIS REFUSES INSTEAD OF SKIPPING. Retail's dispatcher default case is
## `mov ecx,1; ret`, so an opcode with no handler is silently skipped by its
## length field -- and it is tempting to copy that and call an unimplemented
## opcode a no-op. THAT IS WRONG HERE, and the reason is `IF`. Retail skipping
## an opcode it never implemented leaves behaviour it never had; this class
## skipping `IF` (opcode 58, 3.3% of quest records) would run a guarded body
## UNCONDITIONALLY, which is not "less behaviour" but different behaviour. So
## run() refuses a hook containing any opcode outside IMPLEMENTED, and a caller
## finds out before anything executes rather than halfway through.
##
## Nothing here touches the scene tree, a node, or a thread (R10.1): a hook is
## bytes in, effects on a HOST object out.

## Tag -> payload width, for the tags the implemented opcodes use. Same shape
## as Sacred.Startcode.WIDTH and the same refusal: an unlisted tag inside a
## record is a parse error, because a shifted cursor turns a quest id into
## plausible nonsense.
const STR := -1
const WIDTH := {
	0x01: STR,      ## NUL-terminated string
	0x0b: 4,        ## i32
	0x1d: 4,        ## i32, AutoSave's argument
	0x36: 4,        ## i32
}
const END_TAGS := {0x00: true}

const OP_QUEST_BOOK := 53       ## QuestBook(quest_id, kind, res_key)
const OP_SET_VAR_BIT := 68      ## SetVarBit(name, value)
const OP_SET_QUEST_INFO := 87   ## SetQuestInfo(value)
const OP_AUTOSAVE := 121        ## AutoSave(value)

## The opcodes run() will execute. Deliberately small: every one of these was
## read from a real quest's disassembly and its argument shape checked against
## the bytes, rather than assumed from the name.
const IMPLEMENTED := {
	OP_QUEST_BOOK: "QuestBook",
	OP_SET_VAR_BIT: "SetVarBit",
	OP_SET_QUEST_INFO: "SetQuestInfo",
	OP_AUTOSAVE: "AutoSave",
}

## QuestBook's second argument. Measured on quests 65 and 74: the log TITLE
## line carries 0 and every other line carries 1. Named rather than passed
## through as a bare int so a caller reading the log knows which line is the
## heading.
const BOOK_TITLE := 0

var executed := 0               ## records run across every run() call
var refused_op := -1            ## the opcode that caused the last refusal


## Runs one hook. `host` receives the effects and must implement
## quest_book(), set_var(), quest_info() and autosave(). Returns false without
## executing anything when the span is unreadable or names an opcode this
## class does not implement -- `refused_op` says which.
func run(code: PackedByteArray, offset: int, length: int, host: Object) -> bool:
	refused_op = -1
	var recs := decode(code, offset, length)
	if recs.is_empty():
		return length == 0        # an empty hook runs vacuously, and every
		                          # Trigger in the corpus is exactly that
	for r: Dictionary in recs:
		if not IMPLEMENTED.has(r["op"]):
			refused_op = r["op"]
			return false
	for r: Dictionary in recs:
		_apply(r, host)
		executed += 1
	return true


## Splits a span into records without executing anything: [{op, args}], where
## args is [[tag, value], ...]. Empty on a malformed span.
func decode(code: PackedByteArray, offset: int, length: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if offset < 0 or length < 0 or offset + length > code.size():
		push_error("ScriptVM: span %d+%d is outside a %d-byte file" % [offset, length, code.size()])
		return []
	var p := offset
	var end := offset + length
	while p + 4 <= end:
		var op := code.decode_u16(p)
		var l := code.decode_u16(p + 2)
		if l < 4 or p + l > end:
			push_error("ScriptVM: record at %d declares length %d" % [p, l])
			return []
		var args: Variant = _args(code, p + 4, p + l)
		if args == null:
			return []
		out.append({"op": op, "args": args})
		p += l
	return out


## One record's tagged argument list, or null on an unknown tag.
func _args(code: PackedByteArray, from: int, to: int) -> Variant:
	var out: Array = []
	var p := from
	while p < to:
		var tag := code[p]
		p += 1
		if END_TAGS.has(tag):
			break
		if not WIDTH.has(tag):
			push_error("ScriptVM: unknown argument tag 0x%02x at %d" % [tag, p - 1])
			return null
		var w: int = WIDTH[tag]
		if w == STR:
			var e := p
			while e < to and code[e] != 0:
				e += 1
			if e >= to:
				push_error("ScriptVM: unterminated string at %d" % p)
				return null
			out.append([tag, code.slice(p, e).get_string_from_ascii()])
			p = e + 1
		else:
			if p + w > to:
				break     # payload overruns the record; retail reads on
			out.append([tag, code.decode_s32(p)])
			p += w
	return out


func _apply(rec: Dictionary, host: Object) -> void:
	var a: Array = rec["args"]
	match int(rec["op"]):
		OP_QUEST_BOOK:
			# (i32 quest id, i32 kind, string res key). The quest id is in the
			# record rather than implied by the hook, which is why it is passed
			# through instead of being assumed to be the running quest.
			if a.size() >= 3:
				host.quest_book(int(a[0][1]), int(a[1][1]), str(a[2][1]))
		OP_SET_VAR_BIT:
			# (string name, i32 value). Quest state lives here: OnEnter writes
			# 1 and OnExit writes 3, with the variable NAMED for the quest id.
			if a.size() >= 2:
				host.set_var(str(a[0][1]), int(a[1][1]))
		OP_SET_QUEST_INFO:
			if a.size() >= 1:
				host.quest_info(int(a[0][1]))
		OP_AUTOSAVE:
			host.autosave(int(a[0][1]) if a.size() >= 1 else 0)


## Every opcode a span uses, for a caller deciding whether it can run the hook
## before committing to it.
func opcodes(code: PackedByteArray, offset: int, length: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for r: Dictionary in decode(code, offset, length):
		out.append(int(r["op"]))
	return out


## True when every opcode in the span is implemented.
func can_run(code: PackedByteArray, offset: int, length: int) -> bool:
	if length == 0:
		return true
	var ops := opcodes(code, offset, length)
	if ops.is_empty():
		return false
	for op in ops:
		if not IMPLEMENTED.has(op):
			return false
	return true
