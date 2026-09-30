class_name SacredSoundNames
extends RefCounted
## A0: the retail sound-id table, read at RUNTIME from the user's own
## install/sacred -- never shipped. The binary carries a static
## { int32 id; char name[64] } array, 6869 records, at .data vaddr
## 0x879AC80 (Linux 1.0.02; entry 0 = SOUND_FX_INVALID; ids are not
## indexes). Proof and addresses: tmp/a0-music/notes.md.
##
## cMSS::playMusic (sub_84E78C0) builds the audio path as: strip the
## "SOUND_FX_" prefix, append ".ogg"; the pack-aware fopen wrapper
## (sub_85FE454) lowercases the whole path -- so id N plays
## mp3/<stem-lowercase>.ogg under the install root.

const PREFIX := "SOUND_FX_"
const TABLE_VADDR := 0x879AC80
const RECORD := 68
const COUNT := 6869

## Fallback subset (sector-music ids) transcribed from the same table;
## used only when the runtime parse fails (e.g. a non-1.0.02 binary whose
## table address differs -- the X1/X2 compat pass owns that).
const FALLBACK := {
	6500: "ATMO_DESERT", 6501: "ATMO_ICE", 6502: "ATMO_VULCANO",
	6503: "ATMO_WOOD", 6504: "ATMOSPOT_CEMETERY", 6505: "MUSIC_DEATH",
	6506: "MUSIC_MENU", 6507: "ATMO_VILLAGE_SIEGE_MILITARY_SUMMER",
	6508: "ATMOSPOT_ARENA_INDOOR", 6509: "ATMOSPOT_ARENA_OUTDOOR",
	6510: "MUSIC_DESERT01", 6511: "ATMO_DUNGEON",
	6512: "ATMO_DESERT_NIGHT", 6513: "ATMO_ICE_NIGHT",
	6514: "ATMO_VULCANO_NIGHT", 6515: "ATMO_WOOD_NIGHT",
	6516: "ATMO_DUNGEON_NIGHT",
	6517: "ATMO_VILLAGE_SIEGE_MILITARY_WINTER", 6518: "MUSIC_PUB",
	6520: "MUSIC_DUNGEON01", 6521: "MUSIC_DUNGEON02",
	6522: "MUSIC_DUNGEON03", 6523: "MUSIC_DUNGEON04",
	6524: "JINGLE_AIR", 6525: "JINGLE_EARTH", 6526: "JINGLE_SPACE",
	6527: "JINGLE_FIRE", 6528: "JINGLE_WATER",
	6530: "MUSIC_FIGHT01", 6531: "MUSIC_FIGHT02", 6532: "MUSIC_FIGHT03",
	6533: "MUSIC_FIGHT04", 6534: "MUSIC_FIGHT05", 6535: "MUSIC_FIGHT06",
	6536: "MUSIC_FIGHT07", 6538: "MUSIC_ARENA01", 6540: "MUSIC_LAVA01",
	6541: "JINGLE_FANFARE01", 6542: "JINGLE_FANFARE02",
	6543: "JINGLE_FANFARE03", 6544: "MUSIC_MASCARELL",
	6545: "MUSIC_BEFORE_ENDFIGHT", 6546: "MUSIC_KING_IS_DEAD",
	6547: "MUSIC_KILLING_DEMORDEY", 6548: "MUSIC_ENTER_KHORADNUR",
	6549: "MUSIC_FIGHT_GIANTSPIDER", 6550: "MUSIC_VILLAGE01",
	6551: "MUSIC_VILLAGE_SIEGE_MILITARY",
	6552: "MUSIC_VILLAGE_SIEGE_UNDEAD",
	6553: "MEETDEMORDREY", 6554: "MEETSHADDAR", 6555: "MEETSHAREEFA",
	6556: "MEETVALOR", 6557: "MEETVILYA",
	6558: "MUSIC_DEMON_ENDFIGHT",
	6560: "MUSIC_WOOD01", 6561: "MUSIC_WOOD02", 6562: "MUSIC_WOOD03",
	6563: "MUSIC_ICE01", 6564: "MUSIC_FIGHT09", 6565: "MUSIC_FIGHT10",
	6569: "MUSIC_WRONGLEVEL",
	6570: "JINGLE_FIGHT_OVER01", 6571: "JINGLE_FIGHT_OVER02",
	6572: "JINGLE_FIGHT_OVER03", 6573: "JINGLE_FIGHT_OVER04",
	6574: "JINGLE_FIGHT_OVER05",
	6700: "MENU_ADDON", 6701: "MUSIC_PILZWALD", 6702: "MUSIC_HAUPTSTADT",
	6703: "MUSIC_NUKNUK", 6704: "MUSIC_KARIBIK", 6705: "MUSIC_DRYADEN",
	6706: "MUSIC_WAYTOHELL", 6707: "MUSIC_HELL",
	6708: "MUSIC_FIGHT_KARIBIK", 6709: "MUSIC_FIGHT_NUKNUK",
	6710: "MUSIC_DUNGEON_PIRATEN", 6711: "ATMO_KARIBIK",
	6712: "ATMO_PILZWALD", 6713: "ATMO_HELL",
	6714: "MUSIC_DUNGEON_NUKNUK", 6715: "MUSIC_PIRATENPUB",
	6716: "MUSIC_DUNGEON_KARIBIK", 6717: "MUSIC_KARIBIK_NETT",
}

