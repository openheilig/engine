extends "res://checks/check.gd"
## Installed Romata prose/choice -> actual Godot Button -> actual VM callback.
const Cast := preload("res://world/quest_cast.gd")
const Dialogue := preload("res://world/dialogue.gd")
const View := preload("res://view/dialogue_view.gd")
const Session := preload("res://world/game_session.gd")
const Registry := preload("res://world/actor_registry.gd")
const Start := preload("res://formats/startcode.gd")
const Resources := preload("res://formats/resources.gd")

func _init() -> void:
	super()
	allow_frames(10000)
	call_deferred("_exercise")

func _exercise() -> void:
	var install := Sacred.find_install()
	if not expect(not install.is_empty(), "requires retail install"):
		finish(1)
		return
	var dir := install.path_join("bin/type_npc_zwerg")
	var session := Session.new()
	session.registry = Registry.new()
	session.quest_log = Cast.new()
	session.quest_log.bind_runtime(session)
	var runtime := Dialogue.new(dir, session.quest_log,
		Resources.new(install.path_join("scripts/us/global.res")))
	if not expect(runtime.bootstrap(Start.new(dir)) and runtime.start_quest(1), "Dwarf setup refused: %s" % runtime.last_error):
		finish(1)
		return
	var view := View.new()
	root.add_child(view)
	view.bind_runtime(runtime)
	var result := view.show_dialogue("res:17085")
	if not expect(result.get("ok", false) and result.get("choices", []).size() == 1, "installed dialogue missing"):
		finish(1)
		return
	var button := _find_button(view, str(result["choices"][0]["text"]))
	if expect(button != null, "no semantic Button for installed caption"):
		expect(button.focus_mode == Control.FOCUS_ALL, "choice is not keyboard focusable")
		button.pressed.emit()
		expect(session.hero_gold == 2300, "semantic button did not execute actual callback")
		expect(not view.visible, "empty callback result did not close dialogue")
		var again := view.show_dialogue("res:17085")
		expect(again.get("choices", [])[0]["procedure"] == "btn_HQNEW_OK", "real button callback did not change next conversation")
	view.queue_free()
	print("dialogue_view_check OK installed caption -> focusable Button -> actual trigger03")
	finish()

func _find_button(node: Node, caption: String) -> Button:
	if node is Button and node.text == caption:
		return node
	for child in node.get_children():
		var found := _find_button(child, caption)
		if found != null:
			return found
	return null
