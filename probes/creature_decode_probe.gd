extends SceneTree
## Probe: verify the period German Creature.pak.txt field table against the
## retail bytes, test whether a creature id is an items.pak RECORD index, and
## characterise the 26 bytes that table does not describe. Read-only.
##   godot --headless --path godot-port --script res://probes/creature_decode_probe.gd
##
## Claimed record (60 of 86 bytes, hence the doc's "zu ca. 70% aufgeschluesselt"):
##   +0x00 u32 id      +0x04 u16 class   +0x06 u8 flags   +0x07 u8 ?
##   +0x08 u16 xpA     +0x0a u16 xpB     +0x0c..0x11 six base attributes
##   +0x12 u16 always0 +0x14..0x25 eighteen skill bytes
##   +0x26 u16 walk    +0x28 u16 run     +0x2a..0x35 six (bonus level, type)
##   +0x36..0x3b six bonus values        +0x3c..0x55 UNDESCRIBED (26 bytes)
const DATA := 256
const REC := 86
const HERO_NAMES := ["", "SERAPHIM.GRN", "GLADIATOR.GRN", "MAGICIAN.GRN", "DARKELVE.GRN",
	"ELVE_SORCERESS.GRN", "VLADY_D.GRN", "VLADY_N.GRN", "dwarf.grn", "Daemonia.grn"]

func _init() -> void:
	var install := Sacred.find_install()
	var b := FileAccess.get_file_as_bytes(install.path_join("pak/creature.pak"))
	var n := b.decode_u32(4)
	var items := Sacred.Items.new(Sacred.Pak.new(install.path_join("pak/items.pak")))
	var models := Sacred.Models.new(Sacred.Pak.new(install.path_join("pak/models.pak")))
	print("creature\tcount=%d\tstride_fits=%s" % [n, DATA + n * REC == b.size()])

	# 1. Does creature id == items.pak record index? The doc's hardcoded ids
	#    1..9 are the nine playable heroes in a fixed order; items.pak records
	#    1..9 name the nine hero .grn models. If they line up, the id space is
	#    settled by nine independent agreements.
	var by_id: Dictionary = {}
	for i in n:
		by_id[b.decode_u32(DATA + i * REC)] = i
	var agree := 0
	for id in range(1, 10):
		var nm := items.name_of(id)
		var ok: bool = by_id.has(id) and nm == HERO_NAMES[id]
		if ok:
			agree += 1
		var cls := -1
		if by_id.has(id):
			cls = b.decode_u16(DATA + int(by_id[id]) * REC + 4)
		print("hero\tid=%d\titems_name=%s\texpect=%s\tclass=%d\tmatch=%s" % [
			id, nm, HERO_NAMES[id], cls, ok])
	print("hero_agreement=%d of 9" % agree)

	# 2. Class histogram, and how many creature ids resolve to a .grn items name.
	var cls_hist: Dictionary = {}
	var named := 0
	var grn := 0
	for i in n:
		var o := DATA + i * REC
		cls_hist[b.decode_u16(o + 4)] = int(cls_hist.get(b.decode_u16(o + 4), 0)) + 1
		var nm := items.name_of(b.decode_u32(o))
		if nm != "":
			named += 1
			if nm.to_lower().ends_with(".grn"):
				grn += 1
	var ks: Array = cls_hist.keys(); ks.sort()
	for k: int in ks:
		print("class\t%d\t%d" % [k, cls_hist[k]])
	print("ids_naming_an_items_record=%d of %d\tof_which_grn=%d" % [named, n, grn])

	# 3. The 26 undescribed bytes: which vary, and does any look like a
	#    models.pak index (0..%d) or an items index?
	for off in range(0x3c, REC):
		var vals: Dictionary = {}
		var nonzero := 0
		for i in n:
			var v := b[DATA + i * REC + off]
			vals[v] = true
			if v != 0:
				nonzero += 1
		print("unk\t+0x%02x\tdistinct=%d\tnonzero=%d" % [off, vals.size(), nonzero])
	# and as u16/u32 windows, which is where an index would actually live
	for off in [0x3c, 0x3e, 0x40, 0x42, 0x44, 0x46, 0x48, 0x4a, 0x4c, 0x4e, 0x50, 0x52, 0x54]:
		var vals16: Dictionary = {}
		var in_models := 0
		for i in n:
			var v := b.decode_u16(DATA + i * REC + off)
			vals16[v] = true
			if v > 0 and v < models.count():
				in_models += 1
		print("unk16\t+0x%02x\tdistinct=%d\tin_models_range=%d" % [off, vals16.size(), in_models])
	print("models_count=%d" % models.count())
	quit()
