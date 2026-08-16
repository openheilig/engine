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
## Layout: u32 ENTRY COUNT, then 16-byte index entries
## [name_hash, offset, 0, size], then the data. Text is UTF-16LE at offset+4 --
## the u32 AT `offset` is not the size -- and runs `size` bytes.
##
## THE FIRST u32 IS A COUNT, NOT A MAGIC. It reads as `'SZ\0\0'` only by
## coincidence: this file holds 23123 entries and 23123 == 0x00005A53. Retail's
## loader (sub_80AE930) reads it as the count and there is no signature word,
## so a `.res` of any other size failed the old check. The index is therefore
## exactly `4 + count*16` bytes long, which is asserted below.
##
## THE HASH IS 32-BIT AND IT OVERFLOWS ON PURPOSE (sub_80ACC3E, verbatim):
##
##     v = 0
##     for c in name:  v = (int32)(113*v + toupper(c)) % 999999991
##     return v & 0x7fffffff
##
## `113*v` genuinely exceeds 2^32 and WRAPS, and the `%` is x86 `idiv` -- C
## truncated division, so the remainder takes the dividend's sign and `v` goes
## negative between iterations. Both must be emulated.
##
## THIS IS WHAT THE OLD READER GOT WRONG, and the shape of the error is worth
## keeping: GDScript ints are 64-bit, so the old `(h*0x71 + c) % MOD` never
## wrapped. The two agree for exactly four characters and diverge from the
## fifth, because 113 * 1.6e6 is the first product to pass 2^31. Every key in
## the shipped files is a 3-5 digit number, so the numeric namespace resolved
## and looked like proof -- while every symbolic key, all of them longer,
## silently missed. That is why global-res.md concluded the symbolic namespace
## was absent from the install. It is not: with the wrap in place the quest
## log reads in English (findings log row 954).
##
## The final mask is why a caller may pass a NEGATIVE id: 0x084c2e06 branches
## on the sign, and a value with the sign bit set is a key that is ALREADY
## hashed.
##
## See research/formats/global-res.md.

const MOD := 0x3b9ac9f7          ## 999999991, prime
const ENTRY := 16
const WRAP := 1 << 32

var _slots: PackedStringArray
var _by_hash: Dictionary          ## name hash -> text, first entry wins

func _init(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("Resources: cannot open %s (%s)" % [path, error_string(FileAccess.get_open_error())])
		return
	var d := f.get_buffer(f.get_length())
	if d.size() < 12:
		push_error("Resources: %s is too short to be a global.res" % path)
		return
	# The first u32 is the ENTRY COUNT. Retail reads it as one and there is no
	# signature word -- see the class doc on why it looks like 'SZ'.
	var n := d.decode_u32(0)
	# The index is exactly `4 + n*16` bytes, so entry 0's data offset must be
	# `n*16`. That is a real structural check rather than a magic number: it
	# ties the count to the layout, and it is what the old 'SZ' compare only
	# appeared to do. Entry 0's text starts four bytes past that, which is why
	# the last entry's `size` field lands in front of it -- the same "u32 at
	# offset that is not the size" every payload carries. Dropping that entry
	# loses a real one: 23122 is 'Gero Wachholz'.
	if n == 0 or 4 + n * ENTRY > d.size() or d.decode_u32(8) != n * ENTRY:
		push_error("Resources: %s declares %d entries, which does not fit its index" % [path, n])
		return
	var end := 4 + n * ENTRY
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

## The engine's own key, transcribed from sub_80ACC3E. See the class doc: the
## int32 wrap and the sign-taking remainder are the whole point, not detail.
static func name_hash(name: String) -> int:
	var v := 0
	for i in name.length():
		var c := name.unicode_at(i)
		# The original walks BYTES and sign-extends each one (`movsx`). A char
		# past Latin-1 cannot have come from the byte string it hashes, so it
		# is folded to '?' rather than silently contributing a wrong number.
		if c > 0xff:
			c = 0x3f
		if c >= 0x80:
			c -= 0x100                      # movsx: bytes >= 0x80 go NEGATIVE
		elif c >= 0x61 and c <= 0x7a:
			c -= 0x20                       # toupper, C locale
		# 113*v passes 2^32 from the fifth character on, and the original lets
		# it wrap. GDScript ints are 64-bit, so the wrap must be written out.
		var t := (113 * v + c) & 0xffffffff
		if t & 0x80000000:
			t -= WRAP
		# x86 `idiv`: the remainder takes the DIVIDEND's sign, unlike GDScript's
		# `%` on negatives, so v is genuinely negative on some iterations.
		v = -((-t) % MOD) if t < 0 else t % MOD
	return v & 0x7fffffff

## `res:N` from the script bytecode. Empty for an index out of range.
func slot(n: int) -> String:
	return _slots[n] if n >= 0 and n < _slots.size() else ""

## A numeric resource id the way the engine resolves one. A NEGATIVE id is a
## key that is already hashed and is used directly after masking.
func by_id(rid: int) -> String:
	var key := (rid & 0x7fffffff) if rid < 0 else name_hash(str(rid))
	return _by_hash.get(key, "")

## Text for a SYMBOLIC key -- `DQ_BAUER_BEGRUESSUNG_LOG` and the rest of the
## namespace the script bytecode actually writes. Empty when the key is absent,
## which for a composed key (see resolve()) it always is.
func by_name(name: String) -> String:
	return _by_hash.get(name_hash(name), "")


## `res:N` as the bytecode writes it, e.g. startcode.gd's NPC "name" field.
## Anything that is not a `res:` reference comes back unchanged, because the
## same field also carries plain names.
##
## BOTH NAMESPACES ARRIVE THROUGH THIS ONE PREFIX, and which one applies is
## decided by the payload, not by the caller: a decimal payload is a SLOT
## index, anything else is a NAME to hash. `Res:DQ_BAUER_BEGRUESSUNG_LOG` is
## "The peasants need my help."
##
## A COMPOSED key -- `DQ_BRINGE_ITEM+Var(DQ_2604)+_LOG` -- is not resolved
## here and comes back unchanged, because the substituted value lives in the
## script VM's variables and this class has none. Use compose() once the
## caller knows the number; 61 templates in the Seraphim tree are built this
## way and the instantiated keys are real (`DQ_BRINGE_ITEM2_LOGTITLE` is
## "The Father's Sword.").
func resolve(ref: String) -> String:
	if not ref.to_lower().begins_with("res:"):
		return ref
	var n := ref.substr(4).strip_edges()
	if n.is_valid_int():
		return slot(n.to_int())
	if n.find("+") >= 0:
		return ref                      # composed; the caller must compose()
	var t := by_name(n)
	return t if t != "" else ref


## One composed key, instantiated. `ref` is the template as the bytecode writes
## it -- `NAME+Var(X)+SUFFIX` -- and `value` is what the VM's variable holds.
## Returns "" when the instantiated key is not in the table.
func compose(ref: String, value: int) -> String:
	var n := ref.substr(4).strip_edges() if ref.to_lower().begins_with("res:") else ref
	var open := n.find("+")
	var close := n.rfind("+")
	if open < 0 or close <= open:
		return ""
	return by_name("%s%d%s" % [n.substr(0, open), value, n.substr(close + 1)])
