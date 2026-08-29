extends SceneTree
func _init() -> void:
	var install: String = Sacred.find_install()
	var pak := Sacred.Pak.new(install.path_join("pak/models.pak"))
	var models := Sacred.Models.new(pak)
	var rigs := Sacred.Rigs.new(models, PackedInt32Array([661]))
	var e := 661
	out_print(rigs, models, e, "IDLE")
	out_print(rigs, models, e, "FIDLE")
	quit()
func out_print(rigs, models, e: int, action: String) -> void:
	var ci: int = rigs.rest_clip(e) if action == "IDLE" else rigs.clip_for_action(e, action)
	print("%s -> clip %d = %s (score %f)" % [action, ci, models.entry_name(ci) if ci >= 0 else "<none>",
		rigs.score_for(e)])
