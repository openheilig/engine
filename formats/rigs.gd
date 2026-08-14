extends RefCounted
## Which animation clip belongs to which mesh, decided by BONE GEOMETRY rather
## than by name -- because the names do not line up. A clip is called
## `UPI1_WALK_BH.GRN` while its mesh is `UPIRATE_01.GRN`; `DDRU_IDLE_BH.GRN`
## belongs to `DRYADDRUID.GRN`; `HORS_DYING_A.GRN` belongs with `BRIDLE_01.GRN`.
## A four-letter prefix rule resolves 41 of the 124 meshes the spawn tables
## name; this class resolves them by measurement instead.
##
## THE MEASUREMENT, and the finding it rests on. A clip entry and a mesh entry
## that describe the same character carry the same bones, and each bone's LOCAL
## rest transform agrees to within 0.01 on ~80% of shared bones -- against ~4%
## for a clip belonging to a different character. Matching is by exact bone
## NAME, and the comparison is strictly LOCAL: composing either side's own
## parent chain into world space destroys the signal, because the two files do
## not share the chain above `Bip01` (a mesh carries a 90-degree-Z alignment
## bone there that a clip has no node for at all). That is why three earlier
## world-space attempts at this question came back REFUTED -- they measured a
## real quantity that happens not to be this one.
##
## Do NOT "improve" this by composing world transforms. rig_check.gd exists to
## fail when someone does.
##
## COST. Deciding anything requires decoding every clip's bone list once, about
## 7 seconds for the 3397 shipped clips, so the result is cached under `user://`
## keyed by the models.pak byte size. Nothing is bundled and nothing is written
## next to the retail data.

const Models := preload("res://formats/models.gd")

const WITHIN := 0.01
## Below this many shared bone names the fraction is noise -- an unfiltered
## search finds spurious 1.000 agreements on two-bone overlaps.
const MIN_MATCHED := 20
## Refuse a match this weak rather than animate a creature with another
## creature's skeleton. Measured spread: real pairs 0.79..0.97, wrong-
## character pairs 0.04.
const MIN_SCORE := 0.5
const CACHE := "user://rigmap.tsv"

var _clip: Dictionary[int, int] = {}
var _score: Dictionary[int, float] = {}
var _pak_size := 0
var resolved := 0
var computed := 0

## Resolves every entry in `wanted` (mesh entry indices), reading whatever
## the cache already knows and computing the rest in ONE pass over the clip
## corpus. `wanted` may contain duplicates and non-mesh entries; both are
## ignored.
func _init(models: Models, wanted: PackedInt32Array) -> void:
	_pak_size = models.pak_size()
	_load_cache()
	var todo := PackedInt32Array()
	for e in wanted:
		if e >= 0 and not _clip.has(e) and not todo.has(e):
			todo.append(e)
	if not todo.is_empty():
		_compute(models, todo)
		_save_cache()
	for e in wanted:
		if _clip.get(e, -1) >= 0:
			resolved += 1

## The best-agreeing clip entry for `model_entry`, or -1 when none cleared
## MIN_SCORE. A caller that gets -1 must draw the mesh unanimated rather
## than fall back to some other character's clip.
func clip_for(model_entry: int) -> int:
	return _clip.get(model_entry, -1)

## The agreement fraction behind clip_for(), 0.0 when unresolved -- exposed
## so a caller can report how well its own picks did instead of trusting
## them silently.
func score_for(model_entry: int) -> float:
	return _score.get(model_entry, 0.0)

func _compute(models: Models, todo: PackedInt32Array) -> void:
	# Mesh side first: name -> local rest ORIGIN, the only field compared.
	var mesh_local: Array[Dictionary] = []
	for e in todo:
		var d: Dictionary = {}
		for b in models.bones(e):
			var nm: String = (b["name"] as PackedByteArray).get_string_from_utf8()
			if nm != "" and not d.has(nm):
				d[nm] = (b["rest"] as Transform3D).origin
		mesh_local.append(d)
	var best := PackedInt32Array()
	var best_score := PackedFloat32Array()
	best.resize(todo.size())
	best_score.resize(todo.size())
	for i in todo.size():
		best[i] = -1
		best_score[i] = -1.0
	# One pass over the clip corpus, scoring every wanted mesh against each
	# clip as it is decoded -- decoding is the expensive half, so it happens
	# exactly once no matter how many meshes are wanted.
	for ci in models.count():
		if models.kind_of(ci) != Models.KIND_MOTION or not models.is_animation(ci):
			continue
		var cn := models.clip_bone_names(ci)
		if cn.size() < MIN_MATCHED:
			continue
		var cb := models.clip_bones(ci)
		if cb.size() != cn.size():
			continue
		for i in todo.size():
			var d: Dictionary = mesh_local[i]
			if d.size() < MIN_MATCHED:
				continue
			var matched := 0
			var within := 0
			for j in cn.size():
				var o: Variant = d.get(cn[j])
				if o == null:
					continue
				matched += 1
				if (cb[j]["rest"] as Transform3D).origin.distance_to(o) <= WITHIN:
					within += 1
			if matched < MIN_MATCHED:
				continue
			var f := float(within) / float(matched)
			if f > best_score[i]:
				best_score[i] = f
				best[i] = ci
	for i in todo.size():
		computed += 1
		if best_score[i] >= MIN_SCORE:
			_clip[todo[i]] = best[i]
			_score[todo[i]] = best_score[i]
		else:
			# Cached as a NEGATIVE result, so a mesh with no usable clip
			# does not pay the 7-second pass again on every launch.
			_clip[todo[i]] = -1
			_score[todo[i]] = maxf(0.0, best_score[i])

func _load_cache() -> void:
	var f := FileAccess.open(CACHE, FileAccess.READ)
	if f == null:
		return
	# The header pins the cache to one models.pak. A different install, or
	# a patched one, invalidates the whole file rather than mixing entries
	# from two corpora whose entry numbers do not mean the same thing.
	if f.get_line() != "models.pak\t%d" % _pak_size:
		return
	while not f.eof_reached():
		var parts := f.get_line().split("\t")
		if parts.size() != 3:
			continue
		_clip[int(parts[0])] = int(parts[1])
		_score[int(parts[0])] = float(parts[2])

func _save_cache() -> void:
	var f := FileAccess.open(CACHE, FileAccess.WRITE)
	if f == null:
		push_warning("Rigs: cannot write %s -- recomputing on every launch" % CACHE)
		return
	f.store_line("models.pak\t%d" % _pak_size)
	for e: int in _clip:
		f.store_line("%d\t%d\t%f" % [e, _clip[e], _score.get(e, 0.0)])
