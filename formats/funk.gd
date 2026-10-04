extends RefCounted
const Pak := preload("res://formats/pak.gd")
## bin/TYPE_NPC_*/funkcode.bin -- the script bytecode's SPAWN TABLES.
##
## Framing (autoresearch row 711, confirmed against the interpreter's own
## `movsx eax, WORD PTR [ebx+0x2]` at 0x0826af24): u16 opcode, u16 length
## counting those four bytes, then a tagged argument list. Walking by the
## length field needs no tag table at all, so this reader only decodes the
## tags the three spawn opcodes actually use and REFUSES the rest -- an
## unknown tag inside one of those records is a parse error, not a shrug.
##
## What the three opcodes are (rows 728-730):
##   115  declares a spawn group: 1..20 creature ids and three (id, percent)
##        pairs. Every id is a creature.pak id -- 184 of 184 distinct.
##   100  three small numbers the engine writes into the object at the
##        CURRENT SECTOR; the first is always 50.
##    51  the roll. Header tag 0x36 goes into creature field +0x255, the
##        group-alert enable, and its two values split the file by
##        POPULATION: 100 = wildlife (rabbit, crow, deer, bat, cow),
##        310 = hostiles. Body is a repeated (creature id, percent, flag)
##        triple whose percents sum to 100 in 3906 of 5309 records.
##
## ponytail: no placement. WHERE a group spawns is not in these records --
## opcode 100 reads the engine's current-sector globals, and all 39,569 spawn
## records sit under a single script label, so the geography comes from script
## EXECUTION, which nothing here emulates. Upgrade path: interpret the
## Region%dInit / Sector%d%3.3dInit entry points named in startcode.bin.

const OP_ROLL := 51
const OP_SECTOR := 100
const OP_GROUP := 115
const WILDLIFE := 100      ## tag 0x36 value: ambient fauna
const HOSTILE := 310       ## tag 0x36 value: monsters and hostile NPCs

const STR := -1            ## payload is a NUL-terminated string, not a fixed width

## Tag -> payload width in bytes, for the tags the spawn opcodes use only.
## Opcode 115 is the one that needs the long tail: besides its id list
## (0x02) and three pairs (0x87/0x88/0x89) it also carries 0x8b, 0x1d and
## the string tags 0x67 and 0x1e. Leaving any of them out shifts the cursor
## and the ids stop being creature ids -- which is exactly what
## spawn_check.gd is there to catch.
const WIDTH := {
	0x02: 4, 0x0b: 4, 0x19: 12, 0x1d: 4, 0x1e: STR, 0x33: 8, 0x34: 8,
	0x35: 12, 0x36: 4, 0x67: STR, 0x87: 8, 0x88: 8, 0x89: 8, 0x8b: 1,
}

## vectoren.bin's record: a 64-byte name field then five i32, of which the
## first two are a BYTE OFFSET into funkcode.bin and a LENGTH. Consecutive
## entries tile the file (entry 0 is offset 0 length 410, entry 1 is offset
## 410), which is what identifies the pair. So vectoren.bin is the script's
## PROCEDURE TABLE, and it is what turns the spawn records from a flat list
## into placement.
## 88 is NOT "the header plus padding" -- it is 4 + 84, i.e. the u32 count plus
## ONE WHOLE RECORD. Record 0 is an all-zero sentinel (offset 0, length 0), so
## starting here skips it, which is right for this class: `_procs` is keyed by
## funkcode OFFSET and a zero-length record contributes nothing but a spurious
## match at offset 0.
##
## THE REAL BASE IS 4, and it matters the moment anyone treats a vectoren value
## as an INDEX rather than walking the table. vectoren's own quest section holds
## section-1 indices, and resolving each quest's +0x10c and asking whether the
## symbol is literally `QIS_Trigger<that quest id>` gives 285/285 at base 4 and
## 0/285 at base 88 -- where it lands one record early, on SelfTriggerQuest<id>,
## every time. Measured 2026-08-16; see research/formats/install-inventory.md.
const VEC_HDR := 88        ## count + record 0 -- an OFFSET walk, not an index base
const VEC_REC := 84
const VEC_NAME := 64

