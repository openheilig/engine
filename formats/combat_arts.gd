class_name CombatArts
extends RefCounted
## The combat-art table, read out of the retail EXECUTABLE at 0x8793D00
## (findings log rows 1045-1048). It carries the two coefficients an art's
## regeneration is built from:
##
##     total = base + level * step          (world/regen.gd)
##
## WHY THE EXECUTABLE. Those numbers are in no pak. They are not in
## `creature.pak`, not in `balance.bin`, not in `global.res` -- they are a
## static array compiled into the binary, and `sub_8306C6A` scans records
## 1..0x5E of it by art id. This is the first thing the port reads out of the
## executable rather than out of a data file, and that is a real dependency
## rather than a convenience: it is here because the data is there.
##
## NOTHING IS COPIED INTO THIS REPOSITORY. The table is read from the user's
## own install at run time, exactly as `bin/balance.bin` is -- the port carries
## the OFFSETS, retail keeps the values.
##
## THE ADDRESS IS A CONSTANT OF THE LINUX LGP BUILD, so this validates a
## SIGNATURE instead of trusting it: record 1 must be art 1000 at base 5 and
## step 3, the first four ids must be 1000/1001/1002/1009, and every element
## triple must be consecutive. A different binary fails `found` rather than
## returning plausible garbage -- which is the failure mode that matters, since
## a wrong offset here yields floats that look like balance data.

const TABLE := 0x8793D00
const STRIDE := 120
## `sub_8306C6A`'s own bounds. Record 0 is a zero slot and retail skips it.
const FIRST := 1
const LAST := 0x5E

const O_ID := 0x00          ## i16, what sub_8306C6A matches
const O_ICON := 0x0C        ## char[24], the art's own icon TEXTURE name
const O_ELEM := 0x30        ## i32[3], the EMPTY / LOAD / FULL element ids
const O_SCHOOL := 0x3C      ## i32
const O_BASE := 0x40        ## f32  regeneration
const O_STEP := 0x44        ## f32
## A SECOND base/step pair, and what it means depends on the art. For the
## attack moves it reads as a MULTIPLIER -- GUI_MOVE_HARDHIT is 1.80 + 0.20 a
## level against GUI_MOVE_ATTACKE's 0.75 + 0.05, which is the ordering a heavy
## swing and a quick one should have. But art 1022 (CHANGELING_DAY) reads
## 24.00 + 6.00, which is a duration in seconds and not a multiplier at all.
##
## SO THE FIELD IS POLYMORPHIC AND ITS READING IS NOT RECOVERED. It is exposed
## because it is measured; NOTHING applies it. Inventing a rule for which arts
## multiply damage would be inventing balance.
const O_EFFECT := 0x50      ## f32
const O_EFFECT_STEP := 0x54 ## f32

## The signature. Not decoration: it is the whole defence against a build whose
## layout moved.
const SIG_IDS: Array[int] = [1000, 1001, 1002, 1009]
const SIG_BASE := 5.0
const SIG_STEP := 3.0

var found := false
var reason := ""
var _by_id := {}


func _init(install: String) -> void:
	var f := FileAccess.open(install.path_join("sacred"), FileAccess.READ)
	if f == null:
		reason = "no executable at %s" % install.path_join("sacred")
		return
	var bytes := f.get_buffer(f.get_length())
	f.close()
	var off := _vaddr_to_off(bytes, TABLE)
	if off < 0:
		reason = "0x%X is in no PT_LOAD segment" % TABLE
		return
	var rows := []
	for i in range(FIRST, LAST + 1):
		var at := _vaddr_to_off(bytes, TABLE + STRIDE * i)
		if at < 0 or at + STRIDE > bytes.size():
			reason = "record %d runs past the file" % i
			return
		rows.append({
			"id": bytes.decode_s16(at + O_ID),
			"icon": bytes.slice(at + O_ICON, at + O_ELEM).get_string_from_ascii(),
			"school": bytes.decode_s32(at + O_SCHOOL),
			"effect_base": bytes.decode_float(at + O_EFFECT),
			"effect_step": bytes.decode_float(at + O_EFFECT_STEP),
			"base": bytes.decode_float(at + O_BASE),
			"step": bytes.decode_float(at + O_STEP),
			"elem": [bytes.decode_s32(at + O_ELEM),
				bytes.decode_s32(at + O_ELEM + 4),
				bytes.decode_s32(at + O_ELEM + 8)],
		})
	if not _signature_holds(rows):
		return
	for r in rows:
		_by_id[r["id"]] = r
	found = true


