extends "res://checks/check.gd"
## The F3 overlay renders. Every line it prints reaches through a live engine
## API (Performance monitors, DisplayServer, IsoCamera's projection,
## SectorView's residency), and a renamed monitor or a moved field there fails
## SILENTLY at runtime -- the overlay would simply be missing a line nobody is
## watching for. So the gate builds the real thing and asserts on its text.
##
## Run:
##   godot --headless --path godot-port --script res://checks/overlay_check.gd

const OverlayScript := preload("res://debug_overlay.gd")
## Every line of _lines() should be identifiable by one word of its own. The
## "mouse cell" line is absent here and only here: it needs a live viewport,
## which a node added before the tree starts running does not have.
const WANTED := ["fps", "window", "cam cell", "sim tick",
	"player #", "sectors", "draw", "mem"]


func _init() -> void:
	super()
	var cam := IsoCamera.new()
	root.add_child(cam)

	var registry := ActorRegistry.new()
	var sim := Sim.new()
	sim.focus_actor_id = registry.spawn(1, Vector2(3232.0, 3232.0), 75, 100)

	var view := SectorView.new()
	# Never set up with paks here: is_settled() would ask the camera for its
	# wanted set. The overlay only reads residency counts off it, and this is
	# the one field that lets those be read without a streamed world.
	view._streaming = false

	var overlay: CanvasLayer = OverlayScript.new()
	overlay.setup(cam, view, sim, registry)
	root.add_child(overlay)
	overlay.visible = true
	overlay._process(1.0)

	var text: String = overlay._label.text
	print(text)
	for want: String in WANTED:
		expect(text.contains(want), "overlay line missing: %s" % want)
	expect(text.contains("hp 75/100"), "player hp not reported")
	expect(text.count("\n") == WANTED.size() - 1,
		"expected %d lines, got %d" % [WANTED.size(), text.count("\n") + 1])

	# The label is a child only once _ready has run, which it has not here --
	# so it is freed explicitly rather than with its parent.
	overlay._label.free()
	overlay.free()
	view.free()
	cam.free()
	print("overlay_check OK")
	finish(0)
