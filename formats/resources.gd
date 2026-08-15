extends RefCounted
## scripts/<lang>/global.res -- every piece of text the engine shows.
##
## ONE CONTAINER, TWO NAMESPACES, and conflating them is the trap:
##
##   BY SLOT.  `res:N` in the script bytecode is the N'th index entry. This is
##   what startcode.gd's tag 0x01 carries -- an NPC's display name.
##
##   BY NAME.  Everything inside the engine reaches the same tree through a
##   HASH of a resource's NAME, which is the entry's first u32. A caller
##   holding a number prints it to decimal first, so resource 9400 is the entry
##   whose name hashes like the four characters "9400" -- 'Heavenly Magic'.
##
## The two disagree completely: slot 9400 is quest prose about an antidote at
## Faeries Crossing, resource 9400 is 'Heavenly Magic'.
##
## Layout: u32 'SZ', then 16-byte index entries [name_hash, offset, 0, size],
## then the data. Text is UTF-16LE at offset+4 -- the u32 AT `offset` is not
## the size -- and runs `size` bytes. Entry 0's offset is where the index ends.
##
## The hash is the engine's own, at 0x080ae4d2:
##     h = 0; for c in name: h = (h*0x71 + toupper(c)) % 0x3b9ac9f7
##     return h & 0x7fffffff
## The mask is why a caller may pass a NEGATIVE id: 0x084c2e06 branches on the
## sign, and a value with the sign bit set is a key that is ALREADY hashed.
##
## See research/formats/global-res.md.

const MOD := 0x3b9ac9f7          ## 999999991, prime
const ENTRY := 16

var _slots: PackedStringArray
var _by_hash: Dictionary          ## name hash -> text, first entry wins

func _init(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("Resources: cannot open %s (%s)" % [path, error_string(FileAccess.get_open_error())])
		return
	var d := f.get_buffer(f.get_length())
	if d.size() < 12 or d.decode_u16(0) != 0x5a53:      # 'SZ'
		push_error("Resources: %s is not a global.res" % path)
		return
	# Entry 0's data offset is NOT where the index ends -- it is four bytes
	# short of it, and (first - 4) is not even a multiple of 16. The index runs
	# to `first + 4`, so the count is `first / 16` exactly (23123 here). The
	# last entry's `size` field therefore lands on the four bytes that sit in
	# front of entry 0's text, which is the same "u32 at offset that is not the
	# size" every payload carries. Dropping it loses a real entry: 23122 is
	# 'Gero Wachholz'.
	var first := d.decode_u32(8)
	var end := first + 4
	var i := 4
	while i + ENTRY <= end:
		var h := d.decode_u32(i)
		var off := d.decode_u32(i + 4)
		var size := d.decode_u32(i + 12)
		var text := ""
		if off + 4 + size <= d.size():
			text = d.slice(off + 4, off + 4 + size).get_string_from_utf16()
		_slots.append(text)
		if not _by_hash.has(h):
			_by_hash[h] = text                          # first wins, as the tree does
		i += ENTRY

func count() -> int:
	return _slots.size()

## The engine's own key. `name` is a resource's name, which in every shipped
## file is a decimal integer -- see global-res.md on why nothing is word-named.
static func name_hash(name: String) -> int:
	var h := 0
	for c in name.to_upper():
		h = (h * 0x71 + c.unicode_at(0)) % MOD
	return h & 0x7fffffff

## `res:N` from the script bytecode. Empty for an index out of range.
func slot(n: int) -> String:
	return _slots[n] if n >= 0 and n < _slots.size() else ""

## A numeric resource id the way the engine resolves one. A NEGATIVE id is a
## key that is already hashed and is used directly after masking.
func by_id(rid: int) -> String:
	var key := (rid & 0x7fffffff) if rid < 0 else name_hash(str(rid))
	return _by_hash.get(key, "")

## `res:N` as the bytecode writes it, e.g. startcode.gd's NPC "name" field.
## Anything that is not a `res:` reference comes back unchanged, because the
## same field also carries plain names.
func resolve(ref: String) -> String:
	if not ref.to_lower().begins_with("res:"):
		return ref
	var n := ref.substr(4).strip_edges()
	return slot(n.to_int()) if n.is_valid_int() else ref
