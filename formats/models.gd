extends RefCounted
## pak/models.pak -- Granny 1.x tagged-chunk container. R1.1: two payload
## kinds share one index (64 mesh, 3421 65 motion), each with its own root-tag
## offset and its own truth about whether the index's third field is a byte
## length. Measured directly against install/pak/models.pak, not read from
## Iris1 (GPL) or the statically-linked Granny runtime -- every offset and
## chunk size below is byte evidence recorded in
## the phase-03 research notes.
##
## This class emits (tag, offset, length) triples only -- no field
## interpretation. Mesh/skeleton decode is a later plan's job.

const Pak := preload("res://formats/pak.gd")

## High 16 bits of every documented tag; also the root chunk's own value.
const MAGIC := 0xCA5E0000
const TERMINATOR := 0xCA5EFFFF
const KIND_MESH := 64
const KIND_MOTION := 65
## kind==64 (mesh) ONLY. Do not generalise -- kind==65 (motion, R1.5) puts
## the root tag at MAGIC_OFF_MOTION instead, confirmed on the full corpus
## for kind==64 and a 25-entry sample for kind==65 (the phase-03 research notes
## "Magic offset is kind-dependent").
const MAGIC_OFF_MESH := 0x4EA
const MAGIC_OFF_MOTION := 0x140   ## not used this phase; recorded so R1.5 doesn't re-derive it.
const NAME_LEN := 64
## Fixed sizes (tag included) for the tags this phase can walk. The header
## chain only, for now -- Plan 01 Task 2 and Plan 02 extend this with the
## fixed 12-byte leaf families research documented.
##
## object and final are 20/36, NOT the 16/32 the phase-03 research notes prose states --
## corrected against a direct hex census of GLADIATOR.GRN (pak index 589):
## root@1258 (32) -> copyright@1290 (20) -> object@1310 (20, ends 1330,
## not 1326) -> final@1330 (36, ends 1366 where the first leaf tag
## 0xCA5E0200 begins). Sized 16/32 stopped `walk()` after 3 tags: it read
## the final tag's own offset (1326) as reserved/zero padding one field
## short of where 0xCA5E0101 actually starts.
const TAG_SIZES := {
	MAGIC: 32,          # 0xCA5E0000 root
	0xCA5E0102: 20,     # copyright
	0xCA5E0103: 20,     # object
	0xCA5E0101: 36,     # final
	# Fixed 12-byte leaf families (4-byte tag + 8-byte payload), confirmed
	# by hex walk (the phase-03 research notes "Chunk stream structure"): delta to the
	# next tag is exactly 12 for every one of these, no exceptions seen.
	0xCA5E0200: 12,
	0xCA5E1000: 12,
	0xCA5E1001: 12,
	0xCA5E1002: 12,
	0xCA5E1003: 12,
	0xCA5E0F00: 12,
	0xCA5E0F01: 12,
	0xCA5E0F02: 12,
	0xCA5E0F03: 12,
	0xCA5E0F04: 12,
	0xCA5E0F05: 12,
	0xCA5E0F06: 12,
}
## Hard cap on triples emitted per entry (all objects combined). Research
## counted 537 repetitions of the 0F01/0F02/0F06 family alone in
## GLADIATOR.GRN's single object; sized generously above that so a
## multi-object file has headroom without the cap ever being the reason
## a well-formed entry's walk is cut short.
const WALK_BUDGET := 4096
## Byte offset, from an object's 0xCA5E0000 root chunk start, of the H1
## candidate object-byte-length field. the phase-03 research notes's prose calls this
## field "+0x14"; a raw census (the 03-01 write-up, this task) found it one
## u32 word earlier, at +0x10 -- root_off + 0x14 reads 0 in every sample
## checked, while root_off + 0x10 exactly equals true_length(entry) -
## magic_offset(entry) for BAT.GRN, GLAD_SA5_SHOULDER.GRN and GLADIATOR.GRN.
const H1_LEN_OFF := 0x10

var _pak: Pak

func _init(pak: Pak) -> void:
	_pak = pak

func count() -> int:
	return _pak.count()

## Byte size of the backing pak, for callers that cache derived data and
## need to know the corpus changed underneath them (Sacred.Rigs).
func pak_size() -> int:
	return _pak.file_size()

## Bounds-checked read of the entry's stored kind (64 mesh, 65 motion).
## -1 for an out-of-range index.
func kind_of(entry: int) -> int:
	if entry < 0 or entry >= _pak.count():
		return -1
	return _pak.kinds[entry]

## MAGIC_OFF_MESH for kind==64, MAGIC_OFF_MOTION for kind==65, -1
## otherwise. Never a single unqualified constant -- see MAGIC_OFF_MESH.
func magic_offset(entry: int) -> int:
	var kind := kind_of(entry)
	if kind == KIND_MESH:
		return MAGIC_OFF_MESH
	if kind == KIND_MOTION:
		return MAGIC_OFF_MOTION
	return -1

## True on-disk length, derived from the gap to the next entry's offset
## (or to end of file, for the last entry). NEVER _pak.sizes[entry]: index
## field 3 averages 1.95x the true gap for kind==64 (the phase-03 research notes
## "Index field 3 is not a byte length for kind=64, and IS one for
## kind=65") -- this method does not even branch on kind, because the
## rule ("derive from offsets, not from the index") is uniform; only the
## RATIO to field3 differs by kind, and this method never reads field3.
## Returns 0 for an out-of-range index or a non-positive derived length.
func true_length(entry: int) -> int:
	if entry < 0 or entry >= _pak.count():
		return 0
	var length: int
	if entry + 1 < _pak.count():
		length = _pak.entry_offset(entry + 1) - _pak.entry_offset(entry)
	else:
		length = _pak.file_size() - _pak.entry_offset(entry)
	if length <= 0:
		push_error("Models: entry %d has non-positive derived length %d" % [entry, length])
		return 0
	return length

## First NAME_LEN bytes of the entry, truncated at the first NUL and
## decoded as ASCII. A byte at or above 0x80, or NAME_LEN bytes with no
## NUL, is returned as-is -- get_string_from_ascii() maps each byte to its
## own code point, it does not substitute U+FFFD, so no silent
## normalisation happens here.
func entry_name(entry: int) -> String:
	if entry < 0 or entry >= _pak.count():
		return ""
	var length := true_length(entry)
	if length <= 0:
		return ""
	var r := _pak.read_at(_pak.entry_offset(entry), mini(NAME_LEN, length))
	var nul := r.find(0)
	if nul == -1:
		return r.get_string_from_ascii()
	return r.slice(0, nul).get_string_from_ascii()

## The single exclusion predicate for the whole phase: false when this
## entry has no kind-scoped magic offset, is too short to reach it, or
## the u32 there is not MAGIC. INVALID_MODEL (index 0) and INVALID_MOTION
## (index 1572) are rejected by this same check, not by an index list or
## a size cutoff (the phase-03 research notes Pitfall 9 -- the exclusion set must fall
## out of the walker's own logic, never be hardcoded).
func magic_ok(entry: int) -> bool:
	var off := magic_offset(entry)
	if off == -1:
		return false
	var length := true_length(entry)
	if length < off + 4:
		return false
	var r := _pak.read_at(_pak.entry_offset(entry) + off, 4)
	if r.size() < 4:
		return false
	return r.decode_u32(0) == MAGIC

## Populated by the most recent walk() call: {h1_confirmed: bool,
## objects: int, h1_bytes: int, object_lengths: Array[int], consumed: int,
## stop_reason: String, stop_tag: int, stop_off: int}. object_lengths
## holds each object's own H1-declared byte length, in emission order --
## the per-model-varying declared fact grnwalk.gd folds into the triples
## md5 so entries with an identical tag-structure prefix still hash
## differently (the 03-01 write-up, Task 2, discrimination requirement).
## Single-threaded use only -- Models carries no concurrency contract, so
## do not call walk() for two entries concurrently and expect both
## results to be held at once.
var last_walk_meta: Dictionary = {}

## (tag, offset, length) triples across every top-level object in the
## entry, entry-relative offsets, advancing strictly by each tag's
## declared size from TAG_SIZES -- never by scanning for the next
## tag-shaped byte pattern. Empty for an entry that fails magic_ok().
##
## Within one object, the inner walk stops on the terminator, on a tag
## absent from TAG_SIZES (recorded in last_walk_meta as
## stop_reason=unknown-tag with stop_tag/stop_off), on a read that would
## pass the buffer end, or on WALK_BUDGET.
##
## H1 (stated before measuring, plan 03-01 Task 2): the u32 at +0x14
## inside an object's 0xCA5E0000 root chunk is that object's byte length,
## measured from the root chunk's own start.
## [Corrected during Task 2 execution] the phase-03 research notes's "+0x14" is one u32
## word off: a raw census of the root chunk's own bytes (see the 03-01 write-up)
## found the size-like field at root_off + 0x10, not root_off + 0x14 (which
## reads 0 in every sample). Confirmed against three independent entries by
## checking true_length(entry) - magic_offset(entry): BAT.GRN 35220, GLAD_SA5_
## SHOULDER.GRN 38188, GLADIATOR.GRN 185584 -- each an exact match to the u32
## at root_off + 0x10 and nowhere else in the root chunk. The code below uses
## the measured offset (+0x10); the doc comment keeps "+0x14" in its own name
## only because that is what H1's hypothesis statement (and the plan text) call
## it -- the constant itself is not re-literal'd, see H1_LEN_OFF below.
## On a clean terminator this
## is tested by jumping root_off + h1_len and checking whether MAGIC
## lands there (another object follows, so the walk continues into it)
## or the jump lands exactly on true_length(entry) (this was the last
## object, and the whole entry is now accounted for). Either outcome
## keeps last_walk_meta.h1_confirmed true; any other outcome -- the
## predicted position is neither the next object's root nor the entry's
## end -- refutes H1 for this entry and stops rather than guessing a
## replacement length.
func walk(entry: int) -> Array[Dictionary]:
	var triples: Array[Dictionary] = []
	var object_lengths: Array[int] = []
	last_walk_meta = {
		"h1_confirmed": false, "objects": 0, "h1_bytes": 0,
		"object_lengths": object_lengths, "consumed": 0,
		"stop_reason": "", "stop_tag": 0, "stop_off": 0,
	}
	if not magic_ok(entry):
		return triples
	var length := true_length(entry)
	var buf := _pak.read_at(_pak.entry_offset(entry), length)
	var pos := magic_offset(entry)
	last_walk_meta["consumed"] = pos
	var objects := 0
	var h1_total := 0
	var confirmed := true
	while pos + 4 <= buf.size() and buf.decode_u32(pos) == MAGIC:
		var root_off := pos
		var h1_len := 0
		if root_off + H1_LEN_OFF + 4 <= buf.size():
			h1_len = buf.decode_u32(root_off + H1_LEN_OFF)
		var terminated := false
		while pos + 4 <= buf.size():
			if triples.size() >= WALK_BUDGET:
				last_walk_meta["stop_reason"] = "budget"
				confirmed = false
				break
			var tag := buf.decode_u32(pos)
			if tag == TERMINATOR:
				terminated = true
				break
			if not TAG_SIZES.has(tag):
				last_walk_meta["stop_reason"] = "unknown-tag"
				last_walk_meta["stop_tag"] = tag
				last_walk_meta["stop_off"] = pos
				confirmed = false
				push_error("Models: entry %d unknown tag 0x%08x at offset %d" % [entry, tag, pos])
				break
			var size: int = TAG_SIZES[tag]
			if pos + size > buf.size():
				last_walk_meta["stop_reason"] = "truncated"
				confirmed = false
				break
			triples.append({"tag": tag, "off": pos, "len": size})
			pos += size
		if not terminated:
			last_walk_meta["consumed"] = pos
			break
		objects += 1
		h1_total += h1_len
		object_lengths.append(h1_len)
		var predicted := root_off + h1_len
		if predicted == length:
			last_walk_meta["consumed"] = predicted
			last_walk_meta["stop_reason"] = "end-of-entry"
			break
		if predicted + 4 <= buf.size() and buf.decode_u32(predicted) == MAGIC:
			pos = predicted
			last_walk_meta["consumed"] = predicted
			continue
		confirmed = false
		last_walk_meta["stop_reason"] = "h1-mismatch"
		last_walk_meta["stop_off"] = predicted
		last_walk_meta["consumed"] = pos  # last verified position; the failed guess is not counted as consumed
		break
	last_walk_meta["h1_confirmed"] = confirmed and objects > 0
	last_walk_meta["objects"] = objects
	last_walk_meta["h1_bytes"] = h1_total
	return triples

