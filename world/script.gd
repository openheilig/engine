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
## Unsupported EXECUTED records are refused before applying the hook. Native
## IF/ELSEIF/ELSE traversal selects the reachable records first; an unsupported
## record inside a skipped branch is not an executed effect. Conditions are
## evaluated against a shadow of the named variables, including earlier writes.
##
## Nothing here touches the scene tree, a node, or a thread (R10.1): a hook is
## bytes in, effects on a HOST object out.

## Tag -> payload width, for the tags the implemented opcodes use. Same shape
## as Sacred.Startcode.WIDTH and the same refusal: an unlisted tag inside a
## record is a parse error, because a shifted cursor turns a quest id into
## plausible nonsense.
const STR := -1
## A VARIANT tag reads a u32 FIRST and decides its own shape from it: SENTINEL
## means a NUL-terminated string follows, anything else means that u32 was the
## first of three i32. Both forms occur on tag 0x04 inside ONE hook -- quest 1's
## CreateNPC names its NPC with the string form, and the NPC_Goto two records
## later gives that NPC a cell with the triple -- so a reader that picks one
## shape and keeps it decodes half the hook as plausible nonsense.
## Transcribed from analysis/tools/formats/startcode.py, which is the authority
## on this table; not re-derived here.
const VARIANT := -3
const STR2 := -4
const NUMSTR := -5
const END := -2
const SENTINEL := 0xfffffffe
## Payload width of a VARIANT tag when its u32 is NOT the sentinel.
##
## THE FULL ENGINE-DERIVED TAG TABLE (finding 1293): widths recovered by
## FOLLOWING CONTROL FLOW from the interpreter jump-table handlers at
## 0x086f3fbc to the shared epilogue -- derived from the interpreter, not
## fitted to the data. The decoder previously carried only the ten tags the
## eight implemented opcodes use, so it REFUSED real hooks containing any of
## the other ~140 (0x52/0x1f/0x0a hit on the first non-tutorial quests).
## Unlisted tags below 0xa2 are ZERO-WIDTH markers (the default handler is
## `inc [esi]; jmp epilogue`); 0xa2+ fails retail's bounds check and ends
## the record.
const VARIANT_FIXED := {0x04: 12, 0x0c: 12, 0x0d: 12, 0x3c: 12, 0x37: 1, 0x4b: 1, 0x71: 0}
const WIDTH := {
	0x00: END, 0x01: STR, 0x02: 4, 0x03: 2, 0x04: VARIANT, 0x05: STR,
	0x09: STR, 0x0a: 2, 0x0b: 4, 0x0c: VARIANT, 0x0d: VARIANT, 0x11: 4,
	0x15: 8, 0x16: STR, 0x17: END, 0x18: END, 0x19: 12, 0x1c: 4, 0x1d: 4,
	0x1e: STR, 0x1f: 3, 0x20: 12, 0x21: END, 0x22: END, 0x28: 1, 0x29: STR,
	0x2a: 12, 0x33: 8, 0x34: 8, 0x35: 12, 0x36: 4, 0x37: VARIANT, 0x38: 4,
	0x3a: STR2, 0x3b: 4, 0x3c: VARIANT, 0x3d: 16, 0x3e: STR, 0x40: STR,
	0x41: STR, 0x47: STR, 0x48: NUMSTR, 0x49: NUMSTR, 0x4a: NUMSTR,
	0x4b: VARIANT, 0x4d: 12, 0x52: STR, 0x53: 4, 0x54: 4, 0x55: 4, 0x56: 4,
	0x57: 4, 0x5d: NUMSTR, 0x5e: NUMSTR, 0x5f: 4, 0x60: STR, 0x63: STR,
	0x67: STR, 0x68: STR, 0x69: STR, 0x6a: STR, 0x6b: 2, 0x6c: 2,
	0x6d: NUMSTR, 0x6e: NUMSTR, 0x6f: STR, 0x71: VARIANT, 0x73: 4, 0x75: 4,
	0x76: END, 0x77: STR, 0x79: 8, 0x7a: NUMSTR, 0x7d: STR, 0x7e: 4,
	0x7f: 4, 0x81: STR, 0x82: STR, 0x83: STR, 0x84: 4, 0x86: 4, 0x87: 8,
	0x88: 8, 0x89: 8, 0x8b: 1, 0x8c: 4, 0x8f: STR, 0x90: 4, 0x92: STR,
	0x93: 2, 0x94: END, 0x95: STR, 0x9b: 2, 0x9c: 2, 0x9d: STR, 0x9f: 3,
}
const END_TAGS := {0x00: true}

