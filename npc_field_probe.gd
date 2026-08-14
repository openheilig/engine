extends SceneTree
## Probe: which UNKNOWN field of a trigger-carrying static (or of its items
## record) behaves like a creature id? A creature id should take many distinct
## values across the 1246 live triggers AND be stable within one items-name
## group. Everything else -- constant, or varying inside a group -- is not it.
## Read-only.
##   godot --headless --path godot-port --script res://npc_field_probe.gd

## (label, byte offset, width) over the 64-byte PakStatic. Known fields are
## skipped: +0x00 id, +0x04 itemTypeId, +0x08 flags, +0x0e/+0x12 pos,
## +0x1f nextStaticId, +0x27 triggerId.
const STATIC_FIELDS := [
	["st+0x0c.u16", 0x0c, 2], ["st+0x16.u8", 0x16, 1], ["st+0x17.u32", 0x17, 4],
	["st+0x1b.u32", 0x1b, 4], ["st+0x23.u16", 0x23, 2], ["st+0x25.u16", 0x25, 2],
	["st+0x2b.u8", 0x2b, 1], ["st+0x2c.u8", 0x2c, 1], ["st+0x2d.u8", 0x2d, 1],
	["st+0x2e.u8", 0x2e, 1], ["st+0x2f.u8", 0x2f, 1], ["st+0x30.u8", 0x30, 1],
	["st+0x31.u8", 0x31, 1], ["st+0x32.u8", 0x32, 1], ["st+0x33.u8", 0x33, 1],
	["st+0x34.u8", 0x34, 1], ["st+0x35.u8", 0x35, 1], ["st+0x36.u32", 0x36, 4],
	["st+0x3a.u32", 0x3a, 4],
]
## PakItemType is 128 bytes (rs_file.h:358-386). mixedId (+0x10) and the name
## (+0x37) are known; these are the rest of the numeric head plus category.
const ITEM_FIELDS := [
	["it+0x00.u32", 0x00, 4], ["it+0x04.u32", 0x04, 4], ["it+0x08.u32", 0x08, 4],
	["it+0x0c.u32", 0x0c, 4], ["it+0x14.u32", 0x14, 4], ["it+0x1c.u32", 0x1c, 4],
	["it+0x20.u32", 0x20, 4], ["it+0x24.u32", 0x24, 4], ["it+0x2c.u16", 0x2c, 2],
	["it+0x2e.u8", 0x2e, 1], ["it+0x57.u16", 0x57, 2], ["it+0x59.u16", 0x59, 2],
	["it+0x5b.u16", 0x5b, 2], ["it+0x5d.u16", 0x5d, 2], ["it+0x5f.u16", 0x5f, 2],
]

func _read(b: PackedByteArray, off: int, width: int) -> int:
	if off + width > b.size():
		return -1
	if width == 1:
		return b[off]
	return b.decode_u16(off) if width == 2 else b.decode_u32(off)


func _init() -> void:
	var install := Sacred.find_install()
	var items_pak := Sacred.Pak.new(install.path_join("pak/items.pak"))
	var items := Sacred.Items.new(items_pak)
	var static_pak := Sacred.Pak.new(install.path_join("world/static.pak"))
	var tb := FileAccess.get_file_as_bytes(install.path_join("world/triggers.pak"))

	var records: Array = []      ## {st, it, name}
	for i in tb.decode_u32(4):
		var o := 0x10c + i * 16
		if tb.decode_u16(o + 4) != 16:
			continue
		var st := static_pak.blob(tb.decode_u32(o + 6))
		if st.size() < 64:
			continue
		var itype := st.decode_u32(4)
		records.append({"st": st, "it": items_pak.blob(itype), "name": items.name_of(itype)})
	print("targets=%d" % records.size())

	for spec: Array in STATIC_FIELDS + ITEM_FIELDS:
		var label: String = spec[0]
		var from_item := label.begins_with("it")
		var distinct: Dictionary = {}
		var per_name: Dictionary = {}     ## name -> first value
		var unstable := 0
		for rec: Dictionary in records:
			var b: PackedByteArray = rec["it"] if from_item else rec["st"]
			var v := _read(b, spec[1], spec[2])
			distinct[v] = true
			var nm: String = rec["name"]
			if nm == "":
				continue
			if per_name.has(nm):
				if per_name[nm] != v:
					unstable += 1
			else:
				per_name[nm] = v
		print("field\t%s\tdistinct=%d\tunstable_within_name=%d" % [
			label, distinct.size(), unstable])
	quit()