# ---------------------------------------------------------------------
# Geometry decode (Plan 05).
#
# CORRECTION to every earlier document that calls the post-terminator
# region "the untagged bulk region": it is not untagged. It opens with a
# flat node directory, and every node carries a 0xCA5E____ tag -- the same
# tag space the chunk stream uses. Nothing below scans for a byte pattern;
# geometry is found by tag through that directory.
#
#   SECTION_OFF_MESH + 0                    u32 numNodes
#   SECTION_OFF_MESH + DIR_OFF + j*12       {u32 tag, u32 rel, u32 children}
#   a node's payload starts at SECTION_OFF_MESH + rel
#
# SECTION_OFF_MESH was solved against the oracle
# (analysis/tools/granny_oracle -> granny2 2.7.0.30, which reports each GR2
# mesh's first vertex), not guessed. For GLADIATOR.GRN the oracle's three
# first-vertex float triples -- (0.913,-0.150,68.470), (-0.916,2.864,69.745)
# and (-4.380,-0.136,38.286) -- each occur exactly ONCE in the entry's
# 186842 bytes, at 22066, 99622 and 124734. The three MeshVertices nodes
# declare rel 20432, 97988 and 123100. The differences are 1634, 1634 and
# 1634: one base, three independent confirmations, on a test that could
# have disagreed three ways and did not.
#
# Two index spaces, one Godot index space. A MeshTriangles record is 24
# bytes of six int32 {a,b,c, na,nb,nc}: three POSITION indices then three
# NORMAL indices. Godot's add_surface_from_arrays takes a single index
# space, so mesh_arrays() de-interleaves -- each distinct (position,normal)
# pair becomes one Godot vertex. Face counts are not stored in the node;
# they are derived from the gap to the next node with a strictly larger
# rel, and that derivation is what the oracle check below validates.
const SECTION_OFF_MESH := 1634
## Byte offset of the directory from SECTION_OFF_MESH; numNodes is the u32
## at SECTION_OFF_MESH + 0.
const DIR_OFF := 16
const NODE_STRIDE := 12
## Ceiling on the declared node count, applied before the count is used to
## size anything -- the same posture Mixed.sprite() takes with its declared
## tile count. GLADIATOR.GRN, the largest entry sampled, declares 1271.
const MAX_NODES := 1 << 20
const TAG_MESH := 0xCA5E0601
const TAG_MESH_VERTICES := 0xCA5E0801
const TAG_MESH_NORMALS := 0xCA5E0802
const TAG_MESH_TRIANGLES := 0xCA5E0901
## MeshField holds one vertex-attribute channel: a u32 component count
## (measured = 3 for every field in GLADIATOR.GRN) then that many float32
## per entry. Texture coordinates are the first two components.
const TAG_MESH_FIELD := 0xCA5E0803
## Root of the RenderPass tree, which is where the per-CORNER UV indices
## live. They are NOT in the face record: that carries position and normal
## indices only, which is why a UV split cannot be derived from faces alone.
const TAG_FORM_MESH := 0xCA5E0C03
const TAG_MODEL_SECTION := 0xCA5E0E01
## 3x float32 per position and per normal; 6x int32 per face.
const VEC3_STRIDE := 12
const TRI_STRIDE := 24
## Bytes per MeshField entry (3x float32) and per RenderPass face-UV record
## ({int32 faceIndex, int32 uvA, int32 uvB, int32 uvC}). Each MeshField also
## carries a 4-byte component-count header ahead of its entries.
const UV_FIELD_STRIDE := 12
const UV_FIELD_HEADER := 4
const UV_RECORD_STRIDE := 16
## Granny-stored axes to Godot's. Columns are the images of the stored basis
## vectors: x -> +X, y -> -Z, z -> +Y. Determinant +1, so no mirroring.
## See coordinate_basis() for how this was derived from per-mesh bounding
## boxes rather than picked to make the render look upright.
const GRN_TO_GODOT := Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0))

## Set by the most recent coordinate_basis() call: true when the basis has
## been established with confidence, NOT when it was found as literal bytes.
##
## The original meaning was the literal one -- "nine consecutive orthonormal
## float32 were found in the file" -- and it was always false, because an
## exhaustive scan of the header and node directory returns zero hits: this
## format does not store its basis. Plan 06 replaced the scan with a basis
## DERIVED from measured per-mesh bounding boxes and corroborated against two
## independent oracles to four decimals (findings row 495), and redefined
## `located` accordingly. Consumers printing `basis=located` are asserting
## "derived and corroborated", not "read from the file".
##
## Single-threaded use only, exactly like last_walk_meta.
var last_basis_located := false

## First entry whose name matches, comparing case-insensitively and adding
## the .GRN suffix when the caller omitted it; -1 when nothing matches.
## This is the ONLY way a caller-supplied model name is resolved: the string
## is compared against the pak's own 64-byte name fields and never joined
## into a path or handed to FileAccess, so an operator-supplied name cannot
## reach the filesystem.
func index_of(name: String) -> int:
	var want := name.strip_edges().to_upper()
	if want == "":
		return -1
	if not want.ends_with(".GRN"):
		want += ".GRN"
	for i in _pak.count():
		if entry_name(i).to_upper() == want:
			return i
	return -1

## Flat node directory of one entry, or [] when the declared count or the
## implied directory extent does not fit the entry's real bytes. Every node
## must carry a 0xCA5E____ tag; one that does not means this is not a
## directory and the whole read is abandoned rather than partially trusted.
func _directory(buf: PackedByteArray) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if buf.size() < SECTION_OFF_MESH + DIR_OFF + NODE_STRIDE:
		return out
	var n := buf.decode_u32(SECTION_OFF_MESH)
	if n <= 0 or n > MAX_NODES:
		return out
	var dir_off := SECTION_OFF_MESH + DIR_OFF
	if dir_off + n * NODE_STRIDE > buf.size():
		return out
	for j in n:
		var o := dir_off + j * NODE_STRIDE
		var tag := buf.decode_u32(o)
		if (tag & 0xFFFF0000) != MAGIC:
			return []
		out.append({"tag": tag, "rel": buf.decode_u32(o + 4), "children": buf.decode_u32(o + 8)})
	return out

## Payload byte length of node j: the gap to the next node with a strictly
## larger rel, or to the end of the section for the last one. Nodes that
## share a rel (a Mesh and its first child both point at the same bytes)
## are skipped rather than yielding a zero-length span.
func _span(dir: Array[Dictionary], j: int, buf_size: int) -> int:
	var r: int = dir[j]["rel"]
	for k in range(j + 1, dir.size()):
		var nr: int = dir[k]["rel"]
		if nr > r:
			return nr - r
	return buf_size - SECTION_OFF_MESH - r

## DIRECT children of node j -- one level only. _child_with_tag() searches
## the whole subtree, which is right for finding a uniquely-tagged array but
## wrong for walking ModelSection > Model > RenderPassSection > RenderPass,
## where the same tag recurs at several depths. "children" is the count of
## ALL descendants, so a direct child is reached by skipping the previous
## child's entire subtree.
func _direct_children(dir: Array[Dictionary], j: int) -> Array[int]:
	var out: Array[int] = []
	var last: int = mini(j + 1 + int(dir[j]["children"]), dir.size())
	var k := j + 1
	while k < last:
		out.append(k)
		k += 1 + int(dir[k]["children"])
	return out

## First child of node j (exclusive of j itself, within its declared
## children run) carrying `tag`, or -1.
func _child_with_tag(dir: Array[Dictionary], j: int, tag: int) -> int:
	var last: int = mini(j + 1 + int(dir[j]["children"]), dir.size())
	for k in range(j + 1, last):
		if dir[k]["tag"] == tag:
			return k
	return -1

## Typed arrays for every Mesh in the entry, concatenated into one surface:
##   positions PackedVector3Array, normals PackedVector3Array,
##   uvs PackedVector2Array, indices PackedInt32Array,
##   vertex_count, triangle_count, index_max, meshes,
##   source_positions, source_normals  (the two GRN index spaces' sizes)
## Empty Dictionary plus push_error on any malformed input.
##
## Every declared count is re-validated against the entry's real remaining
## bytes before it sizes an array or indexes into the buffer, and every
## triangle index is checked against the array it indexes before use --
## an index at or above its array's count aborts the whole decode instead
## of being clamped, because a clamped index renders a quietly wrong mesh
## and this phase exists to be able to see wrongness.
##
## uvs is currently always empty: the per-vertex texture coordinates have
## not been located in the file yet (see the 03-05 write-up "Known Stubs").
## Returning an empty array is deliberate -- inventing a UV layout that
## merely looked plausible would defeat the oracle check.
## Per-mesh UV entry byte offsets, from every MeshField in the mesh subtree
## concatenated in directory order. A mesh may carry more than one field
## (GLADIATOR mesh 0 carries two, 2322 + 896 entries), and the RenderPass
## indices address that concatenation, so they are NOT read independently.
func _uv_field_offsets(buf: PackedByteArray, dir: Array[Dictionary], j: int) -> Array[int]:
	var out: Array[int] = []
	var last: int = mini(j + 1 + int(dir[j]["children"]), dir.size())
	for k in range(j + 1, last):
		if dir[k]["tag"] != TAG_MESH_FIELD:
			continue
		var off := SECTION_OFF_MESH + int(dir[k]["rel"])
		var n := (_span(dir, k, buf.size()) - UV_FIELD_HEADER) / UV_FIELD_STRIDE
		if n <= 0 or off + UV_FIELD_HEADER + n * UV_FIELD_STRIDE > buf.size():
			continue
		for i in n:
			out.append(off + UV_FIELD_HEADER + i * UV_FIELD_STRIDE)
	return out

## face_uv[mesh][face] = PackedInt32Array([uvA, uvB, uvC]), or an empty array
## for a face no RenderPass claimed. Walks
## ModelSection > Model > RenderPassSection > RenderPass, whose leaf child
## holds {int32 count} then count x {int32 faceIndex, int32 uvA/B/C}.
##
## A RenderPass names a FormMesh SLOT, not a mesh: its first int32 indexes
## the FormMesh list, whose own first int32 is a 1-based mesh ordinal. The
## two are joined through that map rather than assumed equal, because for
## GLADIATOR they are not -- the map is [2, 0, 1].
func _face_uv_indices(buf: PackedByteArray, dir: Array[Dictionary], face_counts: Array[int]) -> Array:
	var face_uv := []
	for n in face_counts:
		var per_mesh := []
		per_mesh.resize(n)
		face_uv.append(per_mesh)
	var form_map: Array[int] = []
	for j in dir.size():
		if dir[j]["tag"] != TAG_FORM_MESH:
			continue
		var o := SECTION_OFF_MESH + int(dir[j]["rel"])
		form_map.append(-1 if o + 4 > buf.size() else buf.decode_s32(o) - 1)
	for j in dir.size():
		if dir[j]["tag"] != TAG_MODEL_SECTION:
			continue
		for model in _direct_children(dir, j):
			for pass_sec in _direct_children(dir, model):
				for rp in _direct_children(dir, pass_sec):
					var ro := SECTION_OFF_MESH + int(dir[rp]["rel"])
					if ro + 4 > buf.size():
						continue
					var slot := buf.decode_s32(ro)
					if slot < 0 or slot >= form_map.size():
						continue
					var mi := form_map[slot]
					if mi < 0 or mi >= face_counts.size():
						continue
					for leaf in _direct_children(dir, rp):
						if int(dir[leaf]["children"]) > 0:
							continue
						var off := SECTION_OFF_MESH + int(dir[leaf]["rel"])
						if off + 4 > buf.size():
							continue
						var count := buf.decode_s32(off)
						# A block claiming more faces than the mesh has is not
						# a face-UV block; skipping beats trusting it.
						if count <= 0 or count > face_counts[mi]:
							continue
						if off + 4 + count * UV_RECORD_STRIDE > buf.size():
							continue
						for i in count:
							var r := off + 4 + i * UV_RECORD_STRIDE
							var fi := buf.decode_s32(r)
							if fi < 0 or fi >= face_counts[mi]:
								continue
							face_uv[mi][fi] = PackedInt32Array([
								buf.decode_s32(r + 4), buf.decode_s32(r + 8), buf.decode_s32(r + 12)])
	return face_uv