const OP_CREATE_NPC := 1        ## CreateNPC(handle, creature, name, task, ?, art)
const OP_SET_NPC_STATE := 3
const OP_QUEST_COMPASS := 64    ## QuestKompassObj(handle)
const OP_SET_VAR := 67          ## SetVar(name, value)
const OP_NPC_GOTO := 72         ## NPC_Goto(handle, cell)
const OP_QUEST_BOOK := 53       ## QuestBook(quest_id, kind, res_key)
const OP_SET_VAR_BIT := 68      ## SetVarBit(name, value)
const OP_SET_QUEST_INFO := 87   ## SetQuestInfo(value)
const OP_AUTOSAVE := 121        ## AutoSave(value)
const OP_TEXT := 26
const OP_IF := 58
const OP_ELSE := 59
const OP_BUTTON := 60
const OP_NOP := 62
const OP_ELSEIF := 66
const OP_START_QUEST := 20
const OP_END_QUEST := 15
const OP_GOLD := 18
const OP_DELETE_NPC := 55
const OP_COMPASS_POS := 63
const OP_DIALOG_STATE := 86
const OP_SOUND := 104
const OP_DIALOG_DEF := 40

## The opcodes run() will execute. Deliberately small: every one of these was
## read from a real quest's disassembly and its argument shape checked against
## the bytes, rather than assumed from the name. The five added on 2026-08-25
## are exactly what quest 1's OnEnter needs and not one opcode more -- quest 9
## sits next to it using Teleport, SetIcon, SetAnimMode and PlaySound, and is
## still refused, which is what checks/quest_check.gd's refusal arm asserts.
const IMPLEMENTED := {
	OP_CREATE_NPC: "CreateNPC",
	OP_QUEST_COMPASS: "QuestKompassObj",
	OP_SET_VAR: "SetVar",
	OP_NPC_GOTO: "NPC_Goto",
	OP_QUEST_BOOK: "QuestBook",
	OP_SET_VAR_BIT: "SetVarBit",
	OP_SET_QUEST_INFO: "SetQuestInfo",
	OP_AUTOSAVE: "AutoSave",
	OP_SET_NPC_STATE: "NPCstate",
	OP_TEXT: "Text",
	OP_IF: "IF",
	OP_ELSE: "ELSE",
	OP_ELSEIF: "ELSEIF",
	OP_BUTTON: "SetButton",
	OP_NOP: "NOP",
	OP_START_QUEST: "StartQuest",
	OP_END_QUEST: "EndQuest",
	OP_GOLD: "GiveGold",
	OP_DELETE_NPC: "DelNPC",
	OP_COMPASS_POS: "QuestKompassPos",
	OP_DIALOG_STATE: "SetDialogState",
	OP_SOUND: "PlaySound",
	OP_DIALOG_DEF: "DialogDefinition",
}

## Opcode -> the host method it calls. Checked BEFORE anything executes, in the
## same pass as IMPLEMENTED, because the two failures are the same failure: a
## hook this VM cannot honestly run. Without it a plain QuestLog -- which
## answers only the first four -- would run half of quest 1 and then crash on
## CreateNPC, having already written the quest book. Refusing whole hooks is
## the invariant; this keeps it true when the HOST is the thing that is narrow.
const HOST_METHOD := {
	OP_QUEST_BOOK: "quest_book",
	OP_SET_VAR_BIT: "set_var",
	OP_SET_QUEST_INFO: "quest_info",
	OP_AUTOSAVE: "autosave",
	OP_SET_VAR: "set_script_var",
	OP_CREATE_NPC: "create_npc",
	OP_NPC_GOTO: "npc_goto",
	OP_QUEST_COMPASS: "quest_compass",
	OP_SET_NPC_STATE: "npc_state",
	OP_TEXT: "dialogue_text",
	OP_BUTTON: "dialogue_button",
	OP_START_QUEST: "start_quest",
	OP_END_QUEST: "end_quest",
	OP_GOLD: "give_gold",
	OP_DELETE_NPC: "delete_npc",
	OP_COMPASS_POS: "quest_compass_pos",
	OP_DIALOG_STATE: "dialogue_state",
	OP_SOUND: "play_sound",
	OP_DIALOG_DEF: "define_dialogue",
}

