extends "res://check.gd"
## floor_check.gd -- the ONE runnable check for world/floor.pak, the per-cell
## OVERLAY TILE layer reached through WldxEntry +0x0c.
##
##   godot --headless --path godot-port --script floor_check.gd
##
## Record is 16 bytes: +0x00 the record's own index, +0x04 the payload,
## +0x08 zero, +0x0c a next index that is either 0 or self+1 -- so a cell's
## handle heads a CHAIN, exactly like static.pak's nextStaticId (row 686).
##
## THE FINDING THIS CHECK EXISTS TO PROTECT: +0x04 splits 15/17, and its LOW 17
## BITS ARE A tiles.pak INDEX. Established by a boundary test, not by eyeballing:
## tiles.pak holds 90,132 records, so a 17-bit field that is really a tile index
## must always land under 90,132 while an unrelated one would only do so 68.77%
## of the time. Measured 6872 of 6872 under it -- and reading one bit wider, at
## 18 bits, immediately drops to ~70%. Every referenced tile then resolves like
## a terrain tile does: texture id inside texture.pak's 25,535 and orientation
## inside 0..17, for all 6872.
##
## THE TOP 15 BITS ARE A SECOND TILE INDEX (row 701), not a layer, a sector or
## a draw order. The retail reader at 0x080e4ca5 splits the payload the same
## way this file does and then treats both halves identically -- each divided
## by 18 for its diamond slot, each looked up in the same tile table -- writing
## two UV pairs into one vertex struct. So a floor.pak cell is a TWO-TEXTURE
## BLEND: the low field is the tile, the top field (0 = none) is a transition
## sheet drawn with it. The blend OPERATION is still unread, so the port draws
## the low tile only.
const LOW17 := 0x1ffff
const TILE_COUNT := 90132        ## audited; tiles.pak does not open via Sacred.Pak
const FLOOR_COUNT := 6713136
const STRIDE := 977              ## coprime-ish walk, ~6872 samples

func _init() -> void:
	super()
	var install := Sacred.find_install()
	var fp := Sacred.Pak.new(install.path_join("world/floor.pak"))
	assert(fp.is_open(), "world/floor.pak did not open")
	assert(fp.count() == FLOOR_COUNT,
		"floor.pak record count moved: want %d, got %d" % [FLOOR_COUNT, fp.count()])
	var tiles := Sacred.Tiles.new(install.path_join("pak/tiles.pak"))
	assert(tiles.count() == TILE_COUNT,
		"tiles.pak count moved: want %d, got %d" % [TILE_COUNT, tiles.count()])

	var n := 0
	var hi_n := 0
	var hi_valid := 0
	var hi_mod18 := 0
	var under17 := 0
	var under18 := 0
	var over16 := 0        ## values the field could not hold if it were 16 bits
	var resolved := 0
	for i in range(1, fp.count(), STRIDE):
		var r := fp.blob(i)
		if r.size() < 16:
			continue
		n += 1
		assert(r.decode_u32(0) == i, "record %d no longer carries its own index" % i)
		var nxt := r.decode_u32(0x0c)
		assert(nxt == 0 or nxt == i + 1,
			"record %d's next link is %d, not 0 or self+1 -- the chain shape moved" % [i, nxt])
		var v := r.decode_u32(4)
		# The top field is the SECOND tile of the blend (row 701). It must
		# resolve as a tile id, and tiles.pak's own orientation must equal the
		# index mod 18 -- the rule the engine derives it by at 0x080e4dbb.
		var hi := v >> 17
		if hi != 0:
			hi_n += 1
			if hi < TILE_COUNT:
				hi_valid += 1
				if tiles.orientation(hi) == hi % 18:
					hi_mod18 += 1
		if (v & LOW17) >= 0x10000:
			over16 += 1
		if (v & LOW17) < TILE_COUNT:
			under17 += 1
			var t := v & LOW17
			if tiles.texture_id(t) < 25535 and tiles.orientation(t) <= 17:
				resolved += 1
		if (v & 0x3ffff) < TILE_COUNT:
			under18 += 1
	assert(n > 1000, "sample too small to mean anything (%d)" % n)
	assert(under17 == n,
		"the low 17 bits are meant to be a tiles.pak index: %d of %d landed outside 0..%d" % [
			n - under17, n, TILE_COUNT])
	assert(resolved == n,
		"every referenced tile must resolve like a terrain tile (texture < 25535, orientation <= 17): %d of %d did" % [
			resolved, n])
	# The boundary is pinned from BOTH sides, because a narrower read is a
	# subset that would pass the test above for free. Below: the field must
	# actually HOLD values a 16-bit field could not (>= 65536), which a 16-bit
	# mask can never produce.
	# The bar is >0 in logic -- a 16-bit field cannot hold a single value at or
	# above 65536, and a 16-bit mask measures exactly 0 here. A floor of 100 is
	# kept so a near-empty sample cannot pass on one stray record. The real rate
	# is 530 of 6872 (7.7%): low tile ids are simply commoner than high ones,
	# since tiles 65536..90131 are only 27% of the table.
	assert(over16 > 100,
		"only %d of %d values reach 65536, so nothing here shows the field is wider than 16 bits" % [
			over16, n])
	# And above: one bit wider must be visibly WORSE, otherwise the 17-bit
	# result is just "any mask passes" and proves nothing.
	assert(float(under18) / float(n) < 0.9,
		"reading 18 bits still passes %.3f of the time -- the 17-bit boundary is not discriminating" % [
			float(under18) / float(n)])

	assert(hi_n > 100, "only %d records carry a non-zero top field -- too few to test row 701" % hi_n)
	assert(hi_valid == hi_n,
		"the top field is meant to be a second tiles.pak index: %d of %d landed outside 0..%d" % [
			hi_n - hi_valid, hi_n, TILE_COUNT])
	assert(hi_mod18 == hi_n,
		"tiles.pak orientation must equal index mod 18 for the top field (the engine's own rule): %d of %d disagreed" % [
			hi_n - hi_mod18, hi_n])

	# Guard the row-662 error: +0x0c is NOT dead at the chapel sector.
	var world := Sacred.World.new(install.path_join("world"))
	var stream := world.sector(50, 39)
	var handles := 0
	var slot08 := 0
	for i in Sacred.SECT * Sacred.SECT:
		if stream.decode_u32(Sacred.NAME + i * Sacred.CELL + 0x0c) != 0:
			handles += 1
		if stream.decode_u32(Sacred.NAME + i * Sacred.CELL + 0x08) != 0:
			slot08 += 1
	# Row 706: +0x08 is a RUNTIME slot -- the head of the engine's per-cell
	# circular list of mobile objects -- and is zero in every one of the
	# world's 24,780,800 cells. Guarded here so nobody sets out to decode it.
	assert(slot08 == 0,
		"WldxEntry +0x08 is shipped empty (row 706) but %d cells here are non-zero" % slot08)
	assert(handles > 2000,
		"sector 50,39 should carry ~2145 floor handles, got %d -- row 662 claimed zero and was wrong" % handles)

	print("floor_check\tOK\tsampled=%d\tlow17_tile_index=%d/%d\tover16=%d\tunder18=%.3f\tchapel_handles=%d" % [
		n, under17, n, over16, float(under18) / float(n), handles])
	finish(0)