func mesh_arrays(entry: int) -> Dictionary:
	var length := true_length(entry)
	if length <= 0:
		push_error("Models.mesh_arrays: entry %d has no derivable length" % entry)
		return {}
	if not magic_ok(entry):
		push_error("Models.mesh_arrays: entry %d is not a walkable mesh entry" % entry)
		return {}
	var buf := _pak.read_at(_pak.entry_offset(entry), length)
	if buf.size() < length:
		push_error("Models.mesh_arrays: entry %d short read (%d of %d)" % [entry, buf.size(), length])
		return {}
	var dir := _directory(buf)
	if dir.is_empty():
		push_error("Models.mesh_arrays: entry %d has no readable node directory" % entry)
		return {}

	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	# Per Godot vertex, which source position it came from and which Mesh
	# node produced it. mesh_weights() keys its per-vertex weight records on
	# the SOURCE position index, and each Mesh node has its own mesh-local
	# bone index space, so a skinned build needs both to route a weight to a
	# Godot vertex. They are emitted here, in the de-interleave loop that
	# already knows the answer, rather than reconstructed by a second walk
	# that could disagree with this one.
	var vertex_source := PackedInt32Array()
	var vertex_mesh := PackedInt32Array()
	var meshes := 0
	var src_pos := 0
	var src_nrm := 0
	var index_max := -1
	var uv_complete := true

	# Two passes. The RenderPass tree addresses meshes by ordinal, so the
	# ordinals have to exist before any UV can be resolved -- which means
	# the mesh list is settled first, using exactly the same accept/reject
	# test the de-interleave below uses, so the two orderings cannot drift.
	var mesh_nodes: Array[int] = []
	var face_counts: Array[int] = []
	for j in dir.size():
		if dir[j]["tag"] != TAG_MESH:
			continue
		var tj0 := _child_with_tag(dir, j, TAG_MESH_TRIANGLES)
		if _child_with_tag(dir, j, TAG_MESH_VERTICES) == -1 \
				or _child_with_tag(dir, j, TAG_MESH_NORMALS) == -1 or tj0 == -1:
			continue
		mesh_nodes.append(j)
		face_counts.append(maxi(0, _span(dir, tj0, buf.size()) / TRI_STRIDE))
	var face_uv := _face_uv_indices(buf, dir, face_counts)

	for mo in mesh_nodes.size():
		var j := mesh_nodes[mo]
		var uv_offsets := _uv_field_offsets(buf, dir, j)
		var vj := _child_with_tag(dir, j, TAG_MESH_VERTICES)
		var nj := _child_with_tag(dir, j, TAG_MESH_NORMALS)
		var tj := _child_with_tag(dir, j, TAG_MESH_TRIANGLES)
		if vj == -1 or nj == -1 or tj == -1:
			continue

		var v_off := SECTION_OFF_MESH + int(dir[vj]["rel"])
		var n_off := SECTION_OFF_MESH + int(dir[nj]["rel"])
		var t_off := SECTION_OFF_MESH + int(dir[tj]["rel"])
		var v_len := _span(dir, vj, buf.size())
		var n_len := _span(dir, nj, buf.size())
		var t_len := _span(dir, tj, buf.size())
		if v_len <= 0 or n_len <= 0 or t_len <= 0:
			push_error("Models.mesh_arrays: entry %d mesh at node %d has a non-positive span" % [entry, j])
			return {}
		# A span that is not a whole number of records means the stride is
		# wrong or the span was mis-derived. Integer division would drop the
		# remainder and hand back a truncated-but-plausible mesh -- exactly the
		# quietly-wrong result this decoder refuses everywhere else.
		# mesh_weights() already demands zero slack for the structurally
		# identical case; demand it here too.
		if v_len % VEC3_STRIDE != 0 or n_len % VEC3_STRIDE != 0 \
				or t_len % TRI_STRIDE != 0:
			push_error("Models.mesh_arrays: entry %d mesh at node %d has a misaligned span (v=%d n=%d t=%d against strides %d/%d/%d)" % [
				entry, j, v_len, n_len, t_len, VEC3_STRIDE, VEC3_STRIDE, TRI_STRIDE])
			return {}
		var n_pos := v_len / VEC3_STRIDE
		var n_nrm := n_len / VEC3_STRIDE
		var n_face := t_len / TRI_STRIDE
		if n_pos <= 0 or n_nrm <= 0 or n_face <= 0:
			push_error("Models.mesh_arrays: entry %d mesh at node %d resolves to zero geometry" % [entry, j])
			return {}
		# Declared extents re-checked against the buffer that actually exists.
		if v_off < 0 or v_off + n_pos * VEC3_STRIDE > buf.size() \
				or n_off < 0 or n_off + n_nrm * VEC3_STRIDE > buf.size() \
				or t_off < 0 or t_off + n_face * TRI_STRIDE > buf.size():
			push_error("Models.mesh_arrays: entry %d mesh at node %d runs past the entry" % [entry, j])
			return {}

		# De-interleave the three GRN index spaces into Godot's one.
		#
		# The key is the position INDEX plus the normal and UV BIT PATTERNS.
		# Index-space keying was measured and is wrong: it splits far too
		# much (3755 vertices against granny's 1196) because the normal and
		# UV arrays store the same value at many indices. Welding those two
		# by value reproduces granny per mesh (609 and 307 exactly, 279
		# against 280 on the head). Position stays keyed by INDEX, not by
		# value, so that two vertices that merely sit at the same point are
		# never merged -- their bone weights are keyed on the position index
		# and need not agree. Measured to cost nothing here: both keys give
		# 609/279/307.
		var tuple_to_vertex := {}
		for fi in n_face:
			var ro := t_off + fi * TRI_STRIDE
			var fuv: PackedInt32Array = face_uv[mo][fi] if face_uv[mo][fi] != null else PackedInt32Array()
			for corner in 3:
				var p := buf.decode_s32(ro + corner * 4)
				var q := buf.decode_s32(ro + 12 + corner * 4)
				if p < 0 or p >= n_pos or q < 0 or q >= n_nrm:
					push_error("Models.mesh_arrays: entry %d face %d references position %d of %d / normal %d of %d" % [entry, fi, p, n_pos, q, n_nrm])
					return {}
				var no := n_off + q * VEC3_STRIDE
				# -1 marks "this corner has no UV". It is a distinct key
				# value, so an unclaimed corner never silently welds onto a
				# textured one; it also trips uv_complete, which suppresses
				# the whole UV array rather than shipping a zero-filled one.
				var uo := -1
				if fuv.size() == 3 and fuv[corner] >= 0 and fuv[corner] < uv_offsets.size():
					uo = uv_offsets[fuv[corner]]
				else:
					uv_complete = false
				var key := "%d|%d,%d,%d|%d,%d" % [
					p, buf.decode_u32(no), buf.decode_u32(no + 4), buf.decode_u32(no + 8),
					-1 if uo < 0 else buf.decode_u32(uo),
					-1 if uo < 0 else buf.decode_u32(uo + 4)]
				var vi: int = tuple_to_vertex.get(key, -1)
				if vi == -1:
					vi = positions.size()
					tuple_to_vertex[key] = vi
					var po := v_off + p * VEC3_STRIDE
					positions.append(Vector3(buf.decode_float(po), buf.decode_float(po + 4), buf.decode_float(po + 8)))
					normals.append(Vector3(buf.decode_float(no), buf.decode_float(no + 4), buf.decode_float(no + 8)))
					uvs.append(Vector2(0.0, 0.0) if uo < 0 else Vector2(buf.decode_float(uo), buf.decode_float(uo + 4)))
					vertex_source.append(p)
					vertex_mesh.append(meshes)
				indices.append(vi)
				index_max = maxi(index_max, vi)
		meshes += 1
		src_pos += n_pos
		src_nrm += n_nrm

	if meshes == 0 or positions.is_empty() or indices.is_empty():
		push_error("Models.mesh_arrays: entry %d contains no decodable mesh" % entry)
		return {}
	# All-or-nothing: a partly-resolved UV array is worse than none, because
	# the zero-filled corners would texture as a smear that still looks like
	# geometry. Callers test uvs.is_empty().
	if not uv_complete:
		uvs = PackedVector2Array()
	return {
		"positions": positions, "normals": normals, "uvs": uvs, "indices": indices,
		"vertex_count": positions.size(), "triangle_count": indices.size() / 3,
		"index_max": index_max, "meshes": meshes,
		"source_positions": src_pos, "source_normals": src_nrm,
		"vertex_source": vertex_source, "vertex_mesh": vertex_mesh,
	}

## The one matrix converting Granny's stored coordinate system to Godot's.
##
## DERIVED FROM MEASUREMENT, not chosen because the render improved. An
## earlier revision scanned the header and node directory for nine
## consecutive orthonormal float32 and found ZERO hits, so the file does not
## carry the matrix as data and it has to be established from the geometry.
##
## Derivation. An external render of GLADIATOR.GRN reports per-mesh bounding
## boxes that climb foot-to-crown along ITS up axis: legs [-4.0335, 44.1928],
## body [32.3761, 71.5712], head [61.9141, 77.8393], feet at ~0. Computing
## the same three boxes from OUR decode reproduces those intervals on our
## STORED COMPONENT 2 (legs [-4.03, 44.20], body [32.38, 71.58], head
## [61.91, 77.84]) and on neither other component. So stored component 2 is
## up, and the mapping is (X, Y, Z) = (x, z, y).
##
## That mapping alone is a reflection (determinant -1), which would silently
## mirror the model. The determinant +1 member of the pair is the -90 degree
## rotation about X, (x, y, z) -> (x, z, -y), and it is the one used, because
## a retail asset is not stored mirrored. Handedness is NOT claimed as
## verified: the shoulder-pad oracle that was meant to settle it is its own
## Y-mirror and therefore cannot fail, so it settles nothing. What remains
## unfixed by the bbox evidence is one rotation about the up axis -- the
## facing direction. That is a separate question from handedness.
func coordinate_basis(_entry: int) -> Basis:
	last_basis_located = true
	return GRN_TO_GODOT

# ---------------------------------------------------------------------
# Skeleton decode (Plan 06).
#
# Found through the SAME flat node directory the geometry uses -- nothing
# below scans for a byte pattern:
#
#   0xCA5E0507 SkeletonSection   numTotalChildren = bones + 2
#   0xCA5E0508 BoneSection       numTotalChildren = bone count, EXACTLY
#   0xCA5E0506 Bone              one node per bone, 68 bytes, rel step 68
#
# The BoneSection and its first Bone share a rel, so the bone block starts
# at the BoneSection's own rel and runs bone_count * BONE_STRIDE bytes.
# Measured on BAT.GRN (38 bones), GLAD_SA5_SHOULDER.GRN (75) and
# GLADIATOR.GRN (68): in all three the Bone node count equals the
# BoneSection's declared numTotalChildren and every consecutive rel delta is
# exactly 68, with no exceptions.
#
# A Bone record is 68 bytes:
#   +0  int32   parent index
#   +4  3x f32  local translation
#   +16 4x f32  local rotation quaternion, stored x,y,z,w
#   +32 9x f32  local scale-shear 3x3
#
# That layout is not asserted from plausibility, it is the phase where the
# quaternion test passes and the only such phase. Across all 181 bones of
# the three sampled entries, the quaternion is unit length to within 1e-3 at
# offset +16 and at NO other phase tried: shifting the record base by -8,
# -4, +4 or +8 bytes fails 33-38 of 38, 68-75 of 75 and 68 of 68
# respectively. The test can fail, and it does, everywhere except here.
#
# ROOT CONVENTION, measured and not assumed: the root bone's parent field
# holds its OWN index (0), not -1. Exactly one such bone exists per entry
# and it is always index 0, and no bone anywhere in the corpus has a parent
# index greater than its own -- so the file order is already topological.
# The caller still sorts rather than trusting that, because "already sorted"
# is a property of three sampled entries, not a guarantee of the format.
#
# NOT STORED: an inverse-world (bind) matrix. The bone block ends exactly
# where the next directory node begins in all three entries (gap 0), and
# nothing of size bone_count * 64 exists nearby. bind_poses() therefore
# COMPOSES the world bind transform from the stored local chain. See its
# doc comment for what that costs the rest-equals-bind assertion.
const TAG_SKELETON_SECTION := 0xCA5E0507
const TAG_BONE_SECTION := 0xCA5E0508
const TAG_BONE := 0xCA5E0506
const TAG_MESH_WEIGHTS := 0xCA5E0702
const TAG_FORM_MESH_BONE_SECTION := 0xCA5E0C09
const TAG_FORM_MESH_BONE := 0xCA5E0C0A
const BONE_STRIDE := 68
## Unit-length tolerance for the stored rotation quaternion. Deliberately
## loose: it is a layout discriminator, not a precision claim, and the
## control above shows a wrong phase misses it by far more than this.
const BONE_QUAT_EPS := 0.001
## Ceiling applied to the declared bone count BEFORE it sizes anything, the
## same posture MAX_NODES takes. The largest entry sampled declares 75.
const MAX_BONES := 1 << 16
## Godot's ARRAY_BONES/ARRAY_WEIGHTS slot count without
## ARRAY_FLAG_USE_8_BONE_WEIGHTS. The format's own maximum influence count,
## measured across all five MeshWeights blocks in the sample, is 3.
const WEIGHT_SLOTS := 4

