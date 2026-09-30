class_name InventoryPanel
extends CanvasLayer
## U0: the inventory surface. A minimal text panel listing the hero's
## INVENTORY instances (name x count), toggled with I. The pickup/drop/
## equip COMMANDS already exist through the session door (C2/S0); this is
## their visual face. Deliberately plain -- retail's own inventory is a
## drag-and-drop grid whose art layout is un-decoded; upgrading the surface
## does not change the commands.

var _label: Label


func _init() -> void:
	layer = 10
	_label = Label.new()
	_label.position = Vector2(16, 64)
	_label.size = Vector2(360, 400)
	_label.add_theme_font_size_override("font_size", 14)
	_label.add_theme_color_override("font_color", Color(1, 0.95, 0.8))
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_label.add_theme_constant_override("outline_size", 4)
	add_child(_label)
	visible = false


func toggle() -> void:
	visible = not visible


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	if k.keycode == KEY_I:
		toggle()


## Rebuild the text from the session's INVENTORY instances. `items` is the
## Sacred.Items name table; unknown types print their id.
func refresh(instances: Array, items) -> void:
	if _label == null:
		return
	var lines := PackedStringArray()
	lines.append("INVENTORY")
	var counts: Dictionary = {}
	var order: Array[int] = []
	for inst in instances:
		var t: int = inst["definition_id"] if inst is Dictionary else inst.definition_id
		if not counts.has(t):
			order.append(t)
			counts[t] = 0
		counts[t] += 1
	for t in order:
		var nm: String = items.name_of(t)
		if nm == "":
			nm = str(t)
		lines.append("%s x%d" % [nm, counts[t]])
	if order.is_empty():
		lines.append("(empty)")
	_label.text = "\n".join(lines)