## One per opcode-51 record: {sector:Vector2i, kind, count_min, count_max,
## flags, has_pairs, pair34, pair33, entries:Array[Vector3i] of
## (creature id, percent, flag)}.
var rolls: Array[Dictionary] = []
## One per opcode-115 record: {sector:Vector2i, ids:PackedInt32Array,
## pairs:Array[Vector2i]}.
var groups: Array[Dictionary] = []
## One per opcode-100 record: {sector:Vector2i, values:PackedInt32Array}.
var sector_params: Array[Dictionary] = []
## Sector (gx, gy) -> indices into `rolls`.
var by_sector: Dictionary[Vector2i, PackedInt32Array] = {}

var _procs: Array = []       ## sorted [offset, end, sector, name]
var _cursor := 0
var _sector := Vector2i(-1, -1)

## `dir` is one bin/TYPE_NPC_* directory: it holds both funkcode.bin and the
## vectoren.bin that indexes it.
func _init(dir: String) -> void:
	_read_procs(dir.path_join("vectoren.bin"))
	var b := FileAccess.get_file_as_bytes(Pak.resolve(dir.path_join("funkcode.bin")))
	if b.is_empty():
		push_error("Funk: cannot read funkcode.bin in %s" % dir)
		return
	var off := 0
	while off + 4 <= b.size():
		var opcode := b.decode_u16(off)
		var length := b.decode_u16(off + 2)
		if length < 4 or off + length > b.size():
			push_error("Funk: bad record length %d at %d" % [length, off])
			return
		match opcode:
			OP_ROLL, OP_GROUP, OP_SECTOR:
				# Records are walked in increasing offset order and the
				# procedures tile the file, so a moving cursor beats a
				# binary search per record.
				_sector = Vector2i(-1, -1)
				while _cursor < _procs.size() and _procs[_cursor][1] <= off:
					_cursor += 1
				if _cursor < _procs.size() and off >= _procs[_cursor][0]:
					_sector = _procs[_cursor][2]
		match opcode:
			OP_ROLL: _read_roll(b, off + 4, off + length)
			OP_GROUP: _read_group(b, off + 4, off + length)
			OP_SECTOR: _read_sector(b, off + 4, off + length)
		off += length

## Procedure names the engine builds with sprintf("Sector%d%3.3d%s", x, y,
## phase) at 0x082a087a -- and the two arguments are written straight into
## the globals 0x879a080 / 0x879a084 on the next two instructions, which are
## the same pair opcode 100's handler shifts left by 6 to make a world
## position. So the FIRST field is gx and the trailing THREE digits are gy.
## Measured confirmation, since the format alone leaves the order open:
## reading it this way puts 5659 of 5684 script sectors inside the world's
## real 6050-sector set; swapping gx and gy drops that to 4013.
##
## THERE IS A SECOND, ID-KEYED FORM. The engine also carries
## "Sector%dInit/Enter/Exit" (0x086eb1b1), formatted elsewhere entirely
## (0x081c5c3b, alongside Region%dInit) from a single number -- the dungeon
## path. 48 procedures use it and they are NOT world sectors: %3.3d always
## emits three digits and %d at least one, so a grid name never has fewer
## than four, and every one of these has exactly two. They are kept with
## sector.x == -1 and the id in sector.y rather than being force-fitted onto
## the grid. Reading a two-digit name as a grid name is exactly the bug this
## comment exists to prevent: it invents sector (0, 84) or (84, 84)
## depending on which end you pad.
func _read_procs(path: String) -> void:
	var v := FileAccess.get_file_as_bytes(Pak.resolve(path))
	if v.size() < VEC_HDR:
		push_error("Funk: cannot read %s" % path)
		return
	var n := v.decode_u32(0)
	var rx := RegEx.create_from_string("^Sector(\\d+)(Init|Enter|Exit)$")
	for i in n:
		var o := VEC_HDR + i * VEC_REC
		if o + VEC_REC > v.size():
			break
		var name := v.slice(o, o + VEC_NAME).get_string_from_ascii()
		var m := rx.search(name)
		if m == null:
			continue
		var digits := m.get_string(1)
		var sector := Vector2i(-1, int(digits))          # id-keyed dungeon form
		if digits.length() >= 4:
			sector = Vector2i(int(digits.substr(0, digits.length() - 3)),
				int(digits.right(3)))
		var start := v.decode_s32(o + VEC_NAME)
		_procs.append([start, start + v.decode_s32(o + VEC_NAME + 4), sector, name])
	_procs.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])