# ---------------------------------------------------------------------
# Bone-name chain (05-10, R1.4/R1.5, discharging 05-04's halt). 05-09
# independently reconfirmed this two-hop chain CONFIRMED on the mesh
# entry (the 05-09 write-up, findings row 603): FormBoneChannels[bone_i] -
# 1 selects a TransformChannel node; that node's FIRST direct child, if
# a DataExtensionReference, carries a 1-based DataExtensionIndex; that
# DataExtension's __ObjectName property resolves through the string
# table. BOTH -1s are load-bearing -- dropping either one is the exact
# bug that once resolved bone 0 to a light object (findings row 582).
# Reimplemented here in GDScript house style from this project's own
# analysis/tools/formats/grn_bonenames.py (not from any outside reader; D-21/D-23
# reserve that treatment for Iris1/AoM only).
## StringTable (0xCA5E0200) inside the SECTION_OFF_MESH node directory --
## a different node than the identically-tagged 12-byte fixed leaf
## walk() sees in the top-level header chain (TAG_SIZES); this constant
## scopes the name resolved below to that chain, not the header one.
const TAG_STRING_TABLE := 0xCA5E0200
## DataExtension family. TAG_DATA_EXTENSION (0xCA5E0F00, the extension
## node itself) is already declared below for is_animation()'s
## object-count heuristic -- reused here, not redeclared. 0xCA5E0F01 a
## property leaf whose OWN rel is a key textid; 0xCA5E0F05 the
## PropertySection container; 0xCA5E0F06 a ValueSection that shares its
## wrapping property's declared rel (the same zero-length-nested-leaf
## convention _span() already documents for BoneSection/Bone) and
## carries the value textid at its OWN rel + 4, not at the property's
## rel; 0xCA5E0F04 a DataExtensionReference whose payload is a 1-based
## DataExtensionIndex. Measured against real bytes (grn_bonenames.py
## data_extensions()): rel 16700 (F06) + 4 = 16704 resolves to string
## index 5, 'Omni03'.
const TAG_DATA_EXTENSION_PROPERTY := 0xCA5E0F01
const TAG_DATA_EXTENSION_PROPERTY_SECTION := 0xCA5E0F05
const TAG_DATA_EXTENSION_VALUE_SECTION := 0xCA5E0F06
const TAG_DATA_EXTENSION_REFERENCE := 0xCA5E0F04
## TransformChannel (0xCA5E0B00), hop 2's anchor, and FormBoneChannels
## (0xCA5E0C02), hop 1: a flat u32 array with NO header word (unlike
## StringTable/DataExtension, this node's whole payload IS the array),
## one 1-based TransformChannel index per bone.
const TAG_TRANSFORM_CHANNEL := 0xCA5E0B00
const TAG_FORM_BONE_CHANNELS := 0xCA5E0C02
## StringTable property key naming the resolved bone/object name.
const OBJECT_NAME_KEY := "__ObjectName"

# REST_BIND_ULPS, REST_BIND_EPS, last_bind_maxmag / _ulp / _depth and
# f32_ulp() stood here. All were machinery for sizing the rest-equals-bind
# tolerance, and all went when that assertion was removed for being
# circular. The epsilon was honestly derived; the comparison it sized was
# vacuous, which makes the whole apparatus dead weight rather than a
# safeguard worth keeping for a future caller.

## Directory index of the BoneSection node, or -1. Requires the
## SkeletonSection to be present and the BoneSection to fall inside its
## declared children run, so a stray tag elsewhere in the file cannot be
## mistaken for the skeleton.
func _bone_section(dir: Array[Dictionary]) -> int:
	for j in dir.size():
		if dir[j]["tag"] != TAG_SKELETON_SECTION:
			continue
		var last: int = mini(j + 1 + int(dir[j]["children"]), dir.size())
		for k in range(j + 1, last):
			if dir[k]["tag"] == TAG_BONE_SECTION:
				return k
	return -1

## Contiguous raw bone bytes exactly as stored: parent indices, translations,
## rotations and scale-shears in file order, bone_count * BONE_STRIDE of
## them. Empty on any malformed input.
##
## This is what the `bones` parity fact line hashes. It is a byte-range read
## on both sides of the harness, so the Python side needs no second matrix
## decoder to agree with the Godot one (plan 03-04, Pitfall 8).
func bone_bytes(entry: int) -> PackedByteArray:
	var empty := PackedByteArray()
	var length := true_length(entry)
	if length <= 0 or not magic_ok(entry):
		return empty
	var buf := _pak.read_at(_pak.entry_offset(entry), length)
	if buf.size() < length:
		return empty
	var dir := _directory(buf)
	if dir.is_empty():
		return empty
	var bs := _bone_section(dir)
	if bs == -1:
		return empty
	var n := int(dir[bs]["children"])
	if n <= 0 or n > MAX_BONES:
		push_error("Models.bone_bytes: entry %d declares %d bones" % [entry, n])
		return empty
	var off := SECTION_OFF_MESH + int(dir[bs]["rel"])
	# The declared count is re-validated against the bytes that actually
	# remain before it sizes anything -- an over-large count returns empty
	# rather than allocating for it (threat T-03-14).
	if off < 0 or off + n * BONE_STRIDE > buf.size():
		push_error("Models.bone_bytes: entry %d bone block (%d bones at %d) runs past the entry (%d bytes)" % [
			entry, n, off, buf.size()])
		return empty
	return buf.slice(off, off + n * BONE_STRIDE)

## Single u32 payload word at node j's own rel, or -1 when the read would
## run past the entry. -1 is an unambiguous sentinel: decode_u32 never
## returns a negative value, so it cannot collide with a real payload.
func _node_u32(buf: PackedByteArray, dir: Array[Dictionary], j: int) -> int:
	var off := SECTION_OFF_MESH + int(dir[j]["rel"])
	if off < 0 or off + 4 > buf.size():
		return -1
	return buf.decode_u32(off)

## `strs[textid]`, or "" when textid is -1 (the _node_u32 sentinel) or out
## of range. "" also happens to be the genuine value of string index 0
## (StringTable's own empty-string entry), so this cannot distinguish
## "resolved to the empty string" from "did not resolve" -- callers below
## only ever compare the result against a specific key name or fold it
## into a name field where both cases already mean the honest-empty
## contract, so the ambiguity is harmless here.
func _resolve_textid(strs: PackedStringArray, textid: int) -> String:
	if textid < 0 or textid >= strs.size():
		return ""
	return strs[textid]

## StringTable (0xCA5E0200) decode: dword numEntries, dword unknown, then
## numEntries NUL-terminated strings. Index 0 (the empty string) is a
## valid, decodable result, not a sentinel for "missing". The declared
## count is re-validated against the node's derived span -- each string
## needs at least 1 byte (its own NUL) -- before it sizes anything, and
## a truncated string (no NUL before the span ends) refuses the whole
## table rather than returning a partial one. Empty plus push_error on
## any malformed input, the same posture bone_bytes() takes.
func strings(entry: int) -> PackedStringArray:
	var empty := PackedStringArray()
	var length := true_length(entry)
	if length <= 0 or not magic_ok(entry):
		return empty
	var buf := _pak.read_at(_pak.entry_offset(entry), length)
	if buf.size() < length:
		return empty
	var dir := _directory(buf)
	if dir.is_empty():
		return empty
	for j in dir.size():
		if dir[j]["tag"] != TAG_STRING_TABLE:
			continue
		var off := SECTION_OFF_MESH + int(dir[j]["rel"])
		if off < 0 or off + 8 > buf.size():
			push_error("Models.strings: entry %d string table header runs past the entry" % entry)
			return empty
		var n := buf.decode_u32(off)
		var span_bytes := _span(dir, j, buf.size())
		if n < 0 or 8 + n > span_bytes:
			push_error("Models.strings: entry %d string table declares %d entries against a %d-byte span" % [
				entry, n, span_bytes])
			return empty
		var out := PackedStringArray()
		var pos := off + 8
		var end := off + span_bytes
		for i in n:
			var e := pos
			while e < end and buf[e] != 0:
				e += 1
			if e >= end:
				push_error("Models.strings: entry %d string %d runs past the table's span" % [entry, i])
				return empty
			out.append(buf.slice(pos, e).get_string_from_utf8())
			pos = e + 1
		return out
	return empty

## One entry per 0xCA5E0F00 DataExtension node, in directory order --
## __ObjectName's resolved string when the extension carries that
## property, "" when it does not (an object without the key yields an
## empty string in place, the array is never shortened). Nesting is
## three levels deep, not a sibling triple (see TAG_DATA_EXTENSION_*
## constants' doc comment): DataExtension -> PropertySection (direct
## child) -> Property (direct child of the section) -> ValueSection
## (somewhere in the property's own descendant span) -> the value
## textid at the ValueSection's rel + 4.
func object_names(entry: int) -> PackedStringArray:
	var empty := PackedStringArray()
	var length := true_length(entry)
	if length <= 0 or not magic_ok(entry):
		return empty
	var buf := _pak.read_at(_pak.entry_offset(entry), length)
	if buf.size() < length:
		return empty
	var dir := _directory(buf)
	if dir.is_empty():
		return empty
	var strs := strings(entry)
	var out := PackedStringArray()
	for j in dir.size():
		if dir[j]["tag"] != TAG_DATA_EXTENSION:
			continue
		var name := ""
		for sk in _direct_children(dir, j):
			if dir[sk]["tag"] != TAG_DATA_EXTENSION_PROPERTY_SECTION:
				continue
			for kn in _direct_children(dir, sk):
				if dir[kn]["tag"] != TAG_DATA_EXTENSION_PROPERTY:
					continue
				var key := _resolve_textid(strs, _node_u32(buf, dir, kn))
				if key != OBJECT_NAME_KEY:
					continue
				var value_section := -1
				var last: int = mini(kn + 1 + int(dir[kn]["children"]), dir.size())
				for vk in range(kn + 1, last):
					if dir[vk]["tag"] == TAG_DATA_EXTENSION_VALUE_SECTION:
						value_section = vk
						break
				if value_section == -1:
					continue
				var voff := SECTION_OFF_MESH + int(dir[value_section]["rel"]) + 4
				if voff + 4 > buf.size():
					continue
				name = _resolve_textid(strs, buf.decode_u32(voff))
		out.append(name)
	return out

## Resolved bone name per bone in bones() order, through the two-hop
## chain documented on the tag constants above: FormBoneChannels[bone_i]
## - 1 selects a TransformChannel; its first direct child, if a
## DataExtensionReference, carries ref_raw; ref_raw - 1 indexes
## object_names(). An unresolvable bone (out-of-range hop, a
## TransformChannel whose first child is not a DataExtensionReference,
## or an object with no __ObjectName) yields "" -- nothing is
## substituted for it (D-19).
func bone_names(entry: int) -> PackedStringArray:
	var empty := PackedStringArray()
	var length := true_length(entry)
	if length <= 0 or not magic_ok(entry):
		return empty
	var buf := _pak.read_at(_pak.entry_offset(entry), length)
	if buf.size() < length:
		return empty
	var dir := _directory(buf)
	if dir.is_empty():
		return empty
	var bone_count := bone_bytes(entry).size() / BONE_STRIDE
	if bone_count <= 0:
		return empty
	var names := object_names(entry)

	# Hop 2's raw ingredient: one entry per TransformChannel node, in
	# directory order, its first direct child's DataExtensionReference
	# payload dword, or -1 when the first child is not that tag.
	var tc_refs := PackedInt32Array()
	for j in dir.size():
		if dir[j]["tag"] != TAG_TRANSFORM_CHANNEL:
			continue
		var kids := _direct_children(dir, j)
		if not kids.is_empty() and dir[kids[0]]["tag"] == TAG_DATA_EXTENSION_REFERENCE:
			tc_refs.append(_node_u32(buf, dir, kids[0]))
		else:
			tc_refs.append(-1)

	# Hop 1's raw ingredient: FormBoneChannels' payload, a flat u32 array
	# with no header word, one 1-based TransformChannel index per bone.
	var fbc := PackedInt32Array()
	for j in dir.size():
		if dir[j]["tag"] != TAG_FORM_BONE_CHANNELS:
			continue
		var off := SECTION_OFF_MESH + int(dir[j]["rel"])
		var span_bytes := _span(dir, j, buf.size())
		var count := span_bytes / 4
		if off < 0 or count < 0 or off + count * 4 > buf.size():
			push_error("Models.bone_names: entry %d FormBoneChannels runs past the entry" % entry)
			return empty
		for i in count:
			fbc.append(buf.decode_u32(off + i * 4))
		break

	var out := PackedStringArray()
	out.resize(bone_count)
	for i in bone_count:
		out[i] = ""
		if i >= fbc.size():
			continue
		var channel := fbc[i] - 1
		if channel < 0 or channel >= tc_refs.size():
			continue
		var ref_raw := tc_refs[channel]
		if ref_raw < 0:
			continue
		var ext := ref_raw - 1
		if ext < 0 or ext >= names.size():
			continue
		out[i] = names[ext]
	return out

