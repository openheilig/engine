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
## HOW THE BAND BECOMES A LEVEL -- and it is NOT a draw, which is the part
## this file used to get wrong. Read off `sub_81806DC`, the only caller being
## the creature spawn path `sub_8180B22`:
##
##     level = hero's own level                  (in a party, the highest)
##     if band.lo and band.hi:
##         lo = DiffLo[difficulty] + band.lo
##         hi = DiffHi[difficulty] + band.hi
##         if   level <  lo:  level = lo
##         elif level <= hi:  level = level + rand()%2
##         else:              level = hi
##
## SO THE BAND IS A CLAMP ON THE PLAYER'S LEVEL, not a range to sample. A
## monster in a sector the player has outgrown is held at `hi`; one in a sector
## above them is lifted to `lo`; in between it tracks the player and the ONLY
## randomness in the whole rule is a single `rand()%2`, worth +0 or +1. That
## is why Sacred's world feels level-scaled, and a port that rolled uniformly
## across the band would get the difficulty curve wrong everywhere while still
## producing levels inside the right range -- an error no range check catches.
##
## THE TWO DIFFICULTY TABLES ARE `balance.bin` KEYS, recovered (row 958). They
## sit in .bss at 0x8B89BA8 and 0x8B89DAC because `sub_812B3E6` slurps the whole
## of `bin/balance.bin` into that block, and they are `OffLevel` and `LevelKap`
## -- SIX-ELEMENT int32 arrays whose key-map entries name only their first
## element. See Sacred.Balance.OFF_LEVEL.
##
##   difficulty   1 Silver  2 Gold  3 Platinum  4 Niob
##   OffLevel        +0       +35      +70        +128    on the LOW bound
##   LevelKap       +50      +120     +190        +250    on the HIGH bound
##
## `LevelKap` is large enough that on Silver the high bound of a (1,4) sector
## becomes 54, so the clamp tracks the player for most of a playthrough and the
## band's own high bound only bites in the endgame. That is the level-scaling
## everyone remembers about this game, and it is a property of these two
## numbers rather than of the band.
##
## STILL OPEN: whether this level is also the level at which the creature's
## SKILLS are known. The skills feed the rating curve
## (research/engine/combat-formulas.md) and `sub_81F596E` reads their levels
## out of the creature struct rather than deriving them from the level, so the
## link is not established here.

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


## The level a creature spawns at, transcribed from sub_81806DC. See the class
## doc: the band CLAMPS the hero's level, it is not sampled.
##
## `rng` is the caller's, because the +0..1 is a real random draw and a sim
## that records and replays cannot have a hidden source. `band` of (-1,-1) --
## what band() returns for a sector that declares none -- leaves the hero's
## level untouched, which is retail's own `if (lo && hi)` guard.
##
## `diff_lo`/`diff_hi` are `OffLevel[i]` and `LevelKap[i]` for the difficulty in
## play; they default to the identity so a caller that has no balance.bin gets
## the band verbatim instead of a silently shifted one. Prefer
## level_at_difficulty(), which reads them.
static func level_for(hero_level: int, band: Vector2i, rng: RandomNumberGenerator,
		diff_lo: int = 0, diff_hi: int = 0) -> int:
	if band.x <= 0 or band.y <= 0:
		return hero_level
	var lo := diff_lo + band.x
	var hi := diff_hi + band.y
	if hero_level < lo:
		return lo
	if hero_level <= hi:
		return hero_level + rng.randi_range(0, 1)
	return hi


## The same clamp, with the difficulty adjustments read from balance.bin rather
## than passed in. `difficulty` is 1..4 = Silver / Gold / Platinum / Niob.
##
## This is the form a game should call: level_for's bare arguments exist for a
## gate that wants to drive the branches directly.
static func level_at_difficulty(hero_level: int, band: Vector2i,
		rng: RandomNumberGenerator, bal, difficulty: int) -> int:
	if bal == null or not bal.found:
		return level_for(hero_level, band, rng)
	var adj: Vector2i = bal.difficulty_adjust(difficulty)
	return level_for(hero_level, band, rng, adj.x, adj.y)
