extends RefCounted
## The PER-SECTOR LEVEL BAND: where a spawned creature's level comes from
## (autoresearch row 953).
##
## Opcode 100 is `SpawnValues` -- retail's own name, from the script compiler's
## keyword tables -- and it carries three int32. The first is 50 in all 11,498
## records in the Seraphim tree and is not a level. The other two are a BAND:
##
##     SpawnValues(50, lo, hi)
##
## `lo <= hi` in 11,498 of 11,498 records, against a control of 0.00% for the
## same test on the first pair, so the ordering belongs to that pair rather
## than to the record. 49 distinct bands, lo in 1..45, hi in 4..80, spans 3..35.
##
## THE BAND IS GEOGRAPHIC, and that is what says it is a LEVEL band rather than
## a percentage or a weight. Every `Sector<cx><cyyy>Init` / `...Enter`
## procedure in vectoren.bin owns a funkcode span, and the SpawnValues records
## inside it belong to that sector. Reading them out:
##
##   sector 50,39  the Seraphim's own StartPosition   -> (1, 4)
##   sectors 51,39  53,42  54,43  59,5  -- the magician, both elves, the dwarf
##                 and the gladiator's starts         -> (1, 4)
##   sector 5,26   the Daemoness's start              -> (45, 80)
##   sector 97,60  the Underworld start               -> (30, 50)
##
## SEVEN OF NINE class start sectors land on the lowest band in the game. A
## number that was not a level would not do that.
##
## 5666 sectors carry a band; the low bound runs 1..45 with a median of 27.
##
## SIXTY SECTORS DECLARE MORE THAN ONE BAND and nothing recovered says what
## chooses between them, so band() returns the first and bands_of() returns all
## -- the ambiguity is exposed rather than resolved by a warning nobody reads.
##
## WHAT THIS DOES NOT SAY: how a creature's level is drawn from the band, and
## whether the same number is the level its SKILLS are known at. Both are
## needed before the attack and defence ratings can be computed
## (research/engine/combat-formulas.md), and neither is recovered -- so this
## class returns the band and does not roll.

const OP_SPAWN_VALUES := 100
## The first argument, constant across every record measured. Kept so a tree
## that breaks the assumption is noticed rather than silently reinterpreted.
const ARG0 := 50

var found := false
var sectors := 0
var records := 0
## packed sector key -> Vector2i(lo, hi)
var _band: Dictionary[int, Vector2i] = {}
## sector key -> every distinct band it declares, in file order
var _all: Dictionary[int, Array] = {}   ## values are Array[Vector2i]
var multi := 0        ## sectors declaring more than one band


static func key_of(cx: int, cy: int) -> int:
	return cx * 1000 + cy


func _init(dir: String) -> void:
	var vec := Sacred.Vectoren.new(dir)
	if not vec.found:
		push_warning("SpawnLevels: vectoren.bin did not decode in %s" % dir)
		return
	var code := FileAccess.get_file_as_bytes(dir.path_join("funkcode.bin"))
	if code.is_empty():
		push_warning("SpawnLevels: funkcode.bin is unreadable in %s" % dir)
		return
	# The procedure NAME is the sector key: `Sector` + cx + cy as three digits,
	# from retail's own `Sector%d%3.3dInit` format string. cx never reaches
	# three digits (the grid is 100 wide) so the concatenation is unambiguous.
	var rx := RegEx.create_from_string("^Sector(\\d+)(Init|Enter)$")
	for i in vec.procs:
		var p := vec.proc_at(i)
		if p.is_empty():
			continue
		var m := rx.search(p["name"])
		if m == null:
			continue
		var digits := m.get_string(1)
		if digits.length() < 4:
			continue          # no room for a 3-digit cy plus a cx
		var cy := digits.substr(digits.length() - 3).to_int()
		var cx := digits.substr(0, digits.length() - 3).to_int()
		for bd in _bands_in(code, int(p["offset"]), int(p["length"])):
			records += 1
			var k := key_of(cx, cy)
			# A SECTOR CAN DECLARE MORE THAN ONE BAND -- 60 of them do, measured
			# -- so every distinct band is kept rather than the first winning
			# behind a warning. What picks between them is not recovered, so
			# band() documents that it returns the first and bands_of() exists
			# for a caller that must not pretend there is only one.
			if not _all.has(k):
				_all[k] = []
			var seen: Array = _all[k]
			if not seen.has(bd):
				seen.append(bd)
			_band[k] = seen[0]
	sectors = _band.size()
	for k in _all:
		if (_all[k] as Array).size() > 1:
			multi += 1
	found = sectors > 0


## Every SpawnValues band in one funkcode span. Walks by the length field, so
## it needs no tag table for the opcodes it skips.
func _bands_in(code: PackedByteArray, offset: int, length: int) -> Array:
	var out: Array = []
	if offset < 0 or length <= 0 or offset + length > code.size():
		return out
	var p := offset
	var end := offset + length
	while p + 4 <= end:
		var op := code.decode_u16(p)
		var l := code.decode_u16(p + 2)
		if l < 4 or p + l > end:
			return out
		if op == OP_SPAWN_VALUES:
			var n := PackedInt32Array()
			var q := p + 4
			while q + 5 <= p + l:
				if code[q] == 0x0b:
					n.append(code.decode_s32(q + 1))
					q += 5
				else:
					q += 1
			if n.size() >= 3 and n[0] == ARG0 and n[1] <= n[2]:
				out.append(Vector2i(n[1], n[2]))
		p += l
	return out


## The level band for a sector, or (-1,-1) when that sector declares none.
## 5666 sectors carry one, so an absent one is ordinary.
##
## RETURNS THE FIRST of possibly several: 60 sectors declare two or more and
## nothing recovered says what chooses between them. A caller that cannot
## tolerate that must use bands_of().
func band(cx: int, cy: int) -> Vector2i:
	return _band.get(key_of(cx, cy), Vector2i(-1, -1))


func has_band(cx: int, cy: int) -> bool:
	return _band.has(key_of(cx, cy))


## The band covering a CELL, which is what a spawner actually holds.
func band_at_cell(cell: Vector2i) -> Vector2i:
	return band(cell.x / Sacred.SECT, cell.y / Sacred.SECT)


## Every distinct band a sector declares, in file order. More than one for 60
## sectors; see band().
func bands_of(cx: int, cy: int) -> Array:
	return _all.get(key_of(cx, cy), [])
