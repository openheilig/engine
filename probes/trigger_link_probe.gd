extends SceneTree
## trigger_link_probe.gd -- READ-ONLY.
## Does triggers.pak record N carry a back-link to the static that names it?
##   godot --headless --path godot-port --script res://probes/trigger_link_probe.gd

const BASE := 0x10c   ## = header u32 at 0x104; 36556 - 2268*16 = 268
const STRIDE := 16

func _init() -> void:
	var install := Sacred.find_install()
	var tf := FileAccess.open(install.path_join("world/triggers.pak"), FileAccess.READ)
	var tlen := tf.get_length()
	tf.seek(4)
	var tn := tf.get_32()
	tf.seek(0x100)
	print("triggers.pak header@0x100: a=%d b=%d c=%d  (b=%d == BASE, c=%d == n*16=%d)" % [
		tf.get_32(), tf.get_32(), tf.get_32(), BASE, 2268 * 16, tn * STRIDE])
	tf.seek(0)
	var t := tf.get_buffer(tlen)
	print("  n=%d  BASE+n*%d=%d  file=%d  %s" % [tn, STRIDE, BASE + tn * STRIDE, tlen,
		"EXACT FIT" if BASE + tn * STRIDE == tlen else "MISFIT"])

	# id == index?
	var bad := 0
	var f4 := {}
	var fa := {}
	var fc := {}
	var u32s := PackedInt64Array()
	u32s.resize(tn)
	for i in tn:
		var o := BASE + i * STRIDE
		if t.decode_u32(o) != i:
			bad += 1
		f4[t.decode_u16(o + 4)] = int(f4.get(t.decode_u16(o + 4), 0)) + 1
		u32s[i] = t.decode_u32(o + 6)
		fa[t.decode_u16(o + 10)] = int(fa.get(t.decode_u16(o + 10), 0)) + 1
		fc[t.decode_u32(o + 12)] = int(fc.get(t.decode_u32(o + 12), 0)) + 1
	print("  +0x00 u32 != index for %d of %d records" % [bad, tn])
	print("  +0x04 u16 histogram: %s" % _hist(f4))
	print("  +0x0a u16 histogram: %s" % _hist(fa))
	print("  +0x0c u32 histogram: %s" % _hist(fc))
	var mn := u32s[0]
	var mx := u32s[0]
	for v in u32s:
		mn = mini(mn, v)
		mx = maxi(mx, v)
	print("  +0x06 u32 range: %d .. %d" % [mn, mx])

	var static_pak := Sacred.Pak.new(install.path_join("world/static.pak"))
	print("  static.pak record count: %d" % static_pak.count())
	var inrange := 0
	for v in u32s:
		if v > 0 and v < static_pak.count():
			inrange += 1
	print("  +0x06 values that are valid static.pak indices: %d of %d" % [inrange, tn])

	# --- decisive: for every .grn static found earlier, does its trigger point back? ---
	var items := Sacred.Items.new(Sacred.Pak.new(install.path_join("pak/items.pak")))
	var pairs := [
		[706840, 1978], [720860, 1989], [721237, 1992], [721429, 1993], [723890, 1994],
		[737887, 2015], [740342, 2017], [740929, 2019], [741091, 2020], [741195, 2021],
		[741454, 2023], [757134, 2032], [758529, 2034], [759398, 2035], [760898, 2036],
		[775488, 2047], [777858, 2048], [777957, 2049], [792654, 2059], [793219, 2061],
		[793816, 2062], [794466, 2063], [795130, 2064], [811547, 2081], [811604, 2082],
		[812349, 2083], [812655, 2084], [812878, 2086], [813195, 2087], [813556, 2089],
		[829419, 2104], [829901, 2105], [830551, 2106],
	]
	print("\n-- back-link test: triggers.pak[trig].+0x06 == static rec? --")
	var ok := 0
	for pr: Array in pairs:
		var rec: int = pr[0]
		var tg: int = pr[1]
		var o := BASE + tg * STRIDE
		var back := t.decode_u32(o + 6)
		var hit := back == rec
		if hit:
			ok += 1
		print("  trig=%-6d static=%-8d back=%-8d %s   f4=%d fa=%d fc=%d" % [
			tg, rec, back, "MATCH" if hit else "MISS",
			t.decode_u16(o + 4), t.decode_u16(o + 10), t.decode_u32(o + 12)])
	print("  matched %d of %d" % [ok, pairs.size()])

	# --- what do ALL 2268 triggers point at? ---
	print("\n-- do all trigger targets name a .grn items record? --")
	var grn := 0
	var nongrn := {}
	var f16 := 0
	var f16grn := 0
	for i in tn:
		var v := u32s[i]
		if v <= 0 or v >= static_pak.count():
			continue
		var r := static_pak.blob(v)
		var typ := r.decode_u32(4)
		var nm := items.name_of(typ)
		if r.decode_u32(8) == 16:
			f16 += 1
		if nm.to_lower().ends_with(".grn"):
			grn += 1
			if r.decode_u32(8) == 16:
				f16grn += 1
		else:
			nongrn[nm if nm != "" else "<unnamed t%d>" % typ] = int(nongrn.get(nm, 0)) + 1
	print("  targets whose static names a .grn record: %d of %d" % [grn, inrange])
	print("  targets whose static has flags(+0x08)==16: %d" % f16)
	print("  ...and both: %d" % f16grn)
	var nk: Array = nongrn.keys()
	nk.sort_custom(func(a, b): return nongrn[a] > nongrn[b])
	print("  top 20 NON-.grn target names: ")
	for k in nk.slice(0, 20):
		print("     %-40s x%d" % [k, nongrn[k]])

	# --- does the static's own +0x27 always equal the trigger index? ---
	print("\n-- reverse: statics whose +0x27 is set, do they round-trip? --")
	var rt_ok := 0
	var rt_bad := 0
	for i in tn:
		var v := u32s[i]
		if v <= 0 or v >= static_pak.count():
			continue
		var own := static_pak.blob(v).decode_u32(0x27)
		if own == i:
			rt_ok += 1
		else:
			rt_bad += 1
			if rt_bad <= 8:
				print("     trig=%d -> static=%d whose own +0x27 = %d" % [i, v, own])
	print("  round-trip OK=%d  mismatched=%d" % [rt_ok, rt_bad])
	quit(0)


func _hist(d: Dictionary) -> String:
	var k: Array = d.keys()
	k.sort_custom(func(a, b): return d[a] > d[b])
	var s := ""
	for x in k.slice(0, 12):
		s += "%d:%d  " % [x, d[x]]
	return s + ("(+%d more)" % (k.size() - 12) if k.size() > 12 else "")
