extends SceneTree
## What ACTION does a clip's name encode?
##
##   godot --headless --path . --script res://probes/clipname_probe.gd
##
## Sacred.Rigs binds a clip to a mesh by BONE GEOMETRY because the character
## prefixes do not line up (`UPI1_WALK_BH.GRN` belongs to `UPIRATE_01.GRN`).
## But the ACTION half of the name is a different question and looks reliable:
## `_WALK_`, `_IDLE_`, `_ATTACK_`, `_DYING_`. This probe censuses the tokens so
## the vocabulary is measured rather than assumed.
func _init() -> void:
	var install := Sacred.find_install()
	var pak := Sacred.Pak.new(install.path_join("pak/models.pak"))
	var models := Sacred.Models.new(pak)
	var tokens: Dictionary = {}
	var clips := 0
	var named := 0
	for e in pak.count():
		if not models.is_motion(e):
			continue
		clips += 1
		var nm := models.entry_name(e).to_upper()
		if nm == "":
			continue
		named += 1
		var stem := nm.replace(".GRN", "")
		for t in stem.split("_"):
			if t == "":
				continue
			tokens[t] = int(tokens.get(t, 0)) + 1
	var rows: Array = []
	for k in tokens:
		rows.append([int(tokens[k]), k])
	rows.sort_custom(func(a, b): return a[0] > b[0])
	print("clips=%d named=%d distinct_tokens=%d" % [clips, named, tokens.size()])
	print("count\ttoken")
	for i in mini(45, rows.size()):
		print("%d\t%s" % [rows[i][0], rows[i][1]])
	quit()