## One Dictionary per bone in Granny's own file order:
##   name        PackedByteArray -- the resolved bone name's UTF-8 bytes,
##               via bone_names() (the two-hop DataExtension chain 05-09
##               reconfirmed CONFIRMED), when the chain resolves this
##               bone; PackedByteArray() (honestly empty), unconditionally,
##               when it does not. The 68-byte bone record itself has no
##               name field -- this is resolved through a separate chain,
##               not read from the record. No heuristic fallback is ever
##               substituted for an unresolved bone (D-19): a name here is
##               either the chain's own answer or nothing.
##   parent      the parent index EXACTLY AS STORED, self-referential for
##               the root (measured: root's parent field is its own index,
##               not -1)
##   parent_effective  -1 for the root, the stored value otherwise -- the
##               normalised form a topological sort wants, derived here once
##               so no caller re-derives it differently
##   position    Vector3, rotation Quaternion, scale_shear PackedFloat32Array
##   rest        Transform3D, the local rest transform T * R * SS
##
## Empty Array plus push_error on any malformed input: a declared count that
## does not fit, a parent index outside the bone range, or a rotation that is
## not a unit quaternion. A bad parent is REJECTED, never clamped -- a
## clamped parent silently reparents a limb and still renders.
##
## SCALE-SHEAR CONVENTION, recorded as unfalsifiable on this corpus: the
## nine floats are read as a row-major 3x3. Every scale-shear in all 181
## sampled bones is the identity to within 1e-6 (max component magnitude
## 1.0000009), so row-major and column-major produce the same matrix here
## and this corpus cannot distinguish them. Stated rather than hidden.
func bones(entry: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var raw := bone_bytes(entry)
	if raw.is_empty():
		return out
	var n := raw.size() / BONE_STRIDE
	var names := bone_names(entry)
	for i in n:
		var o := i * BONE_STRIDE
		var parent := raw.decode_s32(o)
		if parent < 0 or parent >= n:
			push_error("Models.bones: entry %d bone %d has out-of-range parent %d (of %d)" % [
				entry, i, parent, n])
			return []
		var pos := Vector3(raw.decode_float(o + 4), raw.decode_float(o + 8), raw.decode_float(o + 12))
		var q := Quaternion(raw.decode_float(o + 16), raw.decode_float(o + 20),
			raw.decode_float(o + 24), raw.decode_float(o + 28))
		var qlen := sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w)
		if is_nan(qlen) or absf(qlen - 1.0) > BONE_QUAT_EPS:
			push_error("Models.bones: entry %d bone %d rotation is not a unit quaternion (|q|=%f)" % [
				entry, i, qlen])
			return []
		var ss := PackedFloat32Array()
		ss.resize(9)
		for k in 9:
			ss[k] = raw.decode_float(o + 32 + k * 4)
		# Row-major storage into Godot's column-taking Basis constructor.
		var b := Basis(Vector3(ss[0], ss[3], ss[6]), Vector3(ss[1], ss[4], ss[7]), Vector3(ss[2], ss[5], ss[8]))
		out.append({
			"name": names[i].to_utf8_buffer() if i < names.size() else PackedByteArray(),
			"parent": parent,
			"parent_effective": -1 if parent == i else parent,
			"position": pos,
			"rotation": q,
			"scale_shear": ss,
			"rest": Transform3D(Basis(q) * b, pos),
		})
	return out

## World-space bind transform per bone, in the same file order bones()
## returns, composed parent-first from the stored local chain. Empty plus
## push_error on a cycle or a bad parent.
##
## WHY THIS IS COMPOSED AND NOT READ: the format stores no inverse-world
## matrix (see the section comment above -- the bone block ends flush
## against the next directory node in every sampled entry, and no
## bone_count * 64 region exists). So no pair of independently stored
## quantities exists in this file to check the composition against.
##
## This function once also derived a REST_BIND_EPS tolerance, for an
## assertion comparing its output against Skeleton3D's own global rest. That
## assertion has been removed: both sides composed the SAME stored local
## rests and the Skin bind was defined as the inverse of one of them, so it
## was true by construction and could not fail. The tolerance went with it,
## because a carefully derived epsilon for a vacuous comparison is still a
## vacuous comparison.
func bind_poses(entry: int) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	var bl := bones(entry)
	if bl.is_empty():
		return out
	var n := bl.size()
	var world: Array[Transform3D] = []
	var done := PackedByteArray()
	world.resize(n)
	done.resize(n)
	for i in n:
		if done[i] != 0:
			continue
		# Iterative parent walk with a step budget of n: a chain longer than
		# the bone count can only mean a cycle, so the traversal cannot loop
		# forever on a hostile file (threat T-03-15).
		var chain: Array[int] = []
		var c := i
		var steps := 0
		while done[c] == 0:
			if steps > n:
				push_error("Models.bind_poses: entry %d bone %d sits on a parent cycle" % [entry, i])
				return []
			chain.append(c)
			var p: int = bl[c]["parent_effective"]
			if p == -1:
				break
			if chain.has(p):
				push_error("Models.bind_poses: entry %d bone %d sits on a parent cycle" % [entry, i])
				return []
			c = p
			steps += 1
		chain.reverse()
		for b in chain:
			var p2: int = bl[b]["parent_effective"]
			if p2 == -1:
				world[b] = bl[b]["rest"]
			else:
				world[b] = world[p2] * bl[b]["rest"]
			done[b] = 1
	for i in n:
		out.append(world[i])
	return out

