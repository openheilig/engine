extends RefCounted
const Pak := preload("res://formats/pak.gd")
## world/triggers.pak -- the world's 16-byte-record collision TYPE TABLE.
##
## Layout, measured 2026-08-13 and re-pinned by row 1156 (Armalion
## non-US sub_489A60): magic "TRG" v1 (4 bytes), u32 count @+4, an
## unrelated 0x100-byte header block at +0x100, then `count` 16-byte
## entries at +0x10c (268). Each entry:
##
##   +0x00 u32  type id (== record index)
##   +0x04 u16  kind: 16 = live, 0 = dead/erased
##   +0x06 u32  static.pak RECORD index -- the back-link (not used here)
##   +0x0a u16  16-bit type-collision mask -- the field Walkable reads
##   +0x0c u32  always 0 for live
##
## Row 1156 closed the W2 source question: the runtime table at
## world+0x388 is the 16-byte verbatim copy of THIS file -- no arithmetic,
## so the file is the authority. The Walkable path only needs +0xa, which
## is why this reader exposes just mask(type_id).

const HDR := 0x10c
const REC := 16
const MASK_OFF := 0x0a

var _f: FileAccess
var count: int = 0

func _init(path: String) -> void:
	_f = FileAccess.open(Pak.resolve(path), FileAccess.READ)
	if _f == null:
		push_error("TriggerType: cannot open %s" % path)
		return
	var magic := _f.get_buffer(4).get_string_from_ascii()
	if magic.substr(0, 3) != "TRG":
		push_error("TriggerType: %s has bad magic %s" % [path, magic])
		_f = null
		return
	_f.seek(4)
	count = _f.get_32()


func is_open() -> bool:
	return _f != null


## 16-bit type-collision mask for `type_id`, or 0 if the reader is not
## loaded or the id is out of range. Zero on a missing id is the same
## answer the cWorld::canWalk assembly gives through its out-of-range
## path: zeroed masks block by intersection, which matches what retail
## does for type ids retail never assigned.
func mask(type_id: int) -> int:
	if _f == null or type_id < 0 or type_id >= count:
		return 0
	_f.seek(HDR + type_id * REC + MASK_OFF)
	return _f.get_16()