## QuestBook's second argument. Measured on quests 65 and 74: the log TITLE
## line carries 0 and every other line carries 1. Named rather than passed
## through as a bare int so a caller reading the log knows which line is the
## heading.
const BOOK_TITLE := 0

var executed := 0               ## records run across every run() call
var refused_op := -1            ## the opcode that caused the last refusal
## F1: the quest origin for position-less CreateNPC -- the caller sets it
## to the hero's cell before running quest hooks.
var quest_origin := Vector2i.ZERO


## Executes a preflighted reachable path. Sector-only skip_ops is unchanged;
## dialogue callers never pass it. Host validation includes nested quest hooks.
func run(code: PackedByteArray, offset: int, length: int, host: Object,
		skip_ops: PackedInt32Array = PackedInt32Array()) -> bool:
	refused_op = -1
	var recs := decode(code, offset, length)
	if recs.is_empty():
		return length == 0        # an empty hook runs vacuously, and every
		                          # Trigger in the corpus is exactly that
	var selected := reachable(recs, host.named_variables() if host.has_method("named_variables") else {})
	if not selected.get("ok", false):
		return false
	var path: Array = selected["records"]
	for r: Dictionary in path:
		var op := int(r["op"])
		if op == OP_NOP:
			continue
		if not IMPLEMENTED.has(op) or not HOST_METHOD.has(op) or not host.has_method(HOST_METHOD[op]):
			if not skip_ops.has(op):
				refused_op = op
				return false
		elif host.has_method("validate_script_record") and not host.validate_script_record(r):
			refused_op = op
			return false
	for r: Dictionary in path:
		if not _apply(r, host):
			refused_op = int(r["op"])
			return false
		executed += 1
	return true


## LGP sub_82A77C0: predicates are ANDed and stop on the first false.
## Unknown evaluated predicates return -1, never guessed true/false.
func condition(args: Array, variables: Dictionary) -> int:
	var i := 0
	while i < args.size():
		var tag := int(args[i][0])
		if tag == 0xa0:
			# IsNotMultiplayer, native !byte_94FE644. Engine single-player only.
			i += 1
			continue
		if tag not in [0x49, 0x4a, 0x6d, 0x6e] or i + 1 >= args.size():
			return -1
		var operand := int(args[i][1])
		var name := str(args[i + 1][1]).to_lower()
		if int(args[i + 1][0]) != tag:
			return -1
		if not variables.has(name):
			return 0
		var value := int(variables[name])
		var success := false
		match tag:
			0x49: success = ((value >> (operand & 31)) & 1) != 0
			0x4a: success = ((value >> (operand & 31)) & 1) == 0
			0x6d: success = value > operand
			0x6e: success = value < operand
		if not success:
			return 0
		i += 2
	return 1


## Native IF false scans to the first successful ELSEIF or ELSE; successful
## branch encountering ELSEIF skips through ELSE AND its next record.
## ELSE encountered normally skips precisely the next record. No invented
## nesting/end-if convention: retail's scanner is flat.
func reachable(recs: Array, variables: Dictionary) -> Dictionary:
	var shadow := variables.duplicate()
	var out: Array[Dictionary] = []
	var i := 0
	while i < recs.size():
		var r: Dictionary = recs[i]
		var op := int(r["op"])
		if op == OP_IF:
			var result := condition(r["args"], shadow)
			if result < 0:
				refused_op = op
				return {"ok": false, "error": "unsupported IF predicate"}
			if result == 0:
				i += 1
				while i < recs.size():
					var next_op := int(recs[i]["op"])
					if next_op == OP_ELSE:
						break
					if next_op == OP_ELSEIF:
						result = condition(recs[i]["args"], shadow)
						if result < 0:
							refused_op = next_op
							return {"ok": false, "error": "unsupported ELSEIF predicate"}
						if result == 1:
							break
					i += 1
				if i >= recs.size():
					refused_op = op
					return {"ok": false, "error": "IF has no branch terminator"}
		elif op == OP_ELSEIF:
			while i < recs.size() and int(recs[i]["op"]) != OP_ELSE:
				i += 1
			if i + 1 >= recs.size():
				refused_op = op
				return {"ok": false, "error": "ELSEIF has no ELSE/following record"}
			i += 1
		elif op == OP_ELSE:
			if i + 1 >= recs.size():
				refused_op = op
				return {"ok": false, "error": "ELSE has no following record"}
			i += 1
		else:
			out.append(r)
			var a: Array = r["args"]
			if op in [OP_SET_VAR, OP_SET_VAR_BIT] and a.size() == 2:
				var name := str(a[0][1]).to_lower()
				var value := int(a[1][1])
				shadow[name] = value if op == OP_SET_VAR else int(shadow.get(name, 0)) | (1 << value)
		i += 1
	return {"ok": true, "records": out}


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
		var args: Variant
		if op == OP_DIALOG_DEF:
			if l != 84:
				push_error("ScriptVM: dialogue definition is not 80 bytes")
				return []
			args = []
		else:
			args = _args(code, p + 4, p + l, op in [OP_IF, OP_ELSEIF])
		if args == null:
			return []
		var record := {"op": op, "args": args, "offset": p, "length": l}
		if op == OP_DIALOG_DEF:
			record["definition"] = code.slice(p + 4, p + l)
		out.append(record)
		p += l
	return out if p == end else []


