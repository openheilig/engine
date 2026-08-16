extends RefCounted
## bin/wea.bin -- 256 EQUIPMENT POOLS: for each pool, the items.pak records a
## spawner may dress an NPC in. Loaded by retail at startup beside Balance,
## World, World2 and wpmod (autoresearch row 923).
##
## LAYOUT, and it has no header at all: 256 groups laid end to end, each a
## `u32 n` followed by n `u32` items.pak record ids. That consumes the file
## exactly -- 1162 of 1162 int32 -- and exact consumption IS the decode: with
## no magic, no version and no count, a wrong reading desynchronises on the
## first group and runs off the end long before 256.
##
## 114 pools carry members and 142 are empty, which is normal rather than
## damage: the pool id is an archetype slot and most archetypes do not exist.
## Group sizes run 1..32. All 906 members name a `.GRN` in items.pak, and the
## gate asserts that rather than this class, because the structural proof above
## already stands on its own and loading items.pak to read a 4.6 KB table would
## make every caller pay 4.5 MB for corroboration it did not ask for.
##
## MEMBERS REPEAT ON PURPOSE. 906 members span only 265 distinct records, so a
## pool is a WEIGHTED draw, not a set: `w_thief_metal_02.grn` appearing twice in
## pool 0 means it is twice as likely, exactly as sndprofiles.pak pads a short
## bank by repeating entries. A caller that deduplicates changes the odds.
##
## The pools read as a catalogue by archetype -- 0-3 thief armour by material,
## 8-11 ogre, 12-14 orc, 15-18 DarkElve, 50-61 and 224-237 shields, 70-150 and
## 200-217 weapons by family. This is the table a spawner needs to dress an
## NPC and the port has no other source for it.
##
## WHAT IS NOT KNOWN: what selects a pool. Every u8 and u16 column of items.pak
## was scanned for a field equal to the pool id of its members (best 20 of 906)
## and every column of creature.pak's 474 records likewise, with nothing
## reaching agreement. The 0..255 id is most likely a script argument rather
## than a table column, so this class is addressed BY POOL and offers no
## reverse lookup -- there is nothing measured to build one from.

const POOLS := 256

var found := false
var pools := 0          ## groups parsed; 256 when the file is whole
var filled := 0         ## pools with at least one member
var members := 0        ## total member slots, repeats included

var _pools: Array[PackedInt32Array] = []


func _init(install: String) -> void:
	var raw := FileAccess.get_file_as_bytes(install.path_join("bin/wea.bin"))
	if raw.size() < 4 or raw.size() % 4 != 0:
		push_warning("Equipment: bin/wea.bin missing or not u32-aligned under %s" % install)
		return
	var total := raw.size() / 4
	var p := 0
	while _pools.size() < POOLS and p < total:
		var n := raw.decode_u32(p * 4)
		p += 1
		# A desynchronised parse shows up here first: a bogus count either runs
		# past the file or leaves the tail unconsumed, and both are rejected.
		if n > total - p:
			push_warning("Equipment: pool %d declares %d members it cannot hold" % [_pools.size(), n])
			return
		var g := PackedInt32Array()
		for k in n:
			g.append(raw.decode_u32((p + k) * 4))
		p += n
		_pools.append(g)
		if not g.is_empty():
			filled += 1
		members += g.size()
	if p != total or _pools.size() != POOLS:
		push_warning("Equipment: wea.bin parsed %d of %d pools and %d of %d int32 -- layout rejected"
			% [_pools.size(), POOLS, p, total])
		return
	pools = _pools.size()
	found = pools == POOLS


## The items.pak records of one pool, repeats and order preserved -- see the
## class doc: the repeats are the weighting.
func members_of(pool: int) -> PackedInt32Array:
	if pool < 0 or pool >= _pools.size():
		return PackedInt32Array()
	return _pools[pool]


## How many members a pool has, 0 for an empty or out-of-range pool.
func size_of(pool: int) -> int:
	return members_of(pool).size()


## Every pool id that carries members, ascending. Most pools are empty, so a
## caller wanting to survey the table wants this rather than 0..255.
func filled_pools() -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in _pools.size():
		if not _pools[i].is_empty():
			out.append(i)
	return out
