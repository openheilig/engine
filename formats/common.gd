extends RefCounted
## Layout constants and the one decompression helper the readers share.
##
## Split out of sacred.gd so a reader can depend on the numbers without
## depending on the facade that re-exports it -- Sacred preloads these files,
## so a reader reaching back for Sacred.SECT would be a cycle.

const SECT := 64          ## cells per sector edge
const TILE := 256         ## terrain texture edge
const CELL := 32          ## bytes per WldxEntry
const NAME := 32          ## bytes of (unreliable) name at the head of a sector stream

const PAK_HDR := 256
const PAK_IDX := 12
const KEY_HDR := 256
const KEY_REC := 768
const KEY_COORD := 32     ## u32 gy*100+gx -- authoritative, unlike the in-stream name
const KEY_OFF := 236      ## u32 byte offset into sectors.wldx
const KEY_CSIZE := 240    ## u32 compressed size
const KEY_DSIZE := 264    ## u32 decompressed size
## The sector's 0x100-byte ENVIRONMENT block, embedded in the keyx record
## (row 1010). Retail's 768-byte-record loader (sub_80EF4EE) memcpy's record
## bytes 0x1E9..0x2E8 into a per-sector slice hung off the runtime sector at
## +0x17C; the animated-liquid draw then reads the block's +0xF7 (for cells
## whose +0x1f high nibble is 9) and +0xF8 (nibble 10) as indices into the
## 14-material liquid table. Measured over all 1360 liquid sectors: every
## value is in 0..13, the sea reads B_WATER, the underworld reads lava, and
## 22 sectors carry two DIFFERENT liquids at once -- which is why two bytes.
const KEY_ENV := 489
const KEY_LIQ9 := KEY_ENV + 0xF7    ## = 736
const KEY_LIQ10 := KEY_ENV + 0xF8   ## = 737


## zlib stream -> bytes.
##
## Godot's COMPRESSION_DEFLATE is **zlib-wrapped, not raw** -- it calls
## inflateInit2 with window_bits 15, so the 78 9c header must be kept. (The
## plan said the opposite; measured 2026-08-07, results log row 209. Raw
## deflate is not reachable through this API at all.)
##
## Output size is always known up front -- keyx +264 for sectors, w*h*2 for
## textures -- so decompress_dynamic() is never needed.
static func inflate(z: PackedByteArray, out_size: int) -> PackedByteArray:
	return z.decompress(out_size, FileAccess.COMPRESSION_DEFLATE)


## Translate a virtual address in the retail Linux binary to a file offset
## via the ELF32 program headers. Returns -1 when the binary is missing,
## not ELF32, or the address falls in a BSS-only range. Shared by readers
## that pull static tables out of install/sacred at runtime (sound names,
## the unique-item drop table).
static func elf_vaddr_offset(path: String, vaddr: int) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return -1
	# Magic + class/data/version bytes; EI_OSABI is 3 (Linux) in this
	# binary, so bytes 4-7 read 0x03010101, not the textbook 0x00010101.
	if f.get_32() != 0x464C457F or (f.get_32() & 0x00FFFFFF) != 0x00010101:
		return -1
	f.seek(28)
	var phoff := f.get_32()
	f.seek(42)
	var phentsize := f.get_16()
	var phnum := f.get_16()
	for i in phnum:
		f.seek(phoff + i * phentsize)
		var p_type := f.get_32()
		var p_offset := f.get_32()
		var p_vaddr := f.get_32()
		f.get_32()  # p_paddr
		var p_filesz := f.get_32()
		var p_memsz := f.get_32()
		if p_type == 1 and p_vaddr <= vaddr and vaddr < p_vaddr + p_memsz:
			if vaddr - p_vaddr >= p_filesz:
				return -1
			return p_offset + (vaddr - p_vaddr)
	return -1