## (tag, value) pairs of one record body. Eight-byte tags yield the two
## halves as one Vector2i, twelve-byte tags as a Vector3i, so a caller
## never has to re-split them.
func _fields(b: PackedByteArray, from: int, to: int) -> Array:
	var out: Array = []
	var p := from
	while p < to:
		var tag := b[p]
		p += 1
		if not WIDTH.has(tag):
			push_error("Funk: tag 0x%02x in a spawn record at %d" % [tag, p - 1])
			return []
		var w: int = WIDTH[tag]
		if w == STR:
			var end := p
			while end < to and b[end] != 0:
				end += 1
			out.append([tag, b.slice(p, end).get_string_from_ascii()])
			p = end + 1
			continue
		if p + w > to:
			break            # payload overruns: the engine reads on, the loop then ends
		match w:
			1: out.append([tag, b[p]])
			4: out.append([tag, b.decode_u32(p)])
			8: out.append([tag, Vector2i(b.decode_u32(p), b.decode_u32(p + 4))])
			12: out.append([tag, Vector3i(b.decode_u32(p), b.decode_u32(p + 4), b.decode_u32(p + 8))])
		p += w
	return out

func _read_roll(b: PackedByteArray, from: int, to: int) -> void:
	# `has_pairs` records the PRESENCE of 0x34/0x33, not their value: both
	# halves are legitimately zero in some records, so presence is the only
	# reliable discriminator between the two populations.
	var rec := {"sector": _sector, "kind": 0, "count_min": 0, "count_max": 0,
		"flags": 0, "has_pairs": false, "pair34": Vector2i.ZERO,
		"pair33": Vector2i.ZERO, "entries": [] as Array[Vector3i]}
	for f in _fields(b, from, to):
		match f[0]:
			0x36: rec["kind"] = f[1]
			0x34:
				rec["pair34"] = f[1]
				rec["has_pairs"] = true
			0x33: rec["pair33"] = f[1]
			# The engine swaps these two if the first is larger (0x0827b44a),
			# so they are an ordered range; the third component is a flag.
			0x35:
				rec["count_min"] = mini(f[1].x, f[1].y)
				rec["count_max"] = maxi(f[1].x, f[1].y)
				rec["flags"] = f[1].z
			0x19: rec["entries"].append(f[1])
	if _sector.x >= 0:
		if not by_sector.has(_sector):
			by_sector[_sector] = PackedInt32Array()
		by_sector[_sector].append(rolls.size())
	rolls.append(rec)

func _read_group(b: PackedByteArray, from: int, to: int) -> void:
	var ids := PackedInt32Array()
	var pairs: Array[Vector2i] = []
	for f in _fields(b, from, to):
		match f[0]:
			0x02: ids.append(f[1])
			0x87, 0x88, 0x89: pairs.append(f[1])
	groups.append({"sector": _sector, "ids": ids, "pairs": pairs})

func _read_sector(b: PackedByteArray, from: int, to: int) -> void:
	var v := PackedInt32Array()
	for f in _fields(b, from, to):
		if f[0] == 0x0b:
			v.append(f[1])
	sector_params.append({"sector": _sector, "values": v})

## Every opcode-51 roll that applies in sector (gx, gy). Empty for a sector
## the scripts never spawn in -- 5709 of the world's 6050 sectors carry
## spawn records, and a town sector like the Silver Creek chapel (50, 39)
## legitimately carries none.
func rolls_for(gx: int, gy: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i in by_sector.get(Vector2i(gx, gy), PackedInt32Array()):
		out.append(rolls[i])
	return out

## Weighted pick from one roll record: returns a creature.pak id, or -1 if
## the record is empty. The percents are a weight table -- they sum to 100
## in 74% of records and to 200/300/400 in most of the rest, so the roll is
## against the ACTUAL total, not against a hardcoded 100.
func pick(roll: Dictionary, rng: RandomNumberGenerator) -> int:
	var entries: Array[Vector3i] = roll["entries"]
	if entries.is_empty():
		return -1
	var total := 0
	for e in entries:
		total += e.y
	if total <= 0:
		return entries[0].x
	var r := rng.randi_range(0, total - 1)
	for e in entries:
		r -= e.y
		if r < 0:
			return e.x
	return entries[-1].x
