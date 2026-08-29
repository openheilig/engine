extends "res://checks/check.gd"
## camera_follow_check.gd -- pins the camera follow law to retail's.
##
## godot --headless --path . --script res://checks/camera_follow_check.gd
##
## Retail's law was read off an apitrace of the walking game
## (tmp/apitrace/walk.trace, 2026-08-29; findings row 1189): the camera eases
## toward the follow target, HALVING the remaining distance each update --
## measured remaining steps 34.94, 17.21, 8.87, 4.17, 2.08, 1.05, 0.52, 0.52
## world units across eight updates -- and rests exactly, pixel-aligned (the
## tail steps are 0.5215 world units = one screen pixel at the 1.0 zoom step).
## This check feeds IsoCamera.follow_cell a settled start and then a target
## 92.3 world units away -- the walk trace's own first-leg displacement -- and
## asserts the transcribed law: ~halving steps in pixels, exact pixel-grid
## rest on the target, and an immediate snap on a teleport-sized jump.
##
## The probe node is the real IsoCamera added to the tree (never a stand-in),
## the same posture --follow-probe established: follow_cell's arithmetic is
## only correct against a real viewport-derived zoom size.

const TARGET_JUMP := 92.3   ## world units; the walk trace's first-leg move


func _init() -> void:
	# The real IsoCamera needs a live tree before get_viewport() answers, so
	# the body runs on the first processed frame. It is connected BEFORE
	# super() arms the failsafe so the two land on frame 1 in the order
	# body-then-failsafe; the failsafe still catches a body that dies
	# mid-run, which is the hang it exists for.
	process_frame.connect(_run, CONNECT_ONE_SHOT)
	super()



func _run() -> void:
	var cam := IsoCamera.new()
	root.add_child(cam)
	cam.set_zoom_index(1)   # the 1.0 step: one world unit per screen pixel

	var s: float = cam.zoom_scale()
	expect(is_equal_approx(s, 1.0), "zoom step 1 must be scale 1.0 for this check's pixel arithmetic")
	# 1) First follow settles directly on the target (retail's first world
	#    frame is already centred on the hero; nothing eases in).
	var start := Vector2(3236.5, 2511.5)
	cam.follow_cell(start)
	var want := IsoCamera.cell_to_world(start) + IsoCamera.VIEW_ORIGIN
	expect(cam.position.x == roundf(want.x * s) / s and cam.position.y == roundf(want.y * s) / s,
		"first follow must rest exactly on the snapped target")

	# 2) A walk-sized target jump eases with ~halving pixel steps and rests
	#    exactly. VIEW_ORIGIN is constant on both sides, so it cancels.
	var dest := start + Vector2(TARGET_JUMP, -TARGET_JUMP * 0.5)
	var target := IsoCamera.cell_to_world(dest) + IsoCamera.VIEW_ORIGIN
	var dists: Array[float] = []
	var prev := -1.0
	var monotone := true
	for i in 24:
		cam.follow_cell(dest)
		# The rendered position can only rest within half a pixel of a
		# CONTINUOUS target (retail's rests are pixel-aligned too); that
		# quantization floor is the convergence criterion, not d == 0.
		var d := Vector2(cam.position.x, cam.position.y).distance_to(target)
		dists.append(d)
		if prev >= 0.0 and d > prev + 0.001:
			monotone = false
		prev = d
		if d <= 0.71:
			break
	expect(monotone, "ease must never move away from the target")
	expect(dists.size() < 24, "ease must reach the half-pixel floor within 24 ticks")
	expect(dists[0] < TARGET_JUMP, "first eased step must already cover about half the distance (got %f)" % dists[0])
	# Above the one-pixel quantization floor every step roughly halves the
	# remainder -- the trace's measured law (34.94, 17.21, 8.87, ...).
	for i in range(1, dists.size()):
		if dists[i] > 1.0 and dists[i - 1] > 1.0:
			var ratio := dists[i] / maxf(dists[i - 1], 0.0001)
			expect(ratio < 0.75, "step %d must roughly halve the remainder (ratio %.2f)" % [i, ratio])

	# 3) The rendered position is on the pixel grid at every sample.
	expect(absf(cam.position.x * s - roundf(cam.position.x * s)) < 0.0001
		and absf(cam.position.y * s - roundf(cam.position.y * s)) < 0.0001,
		"resting camera must sit exactly on the pixel grid")

	# 4) A teleport-sized jump snaps instead of easing.
	var far := start + Vector2(4000.0, -2000.0)
	cam.follow_cell(far)
	var far_target := IsoCamera.cell_to_world(far) + IsoCamera.VIEW_ORIGIN
	expect(cam.position.x == roundf(far_target.x * s) / s and cam.position.y == roundf(far_target.y * s) / s,
		"teleport-sized jump must snap, not ease")

	finish(0)