static var _cache: Dictionary = {}
static var _loaded := false


## The full id -> stem table (stem = name minus SOUND_FX_, uppercase as
## shipped). Reads install/sacred's PT_LOAD segments once; falls back to
## the transcribed subset if the binary is missing or shaped differently.
static func table(install: String) -> Dictionary:
	if _loaded:
		return _cache
	_loaded = true
	var parsed := _parse_binary(install.path_join("sacred"))
	# Entry 0 (SOUND_FX_INVALID) and any non-positive ids are filtered, so
	# accept anything close to the full 6869 rather than demanding an exact
	# filtered count.
	_cache = parsed if parsed.size() >= COUNT - 16 else FALLBACK.duplicate()
	return _cache


## ELF32: find the PT_LOAD covering TABLE_VADDR, translate to a file
## offset, read COUNT records of {i32 id; char[64] name}.
static func _parse_binary(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	# Magic + class/data/version bytes; EI_OSABI is 3 (Linux) in this
	# binary, so bytes 4-7 read 0x03010101, not the textbook 0x00010101.
	if f.get_32() != 0x464C457F or (f.get_32() & 0x00FFFFFF) != 0x00010101:
		return {}
	f.seek(28)
	var phoff := f.get_32()
	f.seek(42)
	var phentsize := f.get_16()
	var phnum := f.get_16()
	var file_off := -1
	for i in phnum:
		f.seek(phoff + i * phentsize)
		var p_type := f.get_32()
		var p_offset := f.get_32()
		var p_vaddr := f.get_32()
		f.get_32()  # p_paddr
		var p_filesz := f.get_32()
		var p_memsz := f.get_32()
		if p_type == 1 and p_vaddr <= TABLE_VADDR and TABLE_VADDR < p_vaddr + p_memsz:
			if TABLE_VADDR - p_vaddr >= p_filesz:
				return {}  # BSS-only coverage: the table would not be in the file.
			file_off = p_offset + (TABLE_VADDR - p_vaddr)
			break
	if file_off < 0:
		return {}
	var out: Dictionary = {}
	f.seek(file_off)
	for i in COUNT:
		var id := f.get_32()  # signed, but ids are positive
		var raw := f.get_buffer(64)
		var z := raw.find(0)
		var name := raw.slice(0, z if z >= 0 else 64).get_string_from_ascii()
		if id > 0 and not name.is_empty():
			out[id] = name.trim_prefix(PREFIX)
	return out


## Retail's path for id: mp3/<stem lowercase>.ogg, or "" for an unknown id
## (getSndName returns 0; playMusic then plays nothing rather than failing).
static func ogg_relpath(id: int, install: String) -> String:
	var stem: String = table(install).get(id, "")
	if stem.is_empty():
		return ""
	return "mp3/%s.ogg" % stem.to_lower()


## True for the ambience families; retail branches on memcmp(name+9,"ATMO",4)
## (index 9 skips the SOUND_FX_ prefix), which matches both ATMO_* and
## ATMOSPOT_* -- to pick the ambience volume instead of the music volume.
static func is_atmo(id: int, install: String) -> bool:
	var stem: String = table(install).get(id, "")
	return stem.begins_with("ATMO")