## Every check must hold. A near miss is a different table, not a close one.
func _signature_holds(rows: Array) -> bool:
	for i in SIG_IDS.size():
		if rows[i]["id"] != SIG_IDS[i]:
			reason = "art id %d is %d, expected %d" % [i, rows[i]["id"], SIG_IDS[i]]
			return false
	if not (is_equal_approx(rows[0]["base"], SIG_BASE)
			and is_equal_approx(rows[0]["step"], SIG_STEP)):
		reason = "art 1000 reads base %f / step %f" % [rows[0]["base"], rows[0]["step"]]
		return false
	for r in rows:
		if r["id"] == 0:
			reason = "a null slot inside retail's own bounds"
			return false
		# The slot draws EMPTY / LOAD / FULL from three consecutive elements
		# (row 1043). Three that are not consecutive means this is not the
		# table, whatever the floats look like.
		if r["elem"][1] != r["elem"][0] + 1 or r["elem"][2] != r["elem"][0] + 2:
			reason = "art %d's element triple is not consecutive" % r["id"]
			return false
		if r["step"] < 0.0:
			reason = "art %d regenerates FASTER as it levels" % r["id"]
			return false
	return true


## ELF32 program headers. The table is a virtual address; the file is not
## mapped, so it has to be translated rather than seeked to.
func _vaddr_to_off(b: PackedByteArray, vaddr: int) -> int:
	if b.size() < 0x34 or b.decode_u32(0) != 0x464C457F:      # \x7FELF
		return -1
	var ph := b.decode_u32(0x1C)
	var size := b.decode_u16(0x2A)
	var n := b.decode_u16(0x2C)
	for i in n:
		var o := ph + i * size
		if o + 32 > b.size():
			return -1
		if b.decode_u32(o) != 1:                              # PT_LOAD
			continue
		var p_off := b.decode_u32(o + 4)
		var p_vaddr := b.decode_u32(o + 8)
		var p_filesz := b.decode_u32(o + 16)
		if vaddr >= p_vaddr and vaddr < p_vaddr + p_filesz:
			return p_off + (vaddr - p_vaddr)
	return -1


func ids() -> PackedInt32Array:
	var out := PackedInt32Array()
	for k in _by_id:
		out.append(k)
	out.sort()
	return out


func has(art_id: int) -> bool:
	return _by_id.has(art_id)


## The two coefficients world/regen.gd needs, as {base, step}.
func coefficients(art_id: int) -> Dictionary:
	var r: Dictionary = _by_id.get(art_id, {})
	return {"base": r.get("base", 0.0), "step": r.get("step", 0.0)}


## The art's regeneration at a level, which is the whole point of the table.
func total(art_id: int, perm: int, temp: int = 0) -> float:
	var c := coefficients(art_id)
	return Regen.total(c["base"], c["step"], perm, temp)


## The art's own icon texture, e.g. "GUI_MOVE_HARDHIT.TGA". This is the same
## per-art name row 1021 found loose in texture.pak while looking for the
## filled art-slot art -- the table names it directly.
func icon(art_id: int) -> String:
	var r: Dictionary = _by_id.get(art_id, {})
	return r.get("icon", "")


## The second coefficient pair at the art's level. MEASURED, NOT APPLIED --
## see O_EFFECT. A caller that uses this is deciding something this project
## has not recovered.
func effect(art_id: int, perm: int, temp: int = 0) -> float:
	var r: Dictionary = _by_id.get(art_id, {})
	if r.is_empty():
		return 0.0
	return Regen.total(r["effect_base"], r["effect_step"], perm, temp)


## The EMPTY / LOAD / FULL element ids the slot draws with (row 1043).
func elements(art_id: int) -> Array:
	var r: Dictionary = _by_id.get(art_id, {})
	return r.get("elem", [])