## One record's tagged argument list, or null on an unknown tag.
func _args(code: PackedByteArray, from: int, to: int, keep_markers: bool = false) -> Variant:
	var out: Array = []
	var p := from
	while p < to:
		var tag := code[p]
		p += 1
		if END_TAGS.has(tag):
			break
		if not WIDTH.has(tag):
			if tag >= 0xa2:
				# Fails retail's bounds check: the record ends here, exactly
				# as the interpreter's own cursor does.
				break
			# Unlisted sub-0xa2 tag: the interpreter's default handler is
			# `inc [esi]; jmp epilogue` -- a ZERO-WIDTH marker. The old
			# narrow-table decoder refused here; refusing a marker is what
			# made real hooks undecodable (finding 1293).
			if keep_markers:
				out.append([tag, 0])
			continue
		var w: int = WIDTH[tag]
		if w == VARIANT:
			# The u32 decides the shape -- read it ONLY when four bytes
			# remain, exactly like the Python reference: a shorter tail is
			# not an error, it means the fixed payload is all there is.
			if p + 4 <= to and code.decode_u32(p) == SENTINEL:
				p += 4
				w = STR
			else:
				var fixed: int = VARIANT_FIXED.get(tag, 0)
				if p + fixed > to:
					# Python reference: a payload that overruns the record is
					# a silent break, not a failure ("else: break" with ok
					# untouched) -- the engine reads on.
					break
				if fixed == 12:
					# The cell triple (0x04 and siblings): all three
					# components, not just x and y -- a caller that wants a
					# cell takes the first two, and one that drops z silently
					# would make a 12-byte payload look like an 8-byte one.
					out.append([tag, Vector3i(code.decode_s32(p),
						code.decode_s32(p + 4), code.decode_s32(p + 8))])
				else:
					# Python-reference semantics: the fixed payload is ONE
					# little-endian integer of exactly `fixed` bytes (0x4b
					# carries a single byte; 0x71 has none and yields 0).
					var v := 0
					for i in fixed:
						v |= code[p + i] << (8 * i)
					out.append([tag, v])
				p += fixed
				continue
		if w == STR2:
			# The handler calls strcpy TWICE: two NUL-terminated strings with
			# no tag byte between them (0x3a: "HERO" then "res:17562").
			for _i in 2:
				var e2 := p
				while e2 < to and code[e2] != 0:
					e2 += 1
				if e2 >= to:
					push_error("ScriptVM: unterminated STR2 string at %d" % p)
					return null
				out.append([tag, code.slice(p, e2).get_string_from_ascii()])
				p = e2 + 1
			continue
		if w == NUMSTR:
			# Handler 0x0826cb0e: a u32 into the numeric slot array, THEN a
			# NUL-terminated string into the string slots. A SECOND string
			# follows behind two gates the handler applies in order (row 838):
			# the stored u32 must be NEGATIVE ("the operand is the variable
			# named below") and the byte after the first string must be
			# non-zero -- EXCEPT 0x7a, whose handler 0x0826de28 has no second
			# branch at all; it strncasecmps the string against "res:" and
			# strtol's the remainder into a resource id.
			# TRUNCATION IS A SILENT BREAK, not a failure: every `end < 0`
			# here breaks the arg loop with the record still ok -- the engine
			# reads on. Only the STR families treat a missing NUL as invalid.
			if p + 4 > to:
				break
			var num := code.decode_s32(p)
			out.append([tag, num])
			p += 4
			var e3 := p
			while e3 < to and code[e3] != 0:
				e3 += 1
			if e3 >= to:
				break
			out.append([tag, code.slice(p, e3).get_string_from_ascii()])
			p = e3 + 1
			if tag != 0x7a and (num & 0x80000000) != 0 and p < to and code[p] != 0:
				var e4 := p
				while e4 < to and code[e4] != 0:
					e4 += 1
				if e4 >= to:
					break
				out.append([tag, code.slice(p, e4).get_string_from_ascii()])
				p = e4 + 1
			continue
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
			# READ THE DECLARED WIDTH, not four bytes every time. Every tag here
			# was 4 wide until 0x6b (2) arrived with CreateNPC, and decode_s32 on
			# a 2-byte payload silently reads the next tag byte into the value
			# while the cursor advances correctly -- a wrong number, not a parse
			# error, which is the failure mode this class exists to avoid.
			out.append([tag, code.decode_s16(p) if w == 2 else code.decode_s32(p)])
			p += w
	return out