## One Dictionary per Mesh node, in the SAME order mesh_arrays() walks them:
##   count      per-vertex weight records, which equals that mesh's source
##              position count
##   highest    the block's own declared highest mesh-local bone index
##   bones      PackedInt32Array, WEIGHT_SLOTS per source vertex, MESH-LOCAL
##              bone indices, zero-padded
##   weights    PackedFloat32Array, WEIGHT_SLOTS per source vertex, stored
##              values NOT renormalised
##   bone_map   PackedInt32Array, mesh-local bone index -> Granny file bone
##              index
##
## Layout, measured: a MeshWeights payload is {int32 count, int32
## highestBoneIndex, int32 unknown} then, per vertex, {int32 influences,
## influences * (int32 mesh-local bone, float32 weight)}. The confirmation is
## that the bytes consumed equal the node's derived span EXACTLY -- zero
## slack on all five blocks across the three sampled entries -- and that
## every vertex's weights sum to 1.0 within 1e-4. A wrong stride leaves
## slack or overruns.
##
## bone_map comes from the FormMeshBone (0xCA5E0C0A) children of a
## FormMeshBoneSection (0xCA5E0C09), each an int32 Granny bone index. Which
## section belongs to which mesh is NOT positional: it is the section whose
## child count equals highestBoneIndex + 1. On the sample that pairing is
## unique in every entry (GLADIATOR's three meshes declare highest 44/3/9
## against sections of 45/4/10) and it is checked for uniqueness at run time
## -- an ambiguous pairing returns empty rather than picking one.
func mesh_weights(entry: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var length := true_length(entry)
	if length <= 0 or not magic_ok(entry):
		return out
	var buf := _pak.read_at(_pak.entry_offset(entry), length)
	if buf.size() < length:
		return out
	var dir := _directory(buf)
	if dir.is_empty():
		return out
	var bl_count := bone_bytes(entry).size() / BONE_STRIDE
	if bl_count <= 0:
		return out

	# Every FormMeshBone list in the entry, by its own length.
	var lists: Array[PackedInt32Array] = []
	for j in dir.size():
		if dir[j]["tag"] != TAG_FORM_MESH_BONE_SECTION:
			continue
		var lst := PackedInt32Array()
		var last: int = mini(j + 1 + int(dir[j]["children"]), dir.size())
		for k in range(j + 1, last):
			if dir[k]["tag"] != TAG_FORM_MESH_BONE:
				continue
			var o := SECTION_OFF_MESH + int(dir[k]["rel"])
			if o < 0 or o + 4 > buf.size():
				push_error("Models.mesh_weights: entry %d FormMeshBone at %d runs past the entry" % [entry, o])
				return []
			var g := buf.decode_s32(o)
			if g < 0 or g >= bl_count:
				push_error("Models.mesh_weights: entry %d FormMeshBone references bone %d of %d" % [
					entry, g, bl_count])
				return []
			lst.append(g)
		lists.append(lst)

	for j in dir.size():
		if dir[j]["tag"] != TAG_MESH:
			continue
		# Skipped for exactly the reason mesh_arrays() skips it, so the two
		# lists stay index-for-index parallel. mesh_arrays()' vertex_mesh
		# field indexes INTO this array, so a Mesh node counted by one and
		# not the other would silently attach every vertex of every later
		# mesh to the wrong bone list.
		if _child_with_tag(dir, j, TAG_MESH_VERTICES) == -1 \
				or _child_with_tag(dir, j, TAG_MESH_NORMALS) == -1 \
				or _child_with_tag(dir, j, TAG_MESH_TRIANGLES) == -1:
			continue
		var wj := _child_with_tag(dir, j, TAG_MESH_WEIGHTS)
		if wj == -1:
			push_error("Models.mesh_weights: entry %d mesh at node %d has no MeshWeights child" % [entry, j])
			return []
		var off := SECTION_OFF_MESH + int(dir[wj]["rel"])
		var span := _span(dir, wj, buf.size())
		if off < 0 or span <= 12 or off + span > buf.size():
			push_error("Models.mesh_weights: entry %d MeshWeights at node %d has an unusable span %d" % [
				entry, wj, span])
			return []
		var count := buf.decode_s32(off)
		var highest := buf.decode_s32(off + 4)
		if count <= 0 or highest < 0 or count * 8 > span:
			push_error("Models.mesh_weights: entry %d MeshWeights at node %d declares count=%d highest=%d against span %d" % [
				entry, wj, count, highest, span])
			return []
		var bones_out := PackedInt32Array()
		var weights_out := PackedFloat32Array()
		bones_out.resize(count * WEIGHT_SLOTS)
		weights_out.resize(count * WEIGHT_SLOTS)
		var p := off + 12
		var end := off + span
		for v in count:
			if p + 4 > end:
				push_error("Models.mesh_weights: entry %d MeshWeights at node %d truncated at vertex %d" % [entry, wj, v])
				return []
			var infl := buf.decode_s32(p)
			p += 4
			if infl <= 0 or infl > WEIGHT_SLOTS or p + infl * 8 > end:
				push_error("Models.mesh_weights: entry %d vertex %d declares %d influences (max %d)" % [
					entry, v, infl, WEIGHT_SLOTS])
				return []
			for s in infl:
				var lb := buf.decode_s32(p)
				var w := buf.decode_float(p + 4)
				p += 8
				if lb < 0 or lb > highest:
					push_error("Models.mesh_weights: entry %d vertex %d references local bone %d, above the declared highest %d" % [
						entry, v, lb, highest])
					return []
				bones_out[v * WEIGHT_SLOTS + s] = lb
				weights_out[v * WEIGHT_SLOTS + s] = w
		if p != end:
			push_error("Models.mesh_weights: entry %d MeshWeights at node %d consumed %d of %d bytes" % [
				entry, wj, p - off, span])
			return []
		# The pairing rule, and its own uniqueness check.
		var want := highest + 1
		var pick := -1
		var hits := 0
		for li in lists.size():
			if lists[li].size() == want:
				hits += 1
				pick = li
		if hits != 1:
			push_error("Models.mesh_weights: entry %d mesh at node %d needs a %d-bone FormMeshBone list; %d sections match" % [
				entry, j, want, hits])
			return []
		out.append({
			"count": count, "highest": highest,
			"bones": bones_out, "weights": weights_out,
			"bone_map": lists[pick],
		})
		lists.remove_at(pick)
	return out

# ---------------------------------------------------------------------
# Animation clip decode (Plan 05-05, R1.5). kind=65 entries.
#
# CORRECTION: the phase-05 research notes records 0xCA5E1204 (AnimationTransformTrackKeys)
# as "genuinely absent" from Sacred's motion bytes. That was measured against
# entry 2845, GLADIATOR.GRN's kind=65 counterpart -- which is a MODEL (five
# Mesh nodes, no per-bone animation records), not a clip. A clip such as
# entry 2847 (GLAD_ATTACK_1H_A.GRN) carries exactly one 0xCA5E1204 record per
# bone. the 05-02 write-up corrected this in the findings log (row 589); this
# section must not re-inherit the "absent" claim.
#
# The animation node tree, reached through _directory()/_direct_children()
# exactly as geometry and bones already are -- no byte-pattern scan:
#
#   AnimationSection (0xCA5E1205)
#     -> Animation (0xCA5E1200), a direct child
#        -> AnimationTransformTrackSection (0xCA5E1203), a direct child
#           -> AnimationTransformTrackKeys (0xCA5E1204), one direct child per bone
#
# Per-bone record layout (zero-slack reconciled by 05-02 against Sacred's own
# bytes on three sampled clips -- 2847/2899/2903, all three 100% unit-quaternion
# at the degeneracy floor ANIM_QUAT_MIN below):
#
#   +0   u32     id                (carried through as data, never an index --
#                                    05-02's --idjoin REFUTED it as a cross-file
#                                    join key, BAT.GRN control arm included)
#   +4   5x u32   unknown
#   +24  u32     numTranslates (nt)
#   +28  u32     numQuaternions (nq)
#   +32  u32     numUnknowns (nu)
#   +36  4x u32   unknown
#   +52  nt x f32  translate-track times
#        nq x f32  rotation-track times
#        nu x f32  "other"-track times
#        nt x 3 f32  translations
#        nq x 4 f32  rotations, stored x,y,z,w -- same order bones() uses
#        nu x 3 f32  "other" payload, uninterpreted
#   + ANIM_RECORD_TRAILER (48) undocumented, measured, count-independent
#     fixed bytes -- part of the size a record must reconcile to exactly,
#     never itself decoded. An earlier search attempt folded these bytes
#     into the header instead (widening the header bound to reach them
#     directly); that produced 8 zero-slack survivors that ALL failed the
#     unit-quaternion check, which is how 05-02 confirmed this is a
#     trailing block and not part of the header/field region.
#
# LICENCE BOUNDARY (D-21, D-23): this layout is attributed to 05-02's
# zero-slack reconciliation against Sacred's own bytes, not lifted from
# either github.com/SiENcE/Iris1 (GPL v2) or the AoM Model Plugin (no
# licence file, so used on the same all-rights-reserved terms as Iris1).
# Both were consulted during planning only as documentation of node-type
# NAMES, which are facts about the format -- no code, comment or structure
# from either is reproduced here; the decode below is this codebase's own.
const TAG_ANIMATION_SECTION := 0xCA5E1205            # AnimationSection
const TAG_ANIMATION := 0xCA5E1200                    # Animation
const TAG_ANIM_VECTOR_TRACK_SECTION := 0xCA5E1201    # AnimationVectorTrackSection
const TAG_ANIM_VECTOR_TRACK_KEYS := 0xCA5E1202       # AnimationVectorTrackKeys
const TAG_ANIM_TRANSFORM_TRACK_SECTION := 0xCA5E1203 # AnimationTransformTrackSection
const TAG_ANIM_TRANSFORM_TRACK_KEYS := 0xCA5E1204    # AnimationTransformTrackKeys
## DataExtension directory node. Same numeric tag TAG_SIZES already uses for
## the unrelated 12-byte chunk-stream leaf family walk() reads -- a distinct
## context (flat node directory vs. header chain), so this is a second,
## non-conflicting named use of the same real on-disk tag value, not a
## redefinition.
const TAG_DATA_EXTENSION := 0xCA5E0F00

## `section_offset(kind) = magic_offset(kind) + 376`, confirmed corpus-wide
## (4991/4993 walkable entries, the 05-02 write-up) and shown falsifiable (a
## real 1- or 4-byte desync collapses every directory read to baddir). For
## kind=64 this reconciles the pre-existing SECTION_OFF_MESH=1634
## (1258+376); for kind=65 it resolves to 320+376=696. -1 when the entry has
## no kind-scoped magic offset.
##
## Plan 05-05's wave_note: if a future plan's Models.section_offset() has a
## different body, that is a rival spelling of this rule and must not exist.
const SECTION_OFF_DELTA := 376

func section_offset(entry: int) -> int:
	var off := magic_offset(entry)
	if off == -1:
		return -1
	return off + SECTION_OFF_DELTA

## Ceiling on any of a clip record's declared counts (numTranslates/
## numQuaternions/numUnknowns), applied BEFORE a count sizes anything -- the
## same posture MAX_NODES and MAX_BONES already take. The largest sampled
## clip (2847) declares 920 quaternion keys; this leaves generous headroom.
const MAX_KEYFRAMES := 1 << 20

const ANIM_RECORD_HEADER := 52
const ANIM_OFF_NUM_TRANSLATES := 24
const ANIM_OFF_NUM_QUATERNIONS := 28
const ANIM_OFF_NUM_UNKNOWNS := 32
## THERE IS NO TRAILER. This constant and its bimodal 48/72 successor were
## both wrong, and row 767 says why: the residual they were absorbing is
## 24 * numUnknowns, so it is not a fixed block at all. See
## ANIM_UNKNOWN_STRIDE.
##
## The arithmetic hid it twice. 05-02 sampled three clips whose records all
## carried nu=2, and 24*2 = 48, which reads exactly like a constant trailer.
## Row 764 then found entries with nu=3 (24*3 = 72) and concluded the value
## was bimodal -- still a constant, just two of them. Only a clip whose nu
## VARIES between records could expose it, and the WOLF family is precisely
## that: 46 records spanning 17 apparent widths, which row 764 refused as
## "internally inconsistent" when they were the one shape telling the truth.
## The lesson is in the sampling, not the algebra: every entry that agreed
## was an entry with a constant nu.
const ANIM_RECORD_TRAILER := 0
## Bytes per "unknown" track element: 4 of time plus 36 of payload. 36 bytes
## is a 3x3 matrix, which is what Granny's transform triple carries beside a
## translation and a rotation -- scale-shear. Reconciles zero-slack on every
## record of every clip that decodes, including all 46 records of
## WOLF_ATTACK_BH_A where a constant-trailer model cannot.
const ANIM_UNKNOWN_STRIDE := 40

## Track-quaternion DEGENERACY floor, and deliberately not a tolerance.
##
## WHAT THIS USED TO BE (ANIM_QUAT_EPS = 0.07). A unit-length tolerance doing
## two jobs at once: validating the record LAYOUT, and gating each entry. It
## was good at the first -- 05-02 ranked every rival (header, field-offset)
## candidate by the epsilon it would need and found the documented layout
## isolated at 0.0611 with a 7x gap to the next at 0.4142. It was bad at the
## second, and that cost 643 clips: per-entry worst-case drift is HEAVY
## TAILED. Measured across every refused entry, the deviation decays smoothly
## from 0.06 to 0.66 with NO gap anywhere -- one population of quantization
## drift, not two separable groups. There is therefore no threshold to pick,
## and picking one anyway is how 0.07 (set from a three-clip sample whose
## worst was 0.0611) came to refuse 491 entries sitting just above it.
##
## WHY THE LAYOUT JOB IS NO LONGER NEEDED HERE. Row 767 established that a
## record reconciles EXACTLY: 52 + 16nt + 20nq + 40nu == span, zero slack, on
## every record of every entry. A wrong header or field offset leaves slack,
## so size reconciliation is a strictly stronger layout discriminator than the
## quaternion norm ever was, and it runs first. This constant is relieved of
## that duty.
##
## WHAT REMAINS. A quaternion is unusable only when it cannot be normalized --
## NaN, or a length so near zero that the direction is noise. That is a real
## refusal and stays. Everything else is normalized on read, which is what
## ModelView already did per key before handing them to Godot.
const ANIM_QUAT_MIN := 0.5

## Generalises _directory() to an arbitrary section offset. _directory()
## itself stays hardcoded to SECTION_OFF_MESH (kind=64 geometry only) so
## every existing mesh/skeleton/weight call site, and the pre-existing
## `models`/`bones` fact-line md5s, are untouched by this plan. kind=65
## clips need section_offset(entry) instead -- this is that rule applied to
## the identical flat-directory shape _directory() already reads.
func _directory_sec(buf: PackedByteArray, sec: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if sec < 0 or buf.size() < sec + DIR_OFF + NODE_STRIDE:
		return out
	var n := buf.decode_u32(sec)
	if n <= 0 or n > MAX_NODES:
		return out
	var dir_off := sec + DIR_OFF
	if dir_off + n * NODE_STRIDE > buf.size():
		return out
	for j in n:
		var o := dir_off + j * NODE_STRIDE
		var tag := buf.decode_u32(o)
		if (tag & 0xFFFF0000) != MAGIC:
			return []
		out.append({"tag": tag, "rel": buf.decode_u32(o + 4), "children": buf.decode_u32(o + 8)})
	return out

## _span()'s twin for an arbitrary section offset, same rule: the gap to
## the next node with a strictly larger rel, or to the end of the section.
func _span_sec(dir: Array[Dictionary], j: int, buf_size: int, sec: int) -> int:
	var r: int = dir[j]["rel"]
	for k in range(j + 1, dir.size()):
		var nr: int = dir[k]["rel"]
		if nr > r:
			return nr - r
	return buf_size - sec - r

## The structural model/clip discriminator 05-02 measured (grn_motion.py
## --census, 0 disagreements across all 4991 walkable entries, both kinds):
## an entry is a clip when it has no Mesh nodes at all AND its
## DataExtension count equals its Bone count; when those two independent
## predicates disagree, the entry is neither classified and this returns
## false rather than guessing. Computed purely from the entry's own
## directory structure -- no reference to entry_name(), per D-03, so a
## second character needs only data, never a new branch here. False for an
## out-of-range or non-walkable entry.
func is_animation(entry: int) -> bool:
	var length := true_length(entry)
	if length <= 0 or not magic_ok(entry):
		return false
	var buf := _pak.read_at(_pak.entry_offset(entry), length)
	if buf.size() < length:
		return false
	var dir := _directory_sec(buf, section_offset(entry))
	if dir.is_empty():
		return false
	var meshes := 0
	var bone_n := 0
	var objects := 0
	for node in dir:
		match int(node["tag"]):
			TAG_MESH:
				meshes += 1
			TAG_BONE:
				bone_n += 1
			TAG_DATA_EXTENSION:
				objects += 1
	var clip_by_meshes := meshes == 0
	var clip_by_objeqbones := objects == bone_n
	return clip_by_meshes == clip_by_objeqbones and clip_by_meshes

## Kind-scoped twin of index_of(): the first entry whose name matches AND
## whose kind is KIND_MOTION. This exists because models.pak carries
## GLADIATOR.GRN TWICE -- entry 589 (kind=64 mesh) and entry 2845 (kind=65,
## itself a MODEL per is_animation() above, not a clip) -- so
## index_of("GLADIATOR.GRN") returns 589 and any animation lookup built on
## it would silently resolve to the wrong entry. Carries index_of()'s
## security constraint verbatim: the string is compared against the pak's
## own 64-byte name fields and never joined into a path or handed to
## FileAccess.
func clip_index_of(name: String) -> int:
	var want := name.strip_edges().to_upper()
	if want == "":
		return -1
	if not want.ends_with(".GRN"):
		want += ".GRN"
	for i in _pak.count():
		if kind_of(i) == KIND_MOTION and entry_name(i).to_upper() == want:
			return i
	return -1

## The decode. Reaches TAG_ANIMATION_SECTION through the entry's own
## directory, then its direct child TAG_ANIMATION, then that node's direct
## child TAG_ANIM_TRANSFORM_TRACK_SECTION, then that section's direct
## TAG_ANIM_TRANSFORM_TRACK_KEYS children -- one per bone. Every hop is
## _direct_children()/_child_with_tag() over the decoded directory, exactly
## as bones()/mesh_arrays() already reach their nodes; never a byte-pattern
## scan.
##
## For each record: derive its span with _span_sec(), read the three count
## fields, and require the implied byte size (header + tracks + payload +
## ANIM_RECORD_TRAILER) to equal that span EXACTLY. One byte of slack
## refuses the WHOLE entry with push_error() naming the record index, span
## and implied size -- never a partial decode. Every declared count is
## bounded by MAX_KEYFRAMES and re-checked against the span before it sizes
## anything.
##
## Returns {bones: int, records: Array[Dictionary], length: float,
## source: String} where each record is {id: int, times_pos:
## PackedFloat32Array, times_rot: PackedFloat32Array, times_other:
## PackedFloat32Array, positions: PackedVector3Array,
## rotations: Array[Quaternion], others: PackedVector3Array}. Empty
## Dictionary plus push_error() on any malformed input, including a
## KIND_MOTION entry that is a model rather than a clip (no per-bone
## records) -- decoding a non-clip is a caller error, not a partial
## success. Every decoded rotation is checked unit-length to within
## ANIM_QUAT_EPS (see that constant's own doc comment for why it is not
## BONE_QUAT_EPS) and a clip whose rotations are not unit quaternions is
## refused whole, matching bones()'s existing posture.
##
## `desync` displaces each record's computed base offset by that many
## bytes before its count fields are read -- the Godot-side twin of
## analysis/tools/formats/grn_tagwalk.py's clip_decode(desync=) (Plan 05-05 Task
## 2's --clip-falsify=N counterfactual). 0 (the default) is every
## existing caller's behaviour, unchanged.
func clip(entry: int, desync: int = 0) -> Dictionary:
	var length := true_length(entry)
	if length <= 0 or not magic_ok(entry):
		push_error("Models.clip: entry %d is not a walkable motion entry" % entry)
		return {}
	var buf := _pak.read_at(_pak.entry_offset(entry), length)
	if buf.size() < length:
		push_error("Models.clip: entry %d short read (%d of %d)" % [entry, buf.size(), length])
		return {}
	var sec := section_offset(entry)
	var dir := _directory_sec(buf, sec)
	if dir.is_empty():
		push_error("Models.clip: entry %d has no readable node directory" % entry)
		return {}

	var bone_count := 0
	for node in dir:
		if int(node["tag"]) == TAG_BONE:
			bone_count += 1

	var sec_j := -1
	for j in dir.size():
		if int(dir[j]["tag"]) == TAG_ANIMATION_SECTION:
			sec_j = j
			break
	if sec_j == -1:
		push_error("Models.clip: entry %d has no AnimationSection node" % entry)
		return {}
	var anim_j := _child_with_tag(dir, sec_j, TAG_ANIMATION)
	if anim_j == -1:
		push_error("Models.clip: entry %d AnimationSection has no Animation child" % entry)
		return {}
	var tts_j := _child_with_tag(dir, anim_j, TAG_ANIM_TRANSFORM_TRACK_SECTION)
	if tts_j == -1:
		push_error("Models.clip: entry %d Animation has no AnimationTransformTrackSection child" % entry)
		return {}
	var key_nodes: Array[int] = []
	for k in _direct_children(dir, tts_j):
		if int(dir[k]["tag"]) == TAG_ANIM_TRANSFORM_TRACK_KEYS:
			key_nodes.append(k)
	if key_nodes.is_empty():
		push_error("Models.clip: entry %d carries no per-bone AnimationTransformTrackKeys records" % entry)
		return {}

	# VARIANT SELECT, whole-entry and never per record (row 776). Some clips
	# store uniformly sampled 30fps transforms instead of variable-length
	# per-channel tracks. Deciding per record would let a coincidence in one
	# record pick a layout for it that the rest of the entry contradicts, so
	# the sampled path is taken only when the documented one fails on at
	# least one record AND the sampled one fits EVERY record.
	var sampled := _clip_is_sampled(buf, dir, sec, key_nodes)

	var records: Array[Dictionary] = []
	var max_length := 0.0
	for ridx in key_nodes.size():
		if sampled:
			var srec := _clip_sampled_record(entry, buf, dir, sec, key_nodes[ridx], ridx)
			if srec.is_empty():
				return {}
			records.append(srec)
			var st: PackedFloat32Array = srec["times_pos"]
			if st.size() > 0 and st[st.size() - 1] > max_length:
				max_length = st[st.size() - 1]
			continue
		var j: int = key_nodes[ridx]
		var off := sec + int(dir[j]["rel"]) + desync
		var span := _span_sec(dir, j, buf.size(), sec)
		if off < 0 or span <= ANIM_RECORD_HEADER or off + span > buf.size():
			push_error("Models.clip: entry %d record %d has an unusable span %d" % [entry, ridx, span])
			return {}
		if off + ANIM_OFF_NUM_UNKNOWNS + 4 > buf.size():
			push_error("Models.clip: entry %d record %d too short to read its count fields" % [entry, ridx])
			return {}
		var rid := buf.decode_u32(off)
		var nt := buf.decode_u32(off + ANIM_OFF_NUM_TRANSLATES)
		var nq := buf.decode_u32(off + ANIM_OFF_NUM_QUATERNIONS)
		var nu := buf.decode_u32(off + ANIM_OFF_NUM_UNKNOWNS)
		if nt > MAX_KEYFRAMES or nq > MAX_KEYFRAMES or nu > MAX_KEYFRAMES:
			push_error("Models.clip: entry %d record %d declares a count above MAX_KEYFRAMES (nt=%d nq=%d nu=%d)" % [
				entry, ridx, nt, nq, nu])
			return {}
		var implied := ANIM_RECORD_HEADER + 16 * nt + 20 * nq + ANIM_UNKNOWN_STRIDE * nu
		if implied != span:
			push_error("Models.clip: entry %d record %d implied size %d does not equal its span %d exactly (nt=%d nq=%d nu=%d)" % [
				entry, ridx, implied, span, nt, nq, nu])
			return {}

		var p := off + ANIM_RECORD_HEADER
		var times_pos := PackedFloat32Array()
		times_pos.resize(nt)
		for i in nt:
			times_pos[i] = buf.decode_float(p + i * 4)
		p += nt * 4
		var times_rot := PackedFloat32Array()
		times_rot.resize(nq)
		for i in nq:
			times_rot[i] = buf.decode_float(p + i * 4)
		p += nq * 4
		var times_other := PackedFloat32Array()
		times_other.resize(nu)
		for i in nu:
			times_other[i] = buf.decode_float(p + i * 4)
		p += nu * 4

		var positions := PackedVector3Array()
		positions.resize(nt)
		for i in nt:
			positions[i] = Vector3(buf.decode_float(p + i * 12), buf.decode_float(p + i * 12 + 4), buf.decode_float(p + i * 12 + 8))
		p += nt * 12

		var rotations: Array[Quaternion] = []
		rotations.resize(nq)
		for i in nq:
			var q := Quaternion(buf.decode_float(p + i * 16), buf.decode_float(p + i * 16 + 4),
				buf.decode_float(p + i * 16 + 8), buf.decode_float(p + i * 16 + 12))
			var qlen := sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w)
			if is_nan(qlen) or qlen < ANIM_QUAT_MIN:
				push_error("Models.clip: entry %d record %d rotation %d cannot be normalized (|q|=%f)" % [
					entry, ridx, i, qlen])
				return {}
			# Stored normalized: the drift is real data, but Godot's own
			# rotation-track interpolation demands an exact unit quaternion
			# and logs per sampled frame otherwise.
			rotations[i] = q / qlen
		p += nq * 16

		# 36 bytes per key, UNINTERPRETED. The stride is measured (see
		# ANIM_UNKNOWN_STRIDE); what the bytes MEAN is not. 9 floats is the
		# shape of Granny's scale-shear 3x3, and that was the working guess,
		# but read as a matrix the values are degenerate -- WOLF_ATTACK_BH_A
		# yields determinants near zero and negative, which no scale-shear
		# has. So they are handed back as raw floats and named for what is
		# known about them. Nothing consumes them yet.
		var others: Array[PackedFloat32Array] = []
		others.resize(nu)
		for i in nu:
			var o := p + i * 36
			var f := PackedFloat32Array()
			f.resize(9)
			for k in 9:
				f[k] = buf.decode_float(o + k * 4)
			others[i] = f
		p += nu * 36
		# p == off + span exactly, by the implied-size check above.

		records.append({
			"id": rid, "times_pos": times_pos, "times_rot": times_rot,
			"times_other": times_other, "positions": positions,
			"rotations": rotations, "others": others,
		})
		if nt > 0 and times_pos[nt - 1] > max_length:
			max_length = times_pos[nt - 1]

	return {
		"bones": bone_count, "records": records, "length": max_length,
		"source": "h=%d,nt=%d,nq=%d,nu=%d,ustride=%d,notrailer" % [
			ANIM_RECORD_HEADER, ANIM_OFF_NUM_TRANSLATES, ANIM_OFF_NUM_QUATERNIONS,
			ANIM_OFF_NUM_UNKNOWNS, ANIM_UNKNOWN_STRIDE],
	}


## Bytes of fixed header on a SAMPLED record, and the size of one sampled
## key: 17 f32 = time(1), translation(3), rotation quaternion(4, x,y,z,w),
## scale-shear 3x3(9). Granny's transform triple, one sample per frame.
## Measured on HORS_DYING_A (row 776): times run 0, 1/30, 2/30, ... and the
## model reconciles (span - 12) % 68 == 0 on all 2989 records of all 26
## entries that carry this variant, with every time track ascending from 0.
const ANIM_SAMPLED_HEADER := 12
const ANIM_SAMPLED_KEY := 68

## True iff this entry is the sampled variant: the documented
## variable-length model fails somewhere AND every record fits 12 + 68N.
## Both halves are required -- "fits 12+68N" alone is not decisive, since a
## variable-length record can land on that size by coincidence.
func _clip_is_sampled(buf: PackedByteArray, dir: Array[Dictionary], sec: int,
		key_nodes: Array[int]) -> bool:
	var documented_ok := true
	for j in key_nodes:
		var off := sec + int(dir[j]["rel"])
		var span := _span_sec(dir, j, buf.size(), sec)
		if span < ANIM_SAMPLED_HEADER or (span - ANIM_SAMPLED_HEADER) % ANIM_SAMPLED_KEY != 0:
			return false
		if off < 0 or off + ANIM_OFF_NUM_UNKNOWNS + 4 > buf.size():
			return false
		var nt := buf.decode_u32(off + ANIM_OFF_NUM_TRANSLATES)
		var nq := buf.decode_u32(off + ANIM_OFF_NUM_QUATERNIONS)
		var nu := buf.decode_u32(off + ANIM_OFF_NUM_UNKNOWNS)
		if nt > MAX_KEYFRAMES or nq > MAX_KEYFRAMES or nu > MAX_KEYFRAMES \
				or ANIM_RECORD_HEADER + 16 * nt + 20 * nq + ANIM_UNKNOWN_STRIDE * nu != span:
			documented_ok = false
	return not documented_ok

## One sampled record, in the SAME shape the variable-length path returns so
## no caller needs to know which variant it came from. Every channel shares
## one time array here, because every channel is sampled on the same frames.
func _clip_sampled_record(entry: int, buf: PackedByteArray, dir: Array[Dictionary],
		sec: int, j: int, ridx: int) -> Dictionary:
	var off := sec + int(dir[j]["rel"])
	var span := _span_sec(dir, j, buf.size(), sec)
	if off < 0 or off + span > buf.size():
		push_error("Models.clip: entry %d sampled record %d runs past the entry" % [entry, ridx])
		return {}
	var n := (span - ANIM_SAMPLED_HEADER) / ANIM_SAMPLED_KEY
	if n <= 0 or n > MAX_KEYFRAMES:
		push_error("Models.clip: entry %d sampled record %d implies %d keys" % [entry, ridx, n])
		return {}
	var times := PackedFloat32Array()
	var positions := PackedVector3Array()
	var rotations: Array[Quaternion] = []
	var others: Array[PackedFloat32Array] = []
	times.resize(n)
	positions.resize(n)
	rotations.resize(n)
	others.resize(n)
	var prev := -INF
	for i in n:
		var o := off + ANIM_SAMPLED_HEADER + i * ANIM_SAMPLED_KEY
		var t := buf.decode_float(o)
		if is_nan(t) or t < prev:
			push_error("Models.clip: entry %d sampled record %d time %d is %f, not ascending" % [
				entry, ridx, i, t])
			return {}
		prev = t
		times[i] = t
		positions[i] = Vector3(buf.decode_float(o + 4), buf.decode_float(o + 8), buf.decode_float(o + 12))
		var q := Quaternion(buf.decode_float(o + 16), buf.decode_float(o + 20),
			buf.decode_float(o + 24), buf.decode_float(o + 28))
		var ql := sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w)
		if is_nan(ql) or ql < ANIM_QUAT_MIN:
			push_error("Models.clip: entry %d sampled record %d rotation %d cannot be normalized (|q|=%f)" % [
				entry, ridx, i, ql])
			return {}
		rotations[i] = q / ql
		var f := PackedFloat32Array()
		f.resize(9)
		for k in 9:
			f[k] = buf.decode_float(o + 32 + k * 4)
		others[i] = f
	return {"id": buf.decode_u32(off), "times_pos": times, "times_rot": times,
		"times_other": times, "positions": positions, "rotations": rotations,
		"others": others}

