extends "res://checks/check.gd"
## trigger_check.gd -- the ONE runnable check for world/triggers.pak, the
## world's dynamic-object registry (NPCs, monsters, FX).
##
##   godot --headless --path godot-port --script trigger_check.gd
##
## Layout, measured 2026-08-13: magic TRG v1, u32 count @+4, a header at 0x100
## of {u32 136, u32 268, u32 36288} whose 268 is the data offset and whose
## 36288 == count * 16, then `count` 16-byte records at 0x10c:
##   +0x00 u32 trigger id (== record index for live records)
##   +0x04 u16 kind: 16 = live, 0 = dead/erased (an all-zero record)
##   +0x06 u32 static.pak RECORD index -- the back-link
##   +0x0a u16 always 1 for live   +0x0c u32 always 0
## 0x10c + count*16 lands exactly on the file length, which is what fixes the
## stride. NOTE: this file is NOT a generic Pak container -- the index at 0x100
## is a fixed header here, so it must never be read through Sacred.Pak.
##
## Fails loudly if the stride stops fitting the file, if the id<->static
## round-trip stops being bidirectional, or if the chapel priestess moves.
const REC := 16
const DATA_OFF := 0x10c
const PRIESTESS_TRIGGER := 2034
const PRIESTESS_STATIC := 758529

func _init() -> void:
	super()
	var install := Sacred.find_install()
	var bytes := FileAccess.get_file_as_bytes(install.path_join("world/triggers.pak"))
	assert(bytes.size() > DATA_OFF, "world/triggers.pak is missing or short")
	assert(bytes.slice(0, 3).get_string_from_ascii() == "TRG", "triggers.pak magic is not TRG")
	var count := bytes.decode_u32(4)
	assert(DATA_OFF + count * REC == bytes.size(),
		"stride broken: 0x10c + %d*%d = %d but the file is %d bytes" % [
			count, REC, DATA_OFF + count * REC, bytes.size()])

	var static_pak := Sacred.Pak.new(install.path_join("world/static.pak"))
	var statics := Sacred.Statics.new(static_pak)
	var live := 0
	var round_trips := 0
	for i in count:
		var o := DATA_OFF + i * REC
		if bytes.decode_u16(o + 4) != 16:
			continue          # dead/erased record
		live += 1
		assert(bytes.decode_u32(o) == i,
			"live trigger %d no longer carries its own id (+0x00 = %d)" % [i, bytes.decode_u32(o)])
		var target := bytes.decode_u32(o + 6)
		assert(target > 0 and target < static_pak.count(),
			"live trigger %d points outside static.pak (%d)" % [i, target])
		# The back-link must round-trip: the static this trigger names must name
		# it back through its own triggerId at +0x27.
		if static_pak.blob(target).decode_u32(0x27) == i:
			round_trips += 1
	assert(live > 0, "no live triggers at all -- the kind field or the stride moved")
	assert(round_trips == live,
		"the id<->static back-link is no longer bidirectional: %d of %d live triggers round-trip" % [
			round_trips, live])

	# The chapel priestess, the one dynamic object at the Seraphim start.
	var pr := static_pak.blob(PRIESTESS_STATIC)
	assert(pr.size() >= 64, "static %d is absent" % PRIESTESS_STATIC)
	assert(pr.decode_u32(0x27) == PRIESTESS_TRIGGER,
		"the chapel priestess static no longer carries trigger %d" % PRIESTESS_TRIGGER)
	assert(pr.decode_u32(8) == 0x10,
		"+0x08 == 0x10 is the dynamic-object discriminator; the priestess now reads 0x%x" % pr.decode_u32(8))
	var items := Sacred.Items.new(Sacred.Pak.new(install.path_join("pak/items.pak")))
	var nm := items.name_of(pr.decode_u32(4))
	assert(nm.to_lower().ends_with(".grn"),
		"a dynamic object must name a Granny model, not a sprite; got '%s'" % nm)
	assert(items.sprite_of(pr.decode_u32(4)) == 0,
		"a dynamic object must carry NO mixed.pak sprite -- that is why the sprite path drops it")

	print("trigger_check\tOK\tcount=%d\tlive=%d\tround_trips=%d\tpriestess=%s" % [
		count, live, round_trips, nm])
	finish(0)