func _apply(rec: Dictionary, host: Object) -> bool:
	var a: Array = rec["args"]
	match int(rec["op"]):
		OP_DIALOG_DEF:
			return host.define_dialogue(rec["definition"])
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
		OP_SET_VAR:
			# (string name, i32 value). NOT SetVarBit: this writes a whole
			# value under a name (`PoolDLG` 0, `atmos10` 1), where SetVarBit
			# writes one BIT INDEX. Routed to a different host method for that
			# reason -- sharing set_var() would write bit 0 of PoolDLG and call
			# it done.
			if a.size() >= 2:
				host.set_script_var(str(a[0][1]), int(a[1][1]))
		OP_CREATE_NPC:
			var handle := ""
			var name := ""
			var task := ""
			var art := ""
			var ids: Array[int] = []
			var cell := quest_origin
			var dialogue := ""
			for arg in a:
				match int(arg[0]):
					0x01:
						if handle.is_empty(): handle = str(arg[1])
						else: name = str(arg[1])
					0x02: ids.append(int(arg[1]))
					0x04:
						if arg[1] is Vector3i:
							var c: Vector3i = arg[1]
							cell = Vector2i(c.x, c.y)
						else:
							name = str(arg[1])
							if host.has_method("script_position"):
								var placed: Vector2i = host.script_position(name)
								if placed != Vector2i(-1, -1):
									cell = placed
					0x05: task = str(arg[1])
					0x09:
						task = str(arg[1])
						dialogue = str(arg[1])
					0x67: art = str(arg[1])
			if handle.is_empty() or ids.is_empty():
				return false
			host.create_npc(handle, ids[0], name, task, art, cell)
			if host.has_method("configure_npc"):
				host.configure_npc(handle, ids[1] if ids.size() > 1 else 0,
					ids[2] if ids.size() > 2 else 0, dialogue)
		OP_NPC_GOTO:
			# (string handle, VARIANT cell). The cell is the (x, y, z) triple;
			# z is 0 on every record read so far and is dropped HERE rather than
			# in the parser, so the tag's real width stays visible above.
			if a.size() >= 2 and a[1][1] is Vector3i:
				var c: Vector3i = a[1][1]
				host.npc_goto(str(a[0][1]), Vector2i(c.x, c.y))
		OP_QUEST_COMPASS:
			# (string handle). Marks whose head the quest compass points at --
			# the `?!` in a retail capture. Recorded, not drawn: the marker's
			# art has not been identified and guessing it would be invention.
			if a.size() >= 1:
				host.quest_compass(str(a[0][1]))
		OP_NOP:
			pass
		OP_SET_NPC_STATE:
			return host.npc_state(a)
		OP_TEXT:
			return host.dialogue_text(a)
		OP_BUTTON:
			return host.dialogue_button(a)
		OP_START_QUEST:
			return host.start_quest(int(a[0][1]))
		OP_END_QUEST:
			return host.end_quest(int(a[0][1]))
		OP_GOLD:
			return host.give_gold(str(a[0][1]), int(a[1][1]))
		OP_DELETE_NPC:
			return host.delete_npc(str(a[0][1]))
		OP_COMPASS_POS:
			return host.quest_compass_pos(Vector2i(int(a[0][1]), int(a[1][1])), int(a[2][1]))
		OP_DIALOG_STATE:
			return host.dialogue_state(str(a[0][1]), int(a[1][1]))
		OP_SOUND:
			return host.play_sound(str(a[0][1]))
	return true


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
