extends RefCounted
## The creature-class friend/foe matrix, 16x16 bytes (autoresearch row 735).
##
## It lives in the ENGINE BINARY, not in a data file: 256 bytes of .rodata that
## the engine memcpys into .data at startup and indexes as
## `matrix[16 * A.class + B.class]`, class being the creature's field at +0x1f0
## and the same 1..15 enum creature.pak uses (1 Held, 2 Monster, 3 NPC,
## 4 Pferd, 5 Untoter, 6 Tier, 7 Soeldner, 8 Goblinoide, 9 Daemon, 10 Drache,
## 11 Energiewesen, 12 Elf, 13 Feind, 14 Mensch, 15 Dryade). 1 means friendly,
## 0 hostile.
##
## It is FOUND BY ITS OWN SHAPE, not by a hardcoded offset: the retail builds do
## not agree on where it sits (0x6b04e0 in install/sacred, 0x6b7180 in
## sacred_orig), and a wrong offset would silently yield a plausible-looking
## table of zeros and ones. The search below matches exactly one window in each
## of the three binaries tested.
##
## ponytail: read-only, and nothing consumes it yet -- creatures cannot be drawn
## until GRN animation is solved. It is here so the rule lives in one place when
## they can.

const N := 16
const FEIND := 13          ## the enum's unused class: hostile to everything
const CLASS_NAMES := ["", "Held", "Monster", "NPC", "Pferd", "Untoter",
	"Tier", "Soeldner", "Goblinoide", "Daemon", "Drache", "Energiewesen",
	"Elf", "Feind", "Mensch", "Dryade"]
## Binaries to look in, in order. The install ships the patched `sacred`;
## `sacred_orig` is this project's pristine copy and is tried second.
const BINARIES := ["sacred", "sacred_orig"]

var found := false
var source := ""           ## which binary it came from
var offset := -1           ## byte offset within that binary
var _m := PackedByteArray()

func _init(install: String) -> void:
	for name in BINARIES:
		var path := install.path_join(name)
		if not FileAccess.file_exists(path):
			continue
		var b := FileAccess.get_file_as_bytes(path)
		var off := _scan(b)
		if off >= 0:
			_m = b.slice(off, off + N * N)
			found = true
			source = name
			offset = off
			return

## The identifying shape, cheapest test first: a 16-byte-aligned window of
## nothing but 0 and 1, whose class-13 row is entirely zero (including its
## own diagonal cell) while every other diagonal cell is 1. One window in
## the whole binary satisfies it.
func _scan(b: PackedByteArray) -> int:
	var off := 0
	var last := b.size() - N * N
	while off <= last:
		if b[off] == 1 and b[off + FEIND * N + FEIND] == 0:
			var ok := true
			for i in N:
				if i != FEIND and b[off + i * N + i] != 1:
					ok = false
					break
				if b[off + FEIND * N + i] != 0:
					ok = false
					break
			if ok:
				for i in N * N:
					if b[off + i] > 1:
						ok = false
						break
			if ok:
				return off
		off += 16
	return -1

## True when a creature of class `a` treats one of class `b` as an enemy.
## Not symmetric, and deliberately so: nine of the eleven asymmetric pairs
## involve Pferd, because enemies ignore the horse and attack its rider.
func hostile(a: int, b: int) -> bool:
	if not found or a < 0 or b < 0 or a >= N or b >= N:
		return false
	return _m[a * N + b] == 0

func row(a: int) -> PackedByteArray:
	return _m.slice(a * N, a * N + N) if found else PackedByteArray()
