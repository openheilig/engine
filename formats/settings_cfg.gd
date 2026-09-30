class_name SettingsCfg
extends RefCounted
## U1: the retail per-user settings file (~/.lgp/sacred/settings.cfg --
## LF, "KEY : VALUE" lines; the template in the install is CRLF and the
## game copies it on first run). The port honours the user's retail
## preferences at launch instead of ignoring them: SOUND, FULLSCREEN and
## the keys with known semantics (55+ named in
## research/formats/generated/settings-cfg-keys.tsv).

var values: Dictionary[String, String] = {}
var found := false


func _init(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	while not f.eof_reached():
		var line := f.get_line()
		var sep := line.find(":")
		if sep <= 0:
			continue
		values[line.substr(0, sep).strip_edges()] = line.substr(sep + 1).strip_edges()
	found = values.size() > 0


func int_value(key: String, fallback: int) -> int:
	if not values.has(key):
		return fallback
	return int(values[key])


## FULLSCREEN: 1 -> start in fullscreen (the retail config beats the
## command line in retail; here the flag wins if given, else this applies).
func wants_fullscreen() -> bool:
	return int_value("FULLSCREEN", 0) == 1


## SOUND: 0 -> the retail user muted audio; the port starts muted too.
func wants_sound() -> bool:
	return int_value("SOUND", 1) == 1
