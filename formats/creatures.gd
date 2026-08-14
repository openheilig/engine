extends RefCounted
## pak/creature.pak -- the creature type table (autoresearch row 693).
##
## A FLAT CIF table, not a Sacred.Pak container: the magic passes but the bytes
## at 0x100 are header, not an index, so reading it through Pak silently
## misreads it. 474 records of 86 bytes from offset 256, and
## 256 + 474*86 == 41020 == the file length is what fixes the stride.
##
## Only two fields are exposed, because only two are needed to join the spawn
## tables to the faction matrix: the id at +0x00 -- which IS the items.pak
## record index naming the creature's Granny model, so appearance needs no
## field at all -- and the class at +0x04, the 1..15 enum Sacred.Factions
## indexes by.

const DATA := 256
const REC := 86
const ID_OFF := 0
const CLASS_OFF := 4

var _class: Dictionary[int, int] = {}

func _init(pak_dir: String) -> void:
	var b := FileAccess.get_file_as_bytes(pak_dir.path_join("creature.pak"))
	if b.size() < DATA or (b.size() - DATA) % REC != 0:
		push_error("Creatures: creature.pak missing or stride broken")
		return
	for i in (b.size() - DATA) / REC:
		var o := DATA + i * REC
		_class[b.decode_u32(o + ID_OFF)] = b.decode_u16(o + CLASS_OFF)

func count() -> int:
	return _class.size()

func has(id: int) -> bool:
	return _class.has(id)

## The creature's class, or 0 for an id the table does not carry. Feed it
## straight to Sacred.Factions.hostile().
func class_of(id: int) -> int:
	return _class.get(id, 0)
