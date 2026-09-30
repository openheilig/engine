class_name SoundNames
extends RefCounted
## A0: the retail sound-id to name table, recovered from the Linux 1.0.02
## binary's static table at .data 0x879AC80 ({int32 id; char name[64]},
## 6869 records; entry 0 = SOUND_FX_INVALID). This file transcribes the
## sector-music subset (ids 6500-6574 and 6700-6717); the full table is
## mechanical to extend. See tmp/a0-music/notes.md for the proof.
##
## cMSS::playMusic builds the audio path as: strip "SOUND_FX_", append
## ".ogg", the pack-aware fopen wrapper lowercases the whole path -- so
## the file is mp3/<name-without-prefix-lowercase>.ogg relative to the
## install root.

const PREFIX := "SOUND_FX_"

## id -> name-without-prefix (the ogg stem, uppercase as shipped in the
## binary; lowercase it for the on-disk file).
const TABLE := {
	6500: "ATMO_DESERT", 6501: "ATMO_ICE", 6502: "ATMO_VULCANO",
	6503: "ATMO_WOOD", 6504: "ATMOSPOT_CEMETERY", 6505: "MUSIC_DEATH",
	6506: "MUSIC_MENU",
	6507: "ATMO_VILLAGE_SIEGE_MILITARY_SUMMER",
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


## Retail's path for id: mp3/<stem lowercase>.ogg, or "" for an unknown id
## (getSndName returns 0; playMusic then plays nothing rather than failing).
static func ogg_relpath(id: int) -> String:
	var stem: String = TABLE.get(id, "")
	if stem.is_empty():
		return ""
	return "mp3/%s.ogg" % stem.to_lower()


## True for the ambience families; retail branches on memcmp(name+9,"ATMO",4)
## (index 9 skips the SOUND_FX_ prefix), which matches both ATMO_* and
## ATMOSPOT_* -- to pick the ambience volume instead of the music volume.
static func is_atmo(id: int) -> bool:
	var stem: String = TABLE.get(id, "")
	return stem.begins_with("ATMO")
