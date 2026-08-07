class_name RetailCursor
extends RefCounted
## Sacred's own mouse pointer, read from the retail install at runtime.
##
## texture.pak carries 30 MOUSE_*.TGA entries: the main pointer, the eight
## edge-scroll direction arrows (MOUSE_DIRN/NE/E/...), and context cursors for
## traders, blacksmiths, stairs, dialogue, riding and combos. Only the main
## pointer is wired up here -- the rest need the gameplay systems that decide
## WHEN to show them, so they belong to the phases that add those systems.
##
## The art is a 64x64 power-of-two texture with the pointer occupying the
## top-left 32x32; the remaining three quarters are fully transparent. The tip
## sits at exactly pixel (0,0), so the hotspot is the origin -- verified by
## dumping the alpha channel, not assumed from the shape.
##
## ponytail: no caching of the id. The scan is measured at boot and printed as
## `cursor  <name>  id=N  <ms>ms`; if that number ever becomes uncomfortable the
## upgrade path is a user:// cache keyed on the pak's size+mtime, not a
## hardcoded index (which would silently break on a differently-built install).

const NAME := "MOUSE_MAIN.TGA"

## texture.pak blob names occupy a NUL-padded 32-byte field at the start of the
## entry. Sacred.Pak.blob()'s `extra` parameter exists because this header lies
## OUTSIDE the index's recorded size.
const NAME_FIELD := 32

## The opaque region of the 64x64 source. Cropping keeps hotspot coordinates
## unchanged (the content starts at 0,0), and hands the OS a 32x32 cursor
## instead of one that is three-quarters empty.
const SIZE := 32


## Installs Sacred's pointer as the OS cursor. Returns true on success.
##
## Never fatal, by design: this is cosmetic, and a retail install that is
## missing or has a differently-named entry must not stop the engine booting.
## On any failure the platform default cursor stays, and the caller prints why.
static func apply(tex_pak: Sacred.Pak) -> bool:
	if tex_pak == null or not tex_pak.is_open():
		return false
	var t0 := Time.get_ticks_usec()
	var id := find_named(tex_pak, NAME)
	if id < 0:
		push_warning("RetailCursor: %s not found in texture.pak; keeping default cursor" % NAME)
		return false
	var img := Sacred.decode_texture(tex_pak, id)
	if img == null:
		push_warning("RetailCursor: %s (id %d) failed to decode; keeping default cursor" % [NAME, id])
		return false
	if img.get_width() < SIZE or img.get_height() < SIZE:
		push_warning("RetailCursor: %s is %dx%d, smaller than the expected %dx%d"
			% [NAME, img.get_width(), img.get_height(), SIZE, SIZE])
		return false
	Input.set_custom_mouse_cursor(
		ImageTexture.create_from_image(img.get_region(Rect2i(0, 0, SIZE, SIZE))),
		Input.CURSOR_ARROW, Vector2.ZERO)
	print("cursor\t%s\tid=%d\t%.1fms" % [NAME, id, (Time.get_ticks_usec() - t0) / 1000.0])
	return true


## Restores the platform cursor, releasing the texture handed to the Input
## singleton. Call before shutdown.
##
## Not optional housekeeping: Input keeps the ImageTexture alive past
## RenderingServer teardown, so skipping this leaks its RID at exit. MEASURED,
## not assumed -- a windowed --quit-after run with the cursor applied printed
## `2 RIDs of type "Texture" were leaked`, and the identical run with the
## RetailCursor.apply() call removed printed no leak lines at all.
static func clear() -> void:
	Input.set_custom_mouse_cursor(null, Input.CURSOR_ARROW)


## texture.pak has no name index, so this is a linear scan reading the 32-byte
## name field of each entry. Exact match on the NUL-terminated name, NOT a
## prefix compare: a prefix would let a longer entry sharing the same opening
## characters win.
static func find_named(pak: Sacred.Pak, name: String) -> int:
	var want := name.to_ascii_buffer()
	var n := want.size()
	if n <= 0 or n >= NAME_FIELD:
		return -1
	for i in pak.count():
		var raw := pak.read_at(pak.entry_offset(i), NAME_FIELD)
		if raw.size() < n + 1 or raw[n] != 0:
			continue
		if raw.slice(0, n) == want:
			return i
	return -1
