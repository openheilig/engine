extends RefCounted
const Pak := preload("res://formats/pak.gd")
## bin/sets.bin -- the ITEM SET table: 65 named equipment suites and the
## items.pak records that belong to each. Compiled by retail from
## scripts/sets.txt, which retail does not ship (autoresearch rows 923, 924).
##
## LAYOUT: `u32 count` = 66 at +0, then 66 records of 28 int32 (112 bytes), and
## `4 + 66*112 = 7396` is the file exactly. Record 0 is entirely 0xCCCCCCCC --
## MSVC uninitialised-memory filler, not data -- so 65 records carry sets and
## THE FILE'S OWN NUMBERING IS 1-BASED. This class keeps that numbering rather
## than shifting to 0, because field 11 encodes the index and a reader that
## renumbers has to remember to shift it back on every comparison.
##
##   [0..9]   up to ten items.pak member records, zero-padded
##   [10]     the set's NAME, as a global.res key that is ALREADY HASHED
##   [11]     (index << 8) | member_count
##   [12..27] always zero
##
## Field 11 holds for 65 of 65 and is checked on load: it ties the record's
## position to its own contents, so a stride that has slipped by one record
## disagrees on every row rather than silently returning a neighbour's set.
##
## THE NAME IS NOT IN THIS FILE. Field 10 is negative, which is how the engine
## marks a key that must be used directly rather than hashed again -- see
## Resources.by_id. All 65 resolve, to 'Dark Side of Feac', "Uriel's Legacy",
## "Astrala's Powermonger", 'Dream Netting of the Gods'. Meaningful English at
## 65/65 is not something a wrong field produces, which is why no separate
## control arm was needed for it.
##
## Resources is NOT loaded here. name_key() always works; name_of() takes a
## Resources the caller already has, because parsing global.res costs 23123
## entries and a caller asking which set an item belongs to does not need a
## single string.
##
## MEMBER NAMES ARE OFTEN EMPTY, and that is items.pak's property rather than
## this table's: of 378 members only 114 name a `.GRN`, because many of the
## higher ids sit on items.pak records that carry no name at all. A caller must
## not treat an empty name as a bad member.
##
## WHAT IS NOT KNOWN: the set BONUS. This file lists members and nothing else,
## so whatever wearing a full suite grants lives elsewhere -- balance.bin or
## wpmod.bin are the candidates and neither has been shown to carry it.

const REC := 28          ## int32 per record
const MEMBERS := 10      ## [0..9]
const F_NAME := 10
const F_PACKED := 11
const FILLER := -858993460      ## 0xCCCCCCCC as a signed int32

var found := false
var count := 0           ## sets carrying data; 65 when the file is whole
var members := 0         ## total member slots across all sets

var _members: Dictionary[int, PackedInt32Array] = {}   ## 1-based set -> members
var _name_key: Dictionary[int, int] = {}               ## 1-based set -> global.res key
var _set_of: Dictionary[int, int] = {}                 ## items.pak record -> set


func _init(install: String) -> void:
	var raw := FileAccess.get_file_as_bytes(Pak.resolve(install.path_join("bin/sets.bin")))
	if raw.size() < 4:
		push_warning("Sets: bin/sets.bin missing under %s" % install)
		return
	var want := raw.decode_u32(0)
	if raw.size() != 4 + want * REC * 4:
		push_warning("Sets: sets.bin is %d bytes, not the %d that %d records of %d int32 need"
			% [raw.size(), 4 + want * REC * 4, want, REC])
		return
	for i in want:
		var base := 4 + i * REC * 4
		var f := PackedInt32Array()
		f.resize(REC)
		for k in REC:
			f[k] = raw.decode_s32(base + k * 4)
		# Record 0 is filler in the shipped file. Skipping it by INDEX would
		# assume that stays true; recognising the filler pattern means a future
		# file that fills the slot is read rather than dropped.
		if f[0] == FILLER:
			continue
		var mem := PackedInt32Array()
		for k in MEMBERS:
			if f[k] != 0:
				mem.append(f[k])
		# The self-index check. A slipped stride fails this on every row.
		if f[F_PACKED] != ((i << 8) | mem.size()):
			push_warning("Sets: record %d packs %d, not the %d its own position and %d members imply"
				% [i, f[F_PACKED], (i << 8) | mem.size(), mem.size()])
			return
		_members[i] = mem
		_name_key[i] = f[F_NAME]
		for m in mem:
			# First set wins, matching how the engine's own tables resolve a
			# duplicate. Measured: all 378 members are distinct, so nothing
			# actually collides in the shipped file.
			if not _set_of.has(m):
				_set_of[m] = i
		members += mem.size()
	count = _members.size()
	found = count > 0


## The items.pak records belonging to a set, in file order. Empty for an
## unknown set.
func members_of(set_index: int) -> PackedInt32Array:
	return _members.get(set_index, PackedInt32Array())


## The set an items.pak record belongs to, or -1. This is the direction the
## engine wants: an item is in hand and the question is whether it completes
## a suite.
func set_of_item(record: int) -> int:
	return _set_of.get(record, -1)


## The set's raw global.res key. Negative, because it is already hashed.
func name_key(set_index: int) -> int:
	return _name_key.get(set_index, 0)


## The set's display name. `res` is a Sacred.Resources the caller already
## built; "" when the set is unknown or `res` is null.
func name_of(set_index: int, res) -> String:
	if res == null or not _name_key.has(set_index):
		return ""
	return res.by_id(_name_key[set_index])


## Every set index that carries data, ascending. 1-based, see the class doc.
func set_indices() -> PackedInt32Array:
	var out := PackedInt32Array()
	for k in _members:
		out.append(k)
	out.sort()
	return out
