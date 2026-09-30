extends RefCounted
## Per-sector REGION table: building footprints with their own interior grids.
##
## Layout, immediately after the cell array (NAME + 64*64*32 = 131104):
##   36-byte records, ending at the first record whose type field is not 6.
##     +0x00 u32  region cell x   (absolute, inside the owning sector)
##     +0x04 u32  region cell y
##     +0x08 u16  w      +0x0a u16  h
##     +0x0c u32  type   (always 6; scanning for it returns exactly 2231 records
##                        world-wide, independently matching a coordinate-anchored
##                        count, which is what confirms the stride)
##     +0x10 u32  offset of this region's grid, relative to the DECOMPRESSED
##                STREAM -- not to the table, and not to the cell array
##     +0x14 u32  grid byte size, always exactly w*h*32
##     (remainder of the 36 bytes is zero padding)
##
## The grid is w*h cells of 32 bytes, of which only two are ever non-zero:
##   byte 31  cell class (see below)
##   byte 30  door attribute, only ever the value 4
##
## Class codes, counted over all 1870 grids in the world:
##   0x00 empty 143806   0xd1 wall 82866   0xd0 21064   0xe0 18580
##   0xd2 floor  16302   0xda step  2420   0xe2  1802   0xd9 door 566   0xe9 385
##
## 0xd0/0xe0 are NOT empty: they decode to OPEN (see the enum), a building's
## open interior ground. Only the raw 0x00 byte is EMPTY.
##
## Border cells are 87.3% wall (20305/23250). The door reading was a prediction
## made BEFORE measuring: if low-nibble 9 means door then byte 30 attaches to
## those classes and nowhere else. It does -- 0xe9 80.3%, 0xd9 30.9%, 0xd1 0.0%
## (3 of 82866), 0xd0 0.0% (4 of 21064).
##
## The 0xd_ and 0xe_ families share low nibbles and are believed to be storeys or
## an inside/outside split; sector 64,39 carries FOUR co-located 50x55 regions,
## matching the items.pak naming innenunten / innenmitte / innenoben.
##
## Why this exists: retail does a CUTAWAY, captured 2026-08-07 by driving the
## game with autopilot.so -- the roof CENTRE is removed while the tiled ring and
## the outer walls stay, it is instant with no blend, it fires while the player
## is still outside on the steps, and a whole complex swaps at once. A region
## gives the footprint, the wall ring and the door cell, which is what a trigger
## that behaves that way needs.

const Common := preload("res://formats/common.gd")

const TABLE_OFF := Common.NAME + Common.SECT * Common.SECT * Common.CELL
const REC := 36
const TYPE := 6

## Cell classes. Only the low nibble is interpreted here.
##
## The high nibble is NOT the "0xd/0xe family split" this comment used to
## claim (row 710). All 16 values occur across the world -- 0xd 0.244,
## 0x4 0.165, 0x8 0.133, 0x3 0.131, 0x9 0.077, 0xb 0.081 and so on -- while
## the low nibble is essentially only {0,1,2}. Drawn with --classhi it
## segments the ground into contiguous areas that track the visible surface:
## lawn, cobbled courtyard, building floor and garden each take their own
## value. The ground texture predicts it only 0.647 of the time, so it is
## authored, not derived. Retail queries it by EQUALITY over a rect
## (0x080f1d2a walks a cell range accumulating where the high nibble matches
## a target), i.e. it is a per-cell GROUND-TYPE tag with 16 classes.
## Which value means which surface is not established; nothing here reads it.
##
## OPEN is not a nibble value: it is what a NON-ZERO byte whose class nibble
## is 0 (0xd0, 0xe0) decodes to, kept apart from a raw 0x00 byte. Measured
## 2026-08-13 at the Seraphim start (sector 50,39, KLOSTER_KAPELLE01): the
## chapel nave the hero spawns standing in is 0xd0 wall to wall and the
## library wing beside it is 0xe0, so these are the buildings' open interior
## ground. Collapsing them onto EMPTY made the retail roof-cutaway trigger
## unfireable at its own oracle spawn -- the hero's own cell read EMPTY.
enum { EMPTY = 0, WALL = 1, FLOOR = 2, DOOR = 9, STEP = 0xa, OPEN = 0x10 }

var list: Array[Dictionary] = []   ## {cell: Vector2i, size: Vector2i, grid: PackedByteArray}
## Native static+45 indexes the uncompressed 36-byte table, including its
## zero-size origin marker. Compact `list` indices are only presentation keys.
var by_ordinal: Dictionary[int, Dictionary] = {}

func _init(stream: PackedByteArray, gx: int, gy: int) -> void:
	if stream.size() <= TABLE_OFF + REC:
		return
	var lo := Vector2i(gx, gy) * Common.SECT
	var p := TABLE_OFF
	var ordinal := 0
	while p + REC <= stream.size():
		if stream.decode_u32(p + 0x0c) != TYPE:
			break
		var cell := Vector2i(stream.decode_u32(p), stream.decode_u32(p + 0x04))
		var size := Vector2i(stream.decode_u16(p + 0x08), stream.decode_u16(p + 0x0a))
		var off := stream.decode_u32(p + 0x10)
		var bytes := stream.decode_u32(p + 0x14)
		# Preserve the native ordinal even when this is the zero-size origin
		# marker, which cWorld::getPatch(substate) resolves to the base grid.
		if size == Vector2i.ZERO:
			by_ordinal[ordinal] = {"cell": cell, "size": size,
				"grid": PackedByteArray(), "ordinal": ordinal, "index": -1}
		if size.x > 0 and size.y > 0 and bytes == size.x * size.y * Common.CELL \
				and off + bytes <= stream.size() \
				and Rect2i(lo, Vector2i(Common.SECT, Common.SECT)).has_point(cell):
			var region := {"cell": cell, "size": size,
				"grid": stream.slice(off, off + bytes), "ordinal": ordinal, "index": list.size()}
			list.append(region)
			by_ordinal[ordinal] = region
		p += REC
		ordinal += 1

## Class of one grid cell, as the low nibble of byte 31. Out of range -> EMPTY.
static func cell_class(r: Dictionary, cx: int, cy: int) -> int:
	var size: Vector2i = r["size"]
	if cx < 0 or cy < 0 or cx >= size.x or cy >= size.y:
		return EMPTY
	var grid: PackedByteArray = r["grid"]
	var b := grid[(cy * size.x + cx) * Common.CELL + 31]
	if b == 0:
		return EMPTY
	var nibble := b & 0x0f
	return OPEN if nibble == 0 else nibble
