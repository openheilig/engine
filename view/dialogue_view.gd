extends PanelContainer
## Real choice controls consume installed captions and call the bytecode runtime.
## Parent owns simulation/input suspension and drains the canonical cast effects.
signal result_ready(result: Dictionary)
signal closed

var runtime: RefCounted
var _speaker: Label
var _prose: RichTextLabel
var _choices: VBoxContainer
var _error: Label

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	anchor_left = 0.12
	anchor_right = 0.88
	anchor_top = 0.55
	anchor_bottom = 0.95
	var margins := MarginContainer.new()
	for edge in ["left", "top", "right", "bottom"]:
		margins.add_theme_constant_override("margin_%s" % edge, 16)
	add_child(margins)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 10)
	margins.add_child(content)
	_speaker = Label.new()
	content.add_child(_speaker)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size.y = 100
	content.add_child(scroll)
	_prose = RichTextLabel.new()
	_prose.bbcode_enabled = false
	_prose.fit_content = true
	_prose.scroll_active = false
	_prose.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_prose)
	_error = Label.new()
	_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_error)
	_choices = VBoxContainer.new()
	content.add_child(_choices)
	var dismiss := Button.new()
	dismiss.text = "Close"
	dismiss.focus_mode = Control.FOCUS_ALL
	dismiss.pressed.connect(close_dialogue)
	content.add_child(dismiss)
	hide()

func bind_runtime(value: RefCounted) -> void:
	runtime = value

func show_dialogue(handle: String) -> Dictionary:
	if runtime == null:
		return {"ok": false, "error": "dialogue runtime is not bound"}
	var result: Dictionary = runtime.open(handle)
	_present(result)
	result_ready.emit(result)
	return result

func _choose(index: int, revision: int) -> void:
	var result: Dictionary = runtime.choose(index, revision)
	_present(result)
	result_ready.emit(result)

func _present(result: Dictionary) -> void:
	for child in _choices.get_children():
		_choices.remove_child(child)
		child.queue_free()
	_speaker.text = str(result.get("handle", ""))
	_prose.clear()
	for line: Dictionary in result.get("texts", []):
		if not _prose.text.is_empty():
			_prose.append_text("\n\n")
		_prose.append_text(str(line["text"]))
	_error.text = str(result.get("error", ""))
	var index := 0
	for choice: Dictionary in result.get("choices", []):
		var button := Button.new()
		button.text = str(choice["text"])
		button.focus_mode = Control.FOCUS_ALL
		button.pressed.connect(_choose.bind(index, int(result["revision"])))
		_choices.add_child(button)
		index += 1
	if result.get("ok", false) and str(result.get("handle", "")).is_empty():
		hide()
		closed.emit()
	else:
		show()
		if _choices.get_child_count() > 0:
			_choices.get_child(0).grab_focus()

func close_dialogue() -> void:
	if runtime != null:
		runtime.close()
	hide()
	closed.emit()

func _unhandled_key_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		close_dialogue()
		get_viewport().set_input_as_handled()
