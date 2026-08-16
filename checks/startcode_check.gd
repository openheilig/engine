extends "res://checks/check.gd"
## startcode_check.gd -- the ONE runnable check for Sacred.Startcode.
##
##   godot --headless --path godot-port --script res://checks/startcode_check.gd
##
## THE FINDINGS THIS CHECK EXISTS TO PROTECT (autoresearch rows 831-835):
##
##   1. An opcode-1 record's FIRST tag-0x02 value is an items.pak record index
##      naming a Granny model. Every op1 record in every class resolves.
##   2. The position is tag 0x04, a VARIANT: three signed i32 (cell_x, cell_y,
##      layer) or the NAME of an opcode-23 position. Placement is CLOSED --
##      every created NPC and object resolves to a world cell.
##   3. Body / main hand / off hand are tag-0x02 occurrences 0, 1 and 2, and
##      the body and main-hand name sets are DISJOINT.
##
## THE CONTROL ARM IS THE POINT OF ASSERTION 4, and it is why this check is
## worth more than a parse-rate. The first version of finding 1 was "100% of
## op1 operands resolve to a .grn, against an 8.7% random-id baseline" -- and
## that was NOT evidence: operand 0 of an unrelated opcode scores 63.2% on the
## same instrument, because .grn records are not spread over the id space
## (row 833). What actually proves the slot is an INTERNAL negative control:
## the same join, over the same records, on a DIFFERENT tag. If someone
## "improves" the reader by taking the first numeric argument instead of the
## first tag-0x02 one, assertion 1 still passes and assertion 4 fails.
##
## Counts below are per-class measurements, not round numbers, so a reader that
## silently drops or duplicates records fails rather than looks plausible.

const CLASSES := [
	"type_npc_daemonin", "type_npc_darkelve", "type_npc_elve",
	"type_npc_gladiator", "type_npc_magician", "type_npc_seraphim",
	"type_npc_vampirelady", "type_npc_zwerg",
]

## class -> [npcs, objects, places, named positions used]
const EXPECT := {
	"type_npc_daemonin": [319, 2001, 1427, 226],
	"type_npc_darkelve": [319, 2002, 1425, 226],
	"type_npc_elve": [319, 2002, 1425, 226],
	"type_npc_gladiator": [322, 2003, 1462, 229],
	"type_npc_magician": [317, 2003, 1427, 224],
	"type_npc_seraphim": [319, 2003, 1425, 226],
	"type_npc_vampirelady": [331, 2004, 1438, 228],
	"type_npc_zwerg": [319, 2003, 1425, 226],
}

## class -> [cell_x, cell_y, layer] from the tree's single opcode-45
## StartPosition record, the per-class new-game spawn (row 939). Nine distinct
## cells for nine classes is the finding: if a future reader collapsed them --
## by keeping the last record instead of the first, or by mistaking a nearby
## opcode for 45 -- the values would repeat and this table would notice.
## `layer` is absent in most trees and reads 0 there, which is the DEFAULT and
## not a measurement; only seraphim (1) and vampirelady (2) state one.
const START := {
	"type_npc_daemonin": [352, 1722, 0],
	"type_npc_darkelve": [3442, 2698, 0],
	"type_npc_elve": [3440, 2703, 0],
	"type_npc_gladiator": [3790, 349, 0],
	"type_npc_magician": [3292, 2508, 0],
	"type_npc_seraphim": [3236, 2511, 1],
	"type_npc_vampirelady": [3500, 2477, 2],
	"type_npc_zwerg": [3470, 2779, 0],
}

## The world's real cell extent. Sector grid is 100x128 and row 804 places
## script content out to cell 10112,7296, so this is a sanity bound on the
## coordinate DECODE (a wrong stride or an unsigned read blows straight past
## it), NOT a claim about where the world ends.
const CELL_MAX := 12800


