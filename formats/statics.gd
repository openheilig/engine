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

## Offset of nextStaticId inside the 64-byte record. A cell's WldxEntry +0x04
## names only the HEAD of a chain of statics placed at that spot; the rest
## hang off this field and were invisible to this port until 2026-08-13.
## Layout from Resacred-old rs_file.h:322-350 (PakStatic, #pragma pack(1),
## static_assert sizeof == 64), whose +0x04 itemTypeId and +0x0e/+0x12
## worldX/worldY already match what this class reads.
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