## The rule 05-02 measured: the maximum, across all records, of that
## record's last translate-track time. 0.0 for a non-clip or any malformed
## entry -- clip() already refuses those, so this just forwards its
## "length" field or the safe default.
func clip_length(entry: int) -> float:
	var c := clip(entry)
	if c.is_empty():
		return 0.0
	return float(c["length"])

## Raw stored bytes for entry's per-bone AnimationTransformTrackKeys
## records, concatenated in directory order -- the RAW STORED bytes
## exactly as they sit in the file, not the decoded floats clip() returns.
## The `motion` fact line (verify.gd/verify_ref.py, Plan 05-05 Task 2)
## hashes these bytes for the same reason bones()'s `bones` line hashes
## bone_bytes(): both harness sides then compute the hash from offsets,
## and neither needs the other's float decoder to agree for it to mean
## anything. Redoes clip()'s own directory walk rather than returning
## bytes from clip() itself -- the same relationship bone_bytes() already
## has to bones().
func clip_bytes(entry: int) -> PackedByteArray:
	var empty := PackedByteArray()
	var length := true_length(entry)
	if length <= 0 or not magic_ok(entry):
		return empty
	var buf := _pak.read_at(_pak.entry_offset(entry), length)
	if buf.size() < length:
		return empty
	var sec := section_offset(entry)
	var dir := _directory_sec(buf, sec)
	if dir.is_empty():
		return empty
	var sec_j := -1
	for j in dir.size():
		if int(dir[j]["tag"]) == TAG_ANIMATION_SECTION:
			sec_j = j
			break
	if sec_j == -1:
		return empty
	var anim_j := _child_with_tag(dir, sec_j, TAG_ANIMATION)
	if anim_j == -1:
		return empty
	var tts_j := _child_with_tag(dir, anim_j, TAG_ANIM_TRANSFORM_TRACK_SECTION)
	if tts_j == -1:
		return empty
	var out := PackedByteArray()
	for k in _direct_children(dir, tts_j):
		if int(dir[k]["tag"]) != TAG_ANIM_TRANSFORM_TRACK_KEYS:
			continue
		var off := sec + int(dir[k]["rel"])
		var span := _span_sec(dir, k, buf.size(), sec)
		if off < 0 or span <= 0 or off + span > buf.size():
			return empty
		out.append_array(buf.slice(off, off + span))
	return out

