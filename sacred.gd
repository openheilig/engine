class_name Sacred
extends RefCounted
## The `Sacred` namespace: where the retail install is, and one name for every
## reader in formats/.
##
## Nothing here copies, caches or ships a retail byte -- every read seeks into
## the user's own install. See AGENTS.md "Working in godot-port/".
##
## Formats (recovered in analysis/, see RESEARCH and autoresearch-results.tsv):
##   *.pak          256 B header, u32 count @4, index @0x100 of {u32 flags, u32 off, u32 size}
##   tiles.pak      64 B records: name[32], u32 texture id @0x20, u32 orientation @0x24
##   texture.pak    80 B image header: name[32], u16 w @32, u16 h @34, u8 type @36; then zlib
##   sectors.keyx   "WLK" v5, u32 count @4, u32 w @8, u32 h @12; 768 B records from 0x100
##   sectors.wldx   "WLD" v5; zlib streams located by keyx, NOT by scanning

## The readers themselves live in formats/, one file per format. This file
## is their namespace: every Sacred.Pak, Sacred.SECT and Sacred.find_install
## call site keeps working unchanged, and nothing here decodes anything.

const Common := preload("res://formats/common.gd")
const TextureFormat := preload("res://formats/texture.gd")

## Layout constants -- re-exported from formats/common.gd.
const SECT := Common.SECT
const TILE := Common.TILE
const CELL := Common.CELL
const NAME := Common.NAME
const PAK_HDR := Common.PAK_HDR
const PAK_IDX := Common.PAK_IDX
const KEY_HDR := Common.KEY_HDR
const KEY_REC := Common.KEY_REC
const KEY_COORD := Common.KEY_COORD
const KEY_OFF := Common.KEY_OFF
const KEY_CSIZE := Common.KEY_CSIZE
const KEY_DSIZE := Common.KEY_DSIZE

## Atlas geometry -- re-exported from formats/texture.gd.
const SLOT_COUNT := TextureFormat.SLOT_COUNT
const SLOT_W := TextureFormat.SLOT_W
const SLOT_H := TextureFormat.SLOT_H
const SLOT_DX := TextureFormat.SLOT_DX
const SLOT_DY := TextureFormat.SLOT_DY
const SLOT_STAGGER := TextureFormat.SLOT_STAGGER
const ATLAS := TextureFormat.ATLAS
const SLOT_INSET := TextureFormat.SLOT_INSET

## The readers.
const Pak := preload("res://formats/pak.gd")
const Tiles := preload("res://formats/tiles.gd")
const World := preload("res://formats/world.gd")
const Statics := preload("res://formats/statics.gd")
const Mixed := preload("res://formats/mixed.gd")
const Regions := preload("res://formats/regions.gd")
const Footprints := preload("res://formats/footprints.gd")
const Items := preload("res://formats/items.gd")
const Models := preload("res://formats/models.gd")
const Pax := preload("res://formats/pax.gd")
const Funk := preload("res://formats/funk.gd")
const Startcode := preload("res://formats/startcode.gd")
const Factions := preload("res://formats/factions.gd")
const Creatures := preload("res://formats/creatures.gd")
const Rigs := preload("res://formats/rigs.gd")
const Armour := preload("res://formats/armour.gd")


const CFG := "user://openheilig.cfg"


## Resolves the retail install directory. Order: --install=PATH on the command
## line, then user://openheilig.cfg (falling back to the pre-rename
## user://opensacred.cfg), then the workspace sibling. Returns "" if none of
## them holds a real install.
##
## A path given with --install= is remembered, so it is needed once and not on
## every run. Nothing else writes the config.
static func find_install() -> String:
	var cli := _cli_install()
	if cli != "" and is_install(cli):
		save_install(cli)
		return cli
	for candidate in [_cfg_install(), _sibling_install()]:
		if candidate != "" and is_install(candidate):
			return candidate
	return ""


## An install is anything that has the two files the terrain reader needs.
static func is_install(path: String) -> bool:
	return FileAccess.file_exists(path.path_join("pak/tiles.pak")) \
		and FileAccess.file_exists(path.path_join("world/sectors.wldx"))


static func save_install(path: String) -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("game", "install_path", path)
	cfg.save(CFG)


static func _cli_install() -> String:
	for arg in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if arg.begins_with("--install="):
			return arg.trim_prefix("--install=").simplify_path()
	return ""


static func _cfg_install() -> String:
	# The 2026-08-14 OpenSacred -> OpenHeilig rename changed config/name, which
	# moves user:// to a different app_userdata directory. So the pre-rename
	# config is not at user://opensacred.cfg — it is in the sibling directory.
	# ponytail: read-only, never written back. Drop it once nobody is still
	# carrying a config from before the rename.
	var old := ProjectSettings.globalize_path("user://") \
		.path_join("../OpenSacred/opensacred.cfg").simplify_path()
	for name in [CFG, old]:
		var cfg := ConfigFile.new()
		if cfg.load(name) != OK:
			continue
		var path := str(cfg.get_value("game", "install_path", ""))
		if path != "":
			return path
	return ""


static func _sibling_install() -> String:
	return ProjectSettings.globalize_path("res://").path_join("../install").simplify_path()



## zlib inflate, on formats/common.gd.
static func inflate(z: PackedByteArray, out_size: int) -> PackedByteArray:
	return Common.inflate(z, out_size)


## Normalised UV rect of atlas slot n, on formats/texture.gd.
static func slot_uv(n: int) -> Rect2:
	return TextureFormat.slot_uv(n)


## Decodes one texture.pak entry, on formats/texture.gd.
static func decode_texture(pak: Pak, id: int, render: bool = false) -> Image:
	return TextureFormat.decode_texture(pak, id, render)
