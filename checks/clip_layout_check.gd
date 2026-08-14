extends "res://checks/check.gd"
## clip_layout_check.gd -- the ONE runnable check for the clip record layout
## (rows 764/767). Was clip_trailer_check.gd, and the rename is the finding:
## there is no trailer.
##
##   godot --headless --path godot-port --script clip_layout_check.gd
##
## THE LAYOUT. A record is 52 bytes of header, then 16 bytes per translate key,
## 20 per rotation key, and 40 per "unknown" key -- 4 of time plus a 36-byte 3x3,
## which is the scale-shear of Granny's transform triple. Nothing follows.
##
## HOW IT WAS WRONG TWICE, because that is what this protects against. 05-02
## sampled three clips whose records all had nu=2 and read the residual 24*2=48
## as a fixed trailer. Row 764 found entries with nu=3, read 24*3=72, and
## concluded the trailer was bimodal -- still constant, just two values. Both
## fit every entry whose nu never varies, which is most of them. Only a clip
## with a VARYING nu can tell the difference, and row 764 had already refused
## those as "internally inconsistent" -- they were the ones telling the truth.
##
## So the load-bearing case here is WOLF_ATTACK_BH_A: 46 records, nu from 2 to
## 33, which no constant-trailer model can reconcile and this one reconciles
## exactly. If someone reintroduces a constant, that entry fails first.
## Row 772: the unit-length TOLERANCE that gated each entry was removed (it was
## refusing 643 clips for heavy-tailed quantization drift with no gap to cut
## at); layout validation now rests on the exact size reconciliation above,
## which is stronger. Only a non-normalizable quaternion refuses an entry.
## Row 776/777: the sampled 30fps variant (12 + 68N) is decoded too.
const WANT_DECODABLE := 3413
## The sampled variant, and the reason it is pinned by NAME: it is the only
## shape whose records carry no count fields at all, so if the disambiguation
## in _clip_is_sampled ever regresses to per-record, this entry is where a
## variable-length reading first produces nonsense.
const SAMPLED := "HORS_DYING_A.GRN"
const WANT_SAMPLED_RECORDS := 48
const WANT_SAMPLED_LENGTH := 1.1
const VARYING := "WOLF_ATTACK_BH_A.GRN"
const WANT_VARYING_RECORDS := 46
## Distinct nu values across that clip's records. 1 would mean the case has
## stopped being the discriminator it was chosen for.
const WANT_MIN_DISTINCT_NU := 5


func _init() -> void:
	super()
	var install := Sacred.find_install()
	assert(install != "", "no retail install found; pass --install=/path/to/install")
	var models := Sacred.Models.new(Sacred.Pak.new(install.path_join("pak/models.pak")))

	var ok := 0
	var refused := 0
	for i in models.count():
		if models.kind_of(i) != Sacred.Models.KIND_MOTION:
			continue
		if models.clip(i).is_empty():
			refused += 1
		else:
			ok += 1
	assert(ok == WANT_DECODABLE, "decodable clips moved: want %d, got %d" % [WANT_DECODABLE, ok])

	# The discriminating entry: varying nu, decoded, zero slack.
	var vi := models.clip_index_of(VARYING)
	assert(vi >= 0, "no motion entry named %s" % VARYING)
	var vc := models.clip(vi)
	assert(not vc.is_empty(), "%s does not decode -- a constant-trailer model is back" % VARYING)
	var recs: Array = vc["records"]
	assert(recs.size() == WANT_VARYING_RECORDS,
		"%s record count moved: want %d, got %d" % [VARYING, WANT_VARYING_RECORDS, recs.size()])
	var nus := {}
	for r: Dictionary in recs:
		nus[(r["others"] as Array).size()] = true
	assert(nus.size() >= WANT_MIN_DISTINCT_NU,
		"%s now shows only %d distinct nu values -- it no longer discriminates a constant trailer"
			% [VARYING, nus.size()])

	# The 36-byte payload is UNINTERPRETED and this check says so rather than
	# asserting a meaning. 9 floats is the shape of Granny's scale-shear 3x3 and
	# that was the working guess, but read as a matrix WOLF_ATTACK_BH_A gives
	# determinants near zero and negative, which no scale-shear has. What IS
	# checked is the only thing measured: every key carries its 9 floats.
	var checked := 0
	for r: Dictionary in recs:
		for f: PackedFloat32Array in r["others"]:
			assert(f.size() == 9, "an unknown-track key decoded %d floats, want 9" % f.size())
			checked += 1
	assert(checked > 0, "%s decoded no unknown-track keys at all" % VARYING)

	# The sampled variant decodes, at the right shape. 48 records (one per bone)
	# and 1.1s == 33 frames at 1/30, which is what a uniformly sampled clip must
	# produce; a misread stride would not land on an exact frame multiple.
	var si := models.clip_index_of(SAMPLED)
	assert(si >= 0, "no motion entry named %s" % SAMPLED)
	var sc := models.clip(si)
	assert(not sc.is_empty(), "%s does not decode -- the sampled variant is refused again" % SAMPLED)
	assert((sc["records"] as Array).size() == WANT_SAMPLED_RECORDS,
		"%s decoded %d records, want %d" % [SAMPLED, (sc["records"] as Array).size(), WANT_SAMPLED_RECORDS])
	assert(absf(float(sc["length"]) - WANT_SAMPLED_LENGTH) < 0.001,
		"%s length is %f, want %f" % [SAMPLED, sc["length"], WANT_SAMPLED_LENGTH])

	# The wolf is the reason this was reopened: it could not animate at all.
	var idle := models.clip_index_of("WOLF_IDLE_BH.GRN")
	assert(idle >= 0 and not models.clip(idle).is_empty(),
		"WOLF_IDLE_BH.GRN does not decode -- the wolf is a static mesh again")

	print("clip_layout_check: %d motion entries decode (%d refused); %s reconciles %d records across %d distinct nu with %d uninterpreted 9-float keys" % [
		ok, refused, VARYING, recs.size(), nus.size(), checked])
	finish(0)
