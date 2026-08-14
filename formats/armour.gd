extends RefCounted
## bin/rust.bin -- which mesh an armour becomes when a DIFFERENT character wears
## it. Compiled by retail from scripts/Rustungenswitch.txt, which retail does
## not ship; the name is the specification: it is a SWITCH, not an index.
##
## LAYOUT, fixed by exact arithmetic (autoresearch row 743): u32 count = 85,
## then 85 groups, each a u32 n followed by n pairs of u32 (wearer, mesh). Both
## are items.pak RECORD indices, and an items.pak record's +0x37 name is a .GRN
## filename -- the same "the id IS the model" chain Sacred.Creatures uses. The
## parse consumes 1098 of 1098 u32s and 506 of 506 pairs name a mesh on BOTH
## sides; anything less and this class refuses to report found.
##
## HOW IT IS KEYED, and why there is no index to look for (row 744): the ARMOUR
## MESH is the key. 503 distinct meshes across 506 pairs, only 3 in more than
## one group, and distinct (wearer, mesh) pairs == distinct meshes -- so the
## wearer is a function of the mesh and the left column only declares whose
## version a mesh is. A group is one armour, listed once per character that has
## it. No file carries a 0..84 ordinal; items.pak has no such column and is not
## an item catalogue at all.
##
## Everything here is by NAME, because that is what a caller holding a
## models.pak entry has, and because the two paks spell the same file with
## different case (items.pak stores "Seraphim_leather_04.grn").

const Items := preload("res://formats/items.gd")
const Pak := preload("res://formats/pak.gd")

## Meshes ambiguous BY items.pak RECORD -- the real key. Measured: 3.
var ambiguous_records := 0
## Meshes ambiguous BY FILENAME, which is the only key a caller holding a
## models.pak entry can offer. Measured: 109 of 284 distinct names, and for
## 74 of those the group choice CHANGES the answer for some wearer. This is
## why the name API below reports rather than decides.
var ambiguous_names := 0
var distinct_names := 0
## Groups whose wearer column repeats, so one (group, wearer) lookup yields
## more than one mesh. Measured: 8 of 85.
var duplicate_wearer_groups := 0
var groups := 0
var pairs := 0
var found := false

## items.pak record -> group index.
var _group_of_record: Dictionary[int, int] = {}
## UPPER filename -> every group any record of that name belongs to.
var _groups_of_name: Dictionary[String, PackedInt32Array] = {}
## group -> Array of [UPPER wearer name, mesh name as items.pak spells it].
var _members: Array[Array] = []

func _init(install: String) -> void:
	var items := Items.new(Pak.new(install.path_join("pak/items.pak")))
	var raw := FileAccess.get_file_as_bytes(install.path_join("bin/rust.bin"))
	if raw.size() < 4 or raw.size() % 4 != 0:
		push_warning("Armour: bin/rust.bin missing or not u32-aligned under %s" % install)
		return
	var n := raw.decode_u32(0)
	var p := 4
	var rec_first: Dictionary[int, int] = {}
	var rec_amb: Dictionary[int, bool] = {}
	var name_amb: Dictionary[String, bool] = {}
	for g in n:
		if p + 4 > raw.size():
			push_warning("Armour: rust.bin group %d runs past the file" % g)
			return
		var c := raw.decode_u32(p)
		p += 4
		if p + c * 8 > raw.size():
			push_warning("Armour: rust.bin group %d declares %d pairs it cannot hold" % [g, c])
			return
		var members: Array = []
		var wearers: Dictionary[String, int] = {}
		for k in c:
			var wrec := raw.decode_u32(p + k * 8)
			var mrec := raw.decode_u32(p + k * 8 + 4)
			var wname := items.name_of(wrec).to_upper()
			var mname := items.name_of(mrec)
			if wname == "" or mname == "":
				# Both sides naming a mesh is what fixes the layout; one that
				# does not means this is not rust.bin.
				push_warning("Armour: rust.bin group %d pair %d does not name a mesh" % [g, k])
				return
			members.append([wname, mname])
			wearers[wname] = int(wearers.get(wname, 0)) + 1
			if rec_first.has(mrec):
				if rec_first[mrec] != g:
					rec_amb[mrec] = true
			else:
				rec_first[mrec] = g
				_group_of_record[mrec] = g
			var key := mname.to_upper()
			var gl: PackedInt32Array = _groups_of_name.get(key, PackedInt32Array())
			if not gl.has(g):
				if not gl.is_empty():
					name_amb[key] = true
				gl.append(g)
				_groups_of_name[key] = gl
			pairs += 1
		for w: String in wearers:
			if wearers[w] > 1:
				duplicate_wearer_groups += 1
				break
		_members.append(members)
		p += c * 8
	if p != raw.size():
		push_warning("Armour: rust.bin left %d trailing bytes -- layout rejected" % (raw.size() - p))
		return
	ambiguous_records = rec_amb.size()
	ambiguous_names = name_amb.size()
	distinct_names = _groups_of_name.size()
	groups = _members.size()
	found = groups > 0

## EXACT lookup: the wearer's version(s) of the armour held as items.pak
## record `mesh_record`. This is the form the engine itself can use, because
## an item names a RECORD, and two records spelling the same .GRN are
## different armours that merely look alike.
func variants_for_record(mesh_record: int, wearer_name: String) -> PackedStringArray:
	return _read(_group_of_record.get(mesh_record, -1), wearer_name)

## BEST-EFFORT lookup by filename, for a caller holding a models.pak entry
## and no item. Returns the UNION over every group any record of that name
## belongs to, so nothing is silently dropped -- but check is_ambiguous()
## before trusting it, because 109 of 284 names span several groups and 74
## of those disagree about the answer.
func variants_for(mesh_name: String, wearer_name: String) -> PackedStringArray:
	var out := PackedStringArray()
	for g in _groups_of_name.get(_key(mesh_name), PackedInt32Array()):
		for v in _read(g, wearer_name):
			if not out.has(v):
				out.append(v)
	return out

## True when this FILENAME maps to more than one armour group, i.e. the
## name is not enough to identify the armour and variants_for() is a union
## of several possible answers rather than the answer.
func is_ambiguous(mesh_name: String) -> bool:
	return _groups_of_name.get(_key(mesh_name), PackedInt32Array()).size() > 1

## How many groups any record of this filename belongs to; 0 means the name
## is not armour at all, which is a different answer from "no variant".
func group_count(mesh_name: String) -> int:
	return _groups_of_name.get(_key(mesh_name), PackedInt32Array()).size()

func _read(g: int, wearer_name: String) -> PackedStringArray:
	var out := PackedStringArray()
	if g < 0 or g >= _members.size():
		return out
	var want := _key(wearer_name)
	for m: Array in _members[g]:
		if m[0] == want:
			out.append(m[1])
	return out

## items.pak and models.pak disagree about case, and a caller may hand over
## a name with or without the extension.
func _key(name: String) -> String:
	var t := name.strip_edges().to_upper()
	return t if t.ends_with(".GRN") else t + ".GRN"
