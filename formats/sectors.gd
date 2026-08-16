extends RefCounted
## `world/sectors.keyx` -- the per-sector ENVIRONMENT record, and with it the
## answer to a standing open question: what selects the music and atmosphere as
## the player moves (row 960).
##
## It is neither `sndprofiles.pak` nor a script opcode at runtime. Each sector
## carries a 256-byte `cSectorEnvironment` block naming its music directly, and
## `sub_80DB27C` reads it when the player's current sector changes:
##
##     env = world.sectors[id].env
##     if env and env.music:
##         cMSS::receive_event(mss, 2, 0, env.region, env.music, sector.climate, ...)
##     if env.atmo2:
##         sub_84C9342(mss, env.atmo2)
##
## The chooser `sub_84EADBA` then combines music id, CLIMATE and the day/night
## phase into an `SOUND_FX_ATMO_*` id -- climate 32 is desert, 96 ice, 48/64/80
## volcano, 16 and 240 dungeon -- which is why climate is read here beside the
## music rather than left in the terrain layer.
##
## THE STRIDE IS NOT A FIT. `256 + 6050 * 768` is 4,646,656, which is the file
## length exactly, and every one of the 6050 records lands on a DISTINCT sector
## coordinate. A wrong stride gives neither.
##
## `sndprofiles.pak` is ruled out and is a different system: its only reader
## (`sub_813655C`) picks `tbl[profile].group[slot][rand()%8]`, the per-creature
## combat sound variation sets.
##
## WHAT IS NOT READ HERE: the eight neighbour ids at `+0x2C`, and the 256-byte
## environment block's other 248 bytes. Only the three fields with a recovered
## meaning are exposed, because a reader that returns bytes nobody can name is
## an invitation to invent one.

const HEADER := 256
const REC := 768
const O_INDEX := 0x24           ## u32 sector index, retail's own numbering
const O_X := 0x3C               ## i32 raw X; cell = (raw + 25) * 0.0186339
const O_Y := 0x40
const O_CLIMATE := 0x1D8        ## u8; feeds the day/night atmosphere table
const O_ENV := 0x1E9            ## the 256-byte cSectorEnvironment
const O_REGION := O_ENV + 0xD7  ## u8
const O_MUSIC := O_ENV + 0xEF   ## u32 SOUND_FX_* id, 0 when the sector sets none
const O_ATMO2 := O_ENV + 0xF3   ## u32 secondary atmosphere id
## Retail's own conversion from the stored integer to a world cell. The +25 and
## the reciprocal are the binary's, not a fit.
const CELL_SCALE := 0.0186339
const CELL_BIAS := 25.0

var found := false
var count := 0
var _b := PackedByteArray()
var _by_sector: Dictionary[Vector2i, int] = {}   ## sector -> record index


## Vector2i, not a packed int. `sx * 1000 + sy` is only injective for
## 0 <= sy < 1000, and `cell / SECT` truncates TOWARDS ZERO in GDScript so
## cells -1 and +1 both land in sector 0 -- two ways for two sectors to
## collide and silently overwrite each other. Godot hashes Vector2i natively.
static func key_of(sx: int, sy: int) -> Vector2i:
	return Vector2i(sx, sy)


## The sector containing a world cell -- retail's sector-change path needs this
## and it is the one place the truncation trap above can bite a caller.
##
## floori, NOT `int(cell) / SECT`: integer division truncates TOWARDS ZERO, so
## cells -1 and +1 both give sector 0 and a westward step across the origin is
## not seen as a change. Every in-world cell is positive and the two agree
## there, which is exactly why the wrong one survives testing.
static func sector_of(cell: Vector2) -> Vector2i:
	return Vector2i(
		floori(cell.x / float(Sacred.SECT)),
		floori(cell.y / float(Sacred.SECT)))


func _init(install: String) -> void:
	_b = FileAccess.get_file_as_bytes(install.path_join("world/sectors.keyx"))
	if _b.size() < HEADER + REC:
		push_warning("Sectors: world/sectors.keyx is unreadable")
		return
	var n := _b.decode_u32(4)
	# The count and the stride must account for the whole file. This is the
	# structural check; without it a plausible-looking stride reads garbage
	# fields out of the middle of records.
	if HEADER + n * REC != _b.size():
		push_warning("Sectors: %d records of %d do not fill %d bytes" % [n, REC, _b.size()])
		return
	count = n
	for i in n:
		var o := HEADER + i * REC
		var cx := int(round((float(_b.decode_s32(o + O_X)) + CELL_BIAS) * CELL_SCALE))
		var cy := int(round((float(_b.decode_s32(o + O_Y)) + CELL_BIAS) * CELL_SCALE))
		var key := key_of(cx / Sacred.SECT, cy / Sacred.SECT)
		# The class doc claims every record lands on a DISTINCT sector. Check it
		# rather than state it: a collision would silently keep the last writer.
		if _by_sector.has(key):
			push_warning("Sectors: %s claimed by records %d and %d" % [key, _by_sector[key], i])
		_by_sector[key] = i
	found = count > 0


## Record index for a sector, or -1. Every one of the 6050 sectors is present
## exactly once, so a miss means the coordinate is off the map.
func index_of(sx: int, sy: int) -> int:
	return _by_sector.get(key_of(sx, sy), -1)


func _u8(rec: int, off: int) -> int:
	if rec < 0 or rec >= count:
		return 0
	return _b[HEADER + rec * REC + off]


func _u32(rec: int, off: int) -> int:
	if rec < 0 or rec >= count:
		return 0
	return _b.decode_u32(HEADER + rec * REC + off)


## The `SOUND_FX_*` music id a sector declares, or 0 when it declares none.
## 1892 of the 6050 sectors carry 0 and inherit whatever is already playing --
## that is retail's own `if (env->music)` guard, not a decode failure.
func music(sx: int, sy: int) -> int:
	return _u32(index_of(sx, sy), O_MUSIC)


## The climate/terrain code, which selects the day and night atmosphere. All
## twelve values observed are multiples of 16.
func climate(sx: int, sy: int) -> int:
	return _u8(index_of(sx, sy), O_CLIMATE)


func region(sx: int, sy: int) -> int:
	return _u8(index_of(sx, sy), O_REGION)


func atmo2(sx: int, sy: int) -> int:
	return _u32(index_of(sx, sy), O_ATMO2)


## Retail's own sector index, which is NOT the record's position in the file.
func sector_index(sx: int, sy: int) -> int:
	return _u32(index_of(sx, sy), O_INDEX)


## Everything named, for one sector, as a Dictionary. Empty when absent.
func env_of(sx: int, sy: int) -> Dictionary:
	var i := index_of(sx, sy)
	if i < 0:
		return {}
	return {
		"index": _u32(i, O_INDEX),
		"climate": _u8(i, O_CLIMATE),
		"region": _u8(i, O_REGION),
		"music": _u32(i, O_MUSIC),
		"atmo2": _u32(i, O_ATMO2),
	}
