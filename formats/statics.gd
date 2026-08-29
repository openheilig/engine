extends RefCounted
## world/static.pak -- 64-byte records, one per placed static object, indexed
## directly by WldxEntry +0x04. Record 0 is the null object.
##
##   +0x00 u32  self index (every record validates against its own index)
##   +0x04 u32  type id, 2872 distinct in 801..31936
##   +0x08 u32  flags, 9 distinct values
##   +0x0e i32  ox   <- NOT 4-byte aligned
##   +0x12 i32  oy   <- NOT 4-byte aligned
##
## ox/oy are absolute isometric SCREEN coordinates: ox = 48*(cx-cy),
## oy = 24*(cx+cy) plus a sub-cell offset. They, not the referencing cell, are
## the object's true position -- see IsoCamera's note on the 96x48 cell.

const Pak := preload("res://formats/pak.gd")

var _pak: Pak

func _init(pak: Pak) -> void:
	_pak = pak

func count() -> int:
	return _pak.count()

## Sacred.Walkable._door_decision needs the blocker's +0x08 / +0x1f / +0x27
## / +0x2b bytes directly; delegating to Sacred.Pak.blob() is the only path
## that does not double-cache the whole archive.
func blob(i: int) -> PackedByteArray:
	if i <= 0 or i >= _pak.count():
		return PackedByteArray()
	return _pak.blob(i)


## Offset of nextStaticId inside the 64-byte record. A cell's WldxEntry +0x04
## names only the HEAD of a chain of statics placed at that spot; the rest
## hang off this field and were invisible to this port until 2026-08-13.
## Layout from Resacred-old rs_file.h:322-350 (PakStatic, #pragma pack(1),
## static_assert sizeof == 64), whose +0x04 itemTypeId and +0x0e/+0x12
## worldX/worldY already match what this class reads.
##
## That was an outside description until 2026-08-15. It is now pinned by two
## structural properties instead, in tools/parity/static_next_check.py:
##   1. A chain is a LINKED LIST, so links - distinct targets must be 0.
##      +0x1f scores 0 over 174,422 links in retail and over 51,224 in the
##      Armalion prerelease; the best rival that carries comparable traffic
##      has 30,973 excess over 31,031 links.
##   2. A LINKED RECORD IS NEVER A HEAD. None of those 174,422 targets is
##      among the 31,752 chain heads the world cells name -- two separate
##      files partitioning the same records between them.
const NEXT_OFF := 0x1f

## Every static in the chain starting at `i`, head first, as get_object()
## dictionaries. Empty if the head is absent. Terminates on a zero/out-of-
## range link and on a repeat, so a corrupt file cannot spin here -- the
## longest real chain measured at sector 50,39 is 14.
func chain(i: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var seen: Dictionary[int, bool] = {}
	var cur := i
	while cur > 0 and cur < _pak.count() and not seen.has(cur):
		seen[cur] = true
		var o := get_object(cur)
		if o.is_empty():
			break
		out.append(o)
		cur = _pak.blob(cur).decode_u32(NEXT_OFF)
	return out

## {type, flags, pos} for a static index, or an empty Dictionary if absent.
func get_object(i: int) -> Dictionary:
	if i <= 0 or i >= _pak.count():
		return {}
	var r := _pak.blob(i)
	if r.size() < 64:
		return {}
	return {
		"type": r.decode_u32(4),
		"flags": r.decode_u32(8),
		# Godot's Y is up, Sacred's screen Y is down.
		"pos": Vector2(r.decode_s32(0x0e), -r.decode_s32(0x12)),
	}

## The 32-bit flags word at record +0x08. Bit 0x200 marks a static as a
## walkability blocker (the same discriminator cWorld::canWalk uses on the
## static chain at a door-bit cell, rows 1148/1151). Returns 0 for an
## absent or undersized record, never -1.
func flags(idx: int) -> int:
	if idx <= 0 or idx >= _pak.count():
		return 0
	var r := _pak.blob(idx)
	if r.size() < 64:
		return 0
	return r.decode_u32(8)

## The 16-bit collision-class bitmask at record +0x2b, the field cWorld::
## canWalk reads as the per-static "object_mask" (rows 1148/1151). Returns
## 0 for an absent or undersized record -- zero intersection with any
## type mask is then the BLOCKED half of the polarity-corrected gate
## (row 1155: walkable iff (object_mask & type_mask) != 0).
func mask(idx: int) -> int:
	if idx <= 0 or idx >= _pak.count():
		return 0
	var r := _pak.blob(idx)
	if r.size() < 64:
		return 0
	return r.decode_u32(0x2b)
