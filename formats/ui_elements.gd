extends RefCounted
class_name UiElements
## Retail's gfx element table at 0x880DC68 -- the 1887 texture sub-rects
## cUI_Taskbar2 draws from, each with retail's own name where the name blob
## covers it (analysis/tools/formats/uinames.py is the offline authority; the
## name blob is not read here because slots only need sheet+rect+id).
##
## Layout (ui-taskbar.md, row 1042): stride 84;
##   +0x00 char[32] sheet name   +0x24.. f32 u0,v0,u1,v1 (INCLUSIVE texels)
##   +0x4C int element id        +0x50 type flag
## Size is u1 - u0, NOT u1 - u0 + 1 -- hud_check caught the off-by-one.
##
## Validated on open, against facts hud_check already pins: element 12 is the
## console rect (0,169) 230x86, element 103 UI_ACTION is 63x63, and every id
## field equals its own index.

const STRIDE := 84
const MIN_ID := 64          ## a real table carries at least this many rows
const MAX_ID := 1886
const ROW12_REL := 11 * STRIDE   ## element 12 sits at base + 11*STRIDE
## R0: THE TABLE IS LOCATED BY SCAN, not by a build-specific address. The old
## fixed vaddr 0x880DC68 was an LGP-ELF fact; the Windows PE carries the same
## table at a different offset (verified: ENG exe, file 0x5ECEB8, both anchors
## exact). The locator below works for both: it prefilters on element 12's
## rect floats -- u0=0, v0=169, u1=230, v1=255 stored as four consecutive
## little-endian floats at row+0x24, rare enough to prefilter -- then
## validates the whole id==index chain and BOTH anchors before accepting.
## A mislocated table fails loudly; two matching anchors alone are not
## acceptance (audit §R0).

var _sheets: Dictionary[int, Texture2D] = {}
## element id -> {sheet: String, rect: Rect2i}
var _elements: Dictionary[int, Dictionary] = {}
## element id -> retail's own name ("UI_SPELL_51_EMPTY"), where the name blob
## covers it. The blob offset is NOT constant: -5 up to id 351, -3 from 443,
## unresolved in between (row 1042's correction). An unnamed id is "", never a
## guess -- the SPELL vs ACTION prefix is how a slot learns which side it sits
## on, so a wrong name would draw the wrong half of the bar.
var _names: Dictionary[int, String] = {}
## True when the executable's own name bands were readable (ELF layout). A PE
## tree yields "" names today: the blob's band offsets are ELF-specific, so
## the art-slot column routing degrades to the skill side -- a DECLARED gap
## (InstallProfile.capability_gaps), never a guessed side.
var names_resolved := false

const NAME_BLOB_START := 0x6CF9FD   # file offsets, from uinames.py
const NAME_BLOB_END := 0x6D5722
const NAME_LOW_OFFSET := 5
const NAME_LOW_LAST := 351
const NAME_HIGH_OFFSET := 3
const NAME_HIGH_FIRST := 443

func _init(install: String, tex_pak: Sacred.Pak) -> void:
	var bytes := _read_table(install)
	if bytes.is_empty():
		push_error("UiElements: no self-consistent gfx table in %s -- see _read_table for the anchors it validates"
			% install.path_join("sacred"))
		return
	_read_names(install)
	var cache: Dictionary[String, Texture2D] = {}
	# ROW FOR ID N IS AT STRIDE*(N-1) -- the table is zero-based, and it ENDS
	# at the first row whose id field disagrees (uinames.py's own rule).
	for id in range(1, MAX_ID + 1):
		var off := (id - 1) * STRIDE
		if off + STRIDE > bytes.size():
			break
		var sheet := bytes.slice(off, off + 32)
		var nul := sheet.find(0)
		if nul > 0:
			sheet = sheet.slice(0, nul)
		var sname := sheet.get_string_from_ascii()
		var u0 := int(bytes.decode_float(off + 0x24))
		var v0 := int(bytes.decode_float(off + 0x28))
		var u1 := int(bytes.decode_float(off + 0x2C))
		var v1 := int(bytes.decode_float(off + 0x30))
		var rid := bytes.decode_s32(off + 0x4C)
		if rid != id:
			break   # past the real table -- stop, do not store misaligned rows
		if sname.is_empty() or u1 <= u0 or v1 <= v0:
			continue
		_elements[id] = {"sheet": sname, "rect": Rect2i(u0, v0, u1 - u0, v1 - v0)}
	if _elements.is_empty():
		return
	# Two anchors the rest of the HUD already measured. A table that misplaces
	# either is the wrong table, whatever else it parses.
	var console: Dictionary = _elements.get(12, {})
	assert(console.get("rect", Rect2i()) == Rect2i(0, 169, 230, 86),
		"UiElements: element 12 is not the console rect -- table is misaligned")
	var action: Dictionary = _elements.get(103, {})
	assert(action.get("rect", Rect2i()).size == Vector2i(63, 63),
		"UiElements: element 103 is not 63x63 -- table is misaligned")