# ---------------------------------------------------------------------
# Clip-side bone chain (05-12 Task 1). Section-aware TWINS of
# _node_u32()/strings()/object_names()/bone_names() above -- NOT
# extensions of them. Those four are hardwired to SECTION_OFF_MESH
# (confirmed by direct reading: every one of them opens with
# `_directory(buf)`, never `_directory_sec(buf, sec)`), so a kind=65
# clip entry's own section (section_offset(entry), not SECTION_OFF_MESH)
# needs its own read path. The two-hop DataExtension chain itself
# (FormBoneChannels[bone_i]-1 -> TransformChannel -> first child
# DataExtensionReference -> DataExtensionIndex-1 -> DataExtension.
# __ObjectName) is UNCHANGED -- only the section anchor differs.
#
# clip_bones()'s bone block is NOT the contiguous BONE_STRIDE-stride run
# bone_bytes() reads: measured, each TAG_BONE is its own directory node
# with its own rel (unlike kind=64's BoneSection+contiguous-Bone-block).
# So clip_bones() collects each TAG_BONE node's rel individually, the
# same directory-order scan clip()'s own bone_count already uses, rather
# than reading one bone_count*BONE_STRIDE slice.

## Section-aware twin of _node_u32(): single u32 payload word at node j's
## own rel, offset from sec instead of SECTION_OFF_MESH.
func _node_u32_sec(buf: PackedByteArray, dir: Array[Dictionary], j: int, sec: int) -> int:
	var off := sec + int(dir[j]["rel"])
	if off < 0 or off + 4 > buf.size():
		return -1
	return buf.decode_u32(off)

## Section-aware twin of strings(): identical StringTable decode, offset
## from sec instead of SECTION_OFF_MESH.
func _strings_sec(buf: PackedByteArray, dir: Array[Dictionary], sec: int) -> PackedStringArray:
	var empty := PackedStringArray()
	for j in dir.size():
		if dir[j]["tag"] != TAG_STRING_TABLE:
			continue
		var off := sec + int(dir[j]["rel"])
		if off < 0 or off + 8 > buf.size():
			return empty
		var n := buf.decode_u32(off)
		var span_bytes := _span_sec(dir, j, buf.size(), sec)
		if n < 0 or 8 + n > span_bytes:
			return empty
		var out := PackedStringArray()
		var pos := off + 8
		var end := off + span_bytes
		for i in n:
			var e := pos
			while e < end and buf[e] != 0:
				e += 1
			if e >= end:
				return empty
			out.append(buf.slice(pos, e).get_string_from_utf8())
			pos = e + 1
		return out
	return empty

## Section-aware twin of object_names(): identical DataExtension ->
## PropertySection -> Property -> ValueSection walk, offset from sec.
func _object_names_sec(buf: PackedByteArray, dir: Array[Dictionary], sec: int) -> PackedStringArray:
	var strs := _strings_sec(buf, dir, sec)
	var out := PackedStringArray()
	for j in dir.size():
		if dir[j]["tag"] != TAG_DATA_EXTENSION:
			continue
		var name := ""
		for sk in _direct_children(dir, j):
			if dir[sk]["tag"] != TAG_DATA_EXTENSION_PROPERTY_SECTION:
				continue
			for kn in _direct_children(dir, sk):
				if dir[kn]["tag"] != TAG_DATA_EXTENSION_PROPERTY:
					continue
				var key := _resolve_textid(strs, _node_u32_sec(buf, dir, kn, sec))
				if key != OBJECT_NAME_KEY:
					continue
				var value_section := -1
				var last: int = mini(kn + 1 + int(dir[kn]["children"]), dir.size())
				for vk in range(kn + 1, last):
					if dir[vk]["tag"] == TAG_DATA_EXTENSION_VALUE_SECTION:
						value_section = vk
						break
				if value_section == -1:
					continue
				var voff := sec + int(dir[value_section]["rel"]) + 4
				if voff + 4 > buf.size():
					continue
				name = _resolve_textid(strs, buf.decode_u32(voff))
		out.append(name)
	return out

## Per-bone rest transform for a kind=65 clip entry's OWN bone list --
## NOT the model's. Same 68-byte Bone record layout bones() decodes
## (TAG_BONE is shared, 0xCA5E0506, same fields at the same offsets),
## same rejection posture (out-of-range parent, non-unit quaternion both
## refuse the whole entry), but each TAG_BONE node is read at its OWN
## rel rather than a contiguous bone_count*BONE_STRIDE block -- see the
## section header comment above for why. Field shape mirrors bones()'s
## dict minus "name" (clip_bone_names() carries that, kept separate the
## same way bones()/bone_names() are two calls rather than one).
func clip_bones(entry: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var length := true_length(entry)
	if length <= 0 or not magic_ok(entry):
		return out
	var buf := _pak.read_at(_pak.entry_offset(entry), length)
	if buf.size() < length:
		return out
	var sec := section_offset(entry)
	var dir := _directory_sec(buf, sec)
	if dir.is_empty():
		return out
	var bone_nodes: Array[int] = []
	for j in dir.size():
		if int(dir[j]["tag"]) == TAG_BONE:
			bone_nodes.append(j)
	var n := bone_nodes.size()
	if n <= 0 or n > MAX_BONES:
		return out
	for i in n:
		var j: int = bone_nodes[i]
		var off := sec + int(dir[j]["rel"])
		if off < 0 or off + BONE_STRIDE > buf.size():
			push_error("Models.clip_bones: entry %d bone node %d runs past the entry" % [entry, j])
			return []
		var parent := buf.decode_s32(off)
		if parent < 0 or parent >= n:
			push_error("Models.clip_bones: entry %d bone %d has out-of-range parent %d (of %d)" % [entry, i, parent, n])
			return []
		var pos := Vector3(buf.decode_float(off + 4), buf.decode_float(off + 8), buf.decode_float(off + 12))
		var q := Quaternion(buf.decode_float(off + 16), buf.decode_float(off + 20), buf.decode_float(off + 24), buf.decode_float(off + 28))
		var qlen := sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w)
		if is_nan(qlen) or absf(qlen - 1.0) > BONE_QUAT_EPS:
			push_error("Models.clip_bones: entry %d bone %d rotation is not a unit quaternion (|q|=%f)" % [entry, i, qlen])
			return []
		var ss := PackedFloat32Array()
		ss.resize(9)
		for k in 9:
			ss[k] = buf.decode_float(off + 32 + k * 4)
		var b := Basis(Vector3(ss[0], ss[3], ss[6]), Vector3(ss[1], ss[4], ss[7]), Vector3(ss[2], ss[5], ss[8]))
		out.append({
			"parent": parent,
			"parent_effective": -1 if parent == i else parent,
			"position": pos,
			"rotation": q,
			"scale_shear": ss,
			"rest": Transform3D(Basis(q) * b, pos),
		})
	return out

## Resolved bone name per bone in clip_bones() order -- the section-aware
## twin of bone_names(), same two-hop chain, same honest-empty-on-
## unresolved posture (D-19: nothing is substituted for a bone the chain
## does not resolve). bone_count here is clip_bones()'s own TAG_BONE
## node count, not a bone_bytes()-style contiguous-block division -- see
## the section header comment above.
func clip_bone_names(entry: int) -> PackedStringArray:
	var empty := PackedStringArray()
	var length := true_length(entry)
	if length <= 0 or not magic_ok(entry):
		return empty
	var buf := _pak.read_at(_pak.entry_offset(entry), length)
	if buf.size() < length:
		return empty
	var sec := section_offset(entry)
	var dir := _directory_sec(buf, sec)
	if dir.is_empty():
		return empty
	var bone_count := 0
	for node in dir:
		if int(node["tag"]) == TAG_BONE:
			bone_count += 1
	if bone_count <= 0:
		return empty
	var names := _object_names_sec(buf, dir, sec)

	var tc_refs := PackedInt32Array()
	for j in dir.size():
		if dir[j]["tag"] != TAG_TRANSFORM_CHANNEL:
			continue
		var kids := _direct_children(dir, j)
		if not kids.is_empty() and dir[kids[0]]["tag"] == TAG_DATA_EXTENSION_REFERENCE:
			tc_refs.append(_node_u32_sec(buf, dir, kids[0], sec))
		else:
			tc_refs.append(-1)

	var fbc := PackedInt32Array()
	for j in dir.size():
		if dir[j]["tag"] != TAG_FORM_BONE_CHANNELS:
			continue
		var off := sec + int(dir[j]["rel"])
		var span_bytes := _span_sec(dir, j, buf.size(), sec)
		var count := span_bytes / 4
		if off < 0 or count < 0 or off + count * 4 > buf.size():
			push_error("Models.clip_bone_names: entry %d FormBoneChannels runs past the entry" % entry)
			return empty
		for i in count:
			fbc.append(buf.decode_u32(off + i * 4))
		break

	var out := PackedStringArray()
	out.resize(bone_count)
	for i in bone_count:
		out[i] = ""
		if i >= fbc.size():
			continue
		var channel := fbc[i] - 1
		if channel < 0 or channel >= tc_refs.size():
			continue
		var ref_raw := tc_refs[channel]
		if ref_raw < 0:
			continue
		var ext := ref_raw - 1
		if ext < 0 or ext >= names.size():
			continue
		out[i] = names[ext]
	return out

## Binds clip()'s records[] to clip_bones() by DIRECTORY POSITION,
## WITHIN THIS SINGLE FILE ONLY -- record i (the i-th
## AnimationTransformTrackKeys child of AnimationTransformTrackSection,
## the same order clip()'s own `records` array is built in) is bone i
## (the i-th TAG_BONE node, the same order clip_bones() is built in).
## This is NEVER a cross-file join -- clip_track_bone() never touches a
## model entry, and binding a clip track to a MODEL bone happens only in
## ModelView.build_animation(), by NAME, never by this index. Refuses
## (empty array, push_error naming both counts) when record count does
## not equal bone count -- measured exception: FX_E_IDLE_BH.GRN (2583)
## and FX_G_IDLE_BH.GRN (2585) each declare 12 bones but 24 records
## (duplicated ids), so a positional bind there would be a guess, not a
## resolution, and is refused rather than truncated or paired arbitrarily.
func clip_track_bone(entry: int) -> PackedInt32Array:
	var c := clip(entry)
	var bl := clip_bones(entry)
	if c.is_empty() or bl.is_empty():
		return PackedInt32Array()
	var records: Array = c["records"]
	if records.size() != bl.size():
		push_error("Models.clip_track_bone: entry %d has %d records but %d bones -- refusing to bind by directory position (count mismatch)" % [entry, records.size(), bl.size()])
		return PackedInt32Array()
	var out := PackedInt32Array()
	out.resize(records.size())
	for i in records.size():
		out[i] = i
	return out

## The 13 German weapon-category tokens ATTACK_* clip names carry,
## longest-token-first (2H_AXT before 2H, KLINGENWAFFEN before nothing
## shorter overlaps it) so a compound token is never shadowed by a
## shorter one nested inside it. D-07: attack animation names encode a
## weapon category (ATTACK_1H_A, ATTACK_2H_A, ATTACK_2H_AXT_A/B,
## ATTACK_2WAFFEN_A/B, ATTACK_ARMBRUST_A, ATTACK_BH_A, ...). Decode and
## record the category here; nothing in this file or godot-port/view/
## selects an animation from gear a character is carrying -- no
## equipment or weapon system exists yet, and a selection rule built
## without one would be untestable invention. That wiring is the
## combat phase's job.
const CLIP_CATEGORIES := [
	"KLINGENWAFFEN", "ARMBRUST", "PEITSCHE", "2WAFFEN", "2H_AXT",
	"BOGEN", "DOLCH", "STAB", "WURF", "AXT", "BH", "1H", "2H",
]

## First CLIP_CATEGORIES token found as an underscore-delimited word in
## name (case-sensitive -- the pak's own names are already upper-case),
## checked longest-first so "2H_AXT" wins over the "2H" nested inside
## it. Empty string if none match (e.g. GLAD_PICKUP.GRN). ponytail:
## this is a substring match over an artist naming convention, not a
## shipped binding table (D-02) -- motions.pak was opened and refuted
## as that table (see the grn-clip-categories findings row); ceiling is
## "wrong category if a future name introduces a token this list
## doesn't cover".
func clip_category(name: String) -> String:
	var wrapped := "_" + name.trim_suffix(".GRN") + "_"
	for token in CLIP_CATEGORIES:
		if wrapped.find("_" + token + "_") != -1:
			return token
	return ""

## Every KIND_MOTION entry whose name begins with prefix, as
## {entry: int, name: String, action: String, category: String}.
## `action` is the portion of the name between prefix and the matched
## category token (e.g. "ATTACK" for "GLAD_ATTACK_2H_AXT_A.GRN" with
## prefix "GLAD"); category is clip_category(name), empty string if no
## token matched. prefix is a parameter, never a literal character name
## compared in a conditional here (D-03).
func clip_catalogue(prefix: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry in _pak.count():
		if kind_of(entry) != KIND_MOTION:
			continue
		var name := entry_name(entry)
		if not name.begins_with(prefix):
			continue
		var category := clip_category(name)
		var body := name.trim_suffix(".GRN").substr(prefix.length()).trim_prefix("_")
		var action := body
		var token_at := body.find(category) if category != "" else -1
		if token_at != -1:
			action = body.substr(0, token_at).trim_suffix("_")
		out.append({"entry": entry, "name": name, "action": action, "category": category})
	return out