func _init() -> void:
	super()
	var root := Sacred.find_install()
	if root == "":
		printerr("no retail install found; pass --install=PATH once")
		finish(1)
		return

	var items := Sacred.Items.new(Sacred.Pak.new(root.path_join("pak/items.pak")))
	var ok := true
	var total_npcs := 0
	var bodies := {}
	var mains := {}

	for cls in CLASSES:
		var sc = Sacred.Startcode.new(root.path_join("bin").path_join(cls))
		var want: Array = EXPECT[cls]
		var named := 0
		for n in sc.npcs:
			if n["place"] != "":
				named += 1
		for o in sc.objects:
			if o["place"] != "":
				named += 1
		var got := [sc.npcs.size(), sc.objects.size(), sc.places.size(), named]
		if got != want:
			printerr("%s: counts %s, expected %s" % [cls, got, want])
			ok = false

		# 5. Exactly one StartPosition per tree, at the cell retail ships.
		var ws: Array = START[cls]
		var gs := [sc.start_cell.x, sc.start_cell.y, sc.start_layer]
		if gs != ws:
			printerr("%s: StartPosition %s, expected %s" % [cls, gs, ws])
			ok = false

		# 2. Placement is closed: no created thing lacks a world cell.
		if sc.unresolved() != 0:
			printerr("%s: %d named positions do not resolve" % [cls, sc.unresolved()])
			ok = false

		for n in sc.npcs:
			total_npcs += 1
			# 1. Every body id names a Granny model.
			var body: String = items.name_of(n["body"])
			if not body.to_lower().ends_with(".grn"):
				printerr("%s: body id %d -> %s, not a model" % [cls, n["body"], body])
				ok = false
				break
			bodies[body] = true
			if n["main"] != 0:
				mains[items.name_of(n["main"])] = true
			# Coordinates decoded, in range, and never the silent (0,0) that a
			# missing position would look like.
			var c: Vector2i = n["cell"]
			if c.x < 0 or c.y < 0 or c.x > CELL_MAX or c.y > CELL_MAX:
				printerr("%s: cell %s out of range" % [cls, c])
				ok = false
				break

	# 3. Body and main-hand id spaces name DISJOINT sets. A positional or
	#    chance join cannot produce this, which is why it is the assertion
	#    that would survive if every count above were somehow wrong.
	var shared := []
	for b in bodies:
		if mains.has(b):
			shared.append(b)
	if not shared.is_empty():
		printerr("body and main-hand names overlap: %s" % [shared])
		ok = false

	# 6. The eight start cells are all DIFFERENT. This is the assertion that
	#    survives if the table above were ever "corrected" to match a wrong
	#    reader: a reader that finds the wrong opcode, or keeps a later record,
	#    tends to return the SAME value for every tree, and eight equal cells
	#    would still satisfy every per-class comparison if the table were
	#    updated to agree with them. Distinctness is what a collapsed reading
	#    cannot fake.
	var seen := {}
	for cls in CLASSES:
		seen[Vector2i(START[cls][0], START[cls][1])] = true
	if seen.size() != CLASSES.size():
		printerr("start cells collapsed: %d distinct over %d classes" % [seen.size(), CLASSES.size()])
		ok = false

	# 4. THE INTERNAL NEGATIVE CONTROL, and it must be an INFORMATIVE one.
	#
	#    Feed the same items.pak join a field that is definitively NOT a model
	#    id -- the record's own cell_x, a world coordinate -- and measure how
	#    often it "resolves" to a .grn anyway. The answer is about 54%, because
	#    .grn records occupy ids 0..8191 at 34.9% density and coordinates land
	#    in exactly that range. That number IS the finding: the join is
	#    permissive, so a bare hit rate proves nothing, and the evidence for
	#    the body slot is the 100%-versus-54% GAP plus the disjoint name sets
	#    above -- never a rate on its own (row 833).
	#
	#    Both bounds matter. Too HIGH and the join cannot discriminate at all.
	#    Too LOW and the control has gone vacuous -- which is what the first
	#    version of this assertion did by testing the layer field, a 0..4 enum
	#    that scores 0.9% simply because it is always near zero. A control that
	#    cannot fail is not a control.
	var sera = Sacred.Startcode.new(root.path_join("bin/type_npc_seraphim"))
	var hit := 0
	var tried := 0
	for n in sera.npcs:
		if n["place"] != "":
			continue        # named position: no literal coordinate to test
		tried += 1
		if items.name_of(n["cell"].x).to_lower().ends_with(".grn"):
			hit += 1
	var control := float(hit) / float(maxi(tried, 1))
	if tried < 50 or control < 0.30 or control > 0.80:
		printerr("negative control is not informative: %d/%d = %.3f, want 0.30..0.80 over >=50 records" % [hit, tried, control])
		ok = false

	print("startcode: %d NPCs over %d classes, %d distinct bodies, %d distinct main-hand items; body slot 1.000 vs coordinate control %.3f (%d/%d)" % [
		total_npcs, CLASSES.size(), bodies.size(), mains.size(), control, hit, tried])
	print("PASS" if ok else "FAIL")
	finish(0 if ok else 1)