## Locates the gfx element table by content, not by address. Prefilter:
## element 12's rect floats (0.0, 169.0, 230.0, 255.0 inclusive) as 16
## consecutive little-endian bytes at row+0x24 -- rare enough that scanning
## an 11 MB engine is cheap. For each hit, the row base derives as
## hit - 0x24 - 11*STRIDE; accept only if the id==index chain runs from row 1
## without a break for MIN_ID rows, element 12's sheet is printable ASCII,
## and BOTH anchors hold with their expected values. Every accepted table
## passed the same two anchors hud_check measures; a wrong candidate fails
## loudly rather than partially loading.
func _read_table(install: String) -> PackedByteArray:
	var f := FileAccess.open(install.path_join("sacred"), FileAccess.READ)
	if f == null:
		return PackedByteArray()
	var exe := f.get_buffer(f.get_length())
	f.close()
	if exe.size() < MIN_ID * STRIDE:
		return PackedByteArray()
	# The needle's little-endian int32 pattern: 0.0, 169.0, 230.0, 255.0 ==
	# [0x00000000, 0x43290000, 0x43660000, 0x437F0000]. PackedByteArray has
	# no binary find in 4.7 and String conversion truncates on NUL bytes, so
	# the file is searched through FOUR int32 views at phase offsets 0..3 --
	# together they cover every alignment the needle can have relative to the
	# file start. find() runs at C speed; a candidate is accepted only after
	# the full-pattern and anchor validation below.
	var phases := [0x43290000, 0x43660000, 0x437F0000]
	for s in 4:
		var view := exe.slice(s).to_int32_array()
		var i := view.find(phases[0])
		while i >= 1 and i + 2 < view.size():
			if view[i - 1] == 0 and view[i + 1] == phases[1] and view[i + 2] == phases[2]:
				var base := s + (i - 1) * 4 - 0x24 - ROW12_REL
				if base >= 0 and _table_valid(exe, base):
					var last := _chain_length(exe, base)
					return exe.slice(base, base + last * STRIDE)
			i = view.find(phases[0], i + 1)
	return PackedByteArray()


## The id==index chain from row 1, stopping at the first disagreement -- the
## same end-rule the parser applies. -1 when row 1 itself is not a row.
func _chain_length(exe: PackedByteArray, base: int) -> int:
	var n := 0
	while n < MAX_ID:
		var off := base + n * STRIDE
		if off + STRIDE > exe.size() or exe.decode_s32(off + 0x4C) != n + 1:
			break
		n += 1
	return n


func _table_valid(exe: PackedByteArray, base: int) -> bool:
	if _chain_length(exe, base) < MIN_ID:
		return false
	var r12 := base + ROW12_REL + 0x24
	if not (exe.decode_float(r12) == 0.0 and exe.decode_float(r12 + 4) == 169.0
			and exe.decode_float(r12 + 8) == 230.0 and exe.decode_float(r12 + 12) == 255.0):
		return false
	var sheet := exe.slice(base + ROW12_REL, base + ROW12_REL + 9)
	for i in sheet.size():
		if sheet[i] < 0x20 or sheet[i] > 0x7E:
			return false
	# Anchor 2: element 103 is 63x63.
	var a := base + 102 * STRIDE + 0x24
	return int(exe.decode_float(a + 8) - exe.decode_float(a)) == 63 \
		and int(exe.decode_float(a + 12) - exe.decode_float(a + 4)) == 63


func _read_names(install: String) -> void:
	var f := FileAccess.open(install.path_join("sacred"), FileAccess.READ)
	if f == null:
		return
	# The band offsets below are LGP-ELF facts. A PE tree (or any other
	# layout) keeps names UNRESOLVED -- "" per the contract -- rather than
	# applying offsets that were never measured for it.
	var head := f.get_buffer(0x34)
	f.seek(0)
	if head.size() < 0x34 or head.decode_u32(0) != 0x464C457F:
		return
	f.seek(NAME_BLOB_START)
	var blob := f.get_buffer(NAME_BLOB_END - NAME_BLOB_START)
	if blob.is_empty():
		return
	names_resolved = true
	# Walk the NUL-separated strings; the first four are control names, not
	# elements, and the walk self-terminates on truncation.
	var strings: PackedStringArray = []
	var start := 0
	for i in blob.size():
		if blob[i] != 0:
			continue
		if i > start:
			strings.append(blob.slice(start, i).get_string_from_ascii())
		start = i + 1
		for id in range(1, MAX_ID + 1):
			var blob_index := -1
			if id <= NAME_LOW_LAST:
				blob_index = id + NAME_LOW_OFFSET
			elif id >= NAME_HIGH_FIRST:
				blob_index = id + NAME_HIGH_OFFSET
			if blob_index < 0 or blob_index >= strings.size():
				continue   # unresolved band (352..442) stays unnamed
			_names[id] = strings[blob_index]

func found() -> bool:
	return not _elements.is_empty()

## How many element rows the located table carried -- the scan acceptance
## reports this so a degraded table is visible, not just non-empty.
func count_pieces() -> int:
	return _elements.size()

func has(id: int) -> bool:
	return _elements.has(id)

func rect(id: int) -> Rect2i:
	return _elements.get(id, {}).get("rect", Rect2i())

func sheet_name(id: int) -> String:
	return _elements.get(id, {}).get("sheet", "")

## Retail's own element name, or "" inside the unresolved band.
func name(id: int) -> String:
	return _names.get(id, "")

## The element's own sheet as a texture, from texture.pak by stem.
func sheet(id: int, tex_pak: Sacred.Pak, cache: Dictionary) -> Texture2D:
	var sname := sheet_name(id)
	if sname.is_empty():
		return null
	if _sheets.has(id):
		return _sheets[id]
	var tex: Texture2D = cache.get(sname)
	if tex == null:
		var stem := sname.get_basename().to_upper()
		var tid := Sacred.TextureFormat.find_model_texture(tex_pak, stem + ".TGA")
		if tid < 0:
			tid = Sacred.TextureFormat.find_model_texture(tex_pak, stem)
		if tid < 0:
			return null
		var img := Sacred.TextureFormat.decode_texture(tex_pak, tid, false)
		if img == null:
			return null
		tex = ImageTexture.create_from_image(img)
		cache[sname] = tex
	_sheets[id] = tex
	return tex
