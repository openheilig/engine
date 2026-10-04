extends "res://checks/check.gd"
## G1: class 6 is the day-body item, not an absent hero or an enemy model.
## Production start -> selected template -> Items -> Models -> PlayerView.
## Native motion references distinguish the second form without inventing a
## clock, transformation ability, or a selectable class 7.

func _init() -> void:
	super()
	var install := Sacred.find_install()
	assert(not install.is_empty(), "retail install is required")
	var items := Sacred.Items.new(Sacred.Pak.new(install.path_join("pak/items.pak")))
	var models := Sacred.Models.new(Sacred.Pak.new(install.path_join("pak/models.pak")))
	var textures := Sacred.Pak.new(install.path_join("pak/texture.pak"))
	var creatures := Sacred.Creatures.new(install.path_join("pak"))
	assert(items.name_of(6).to_upper() == "VLADY_D.GRN", "class 6 must name the native day body")
	assert(items.name_of(7).to_upper() == "VLADY_N.GRN", "type 7 must name the distinct night body")
	assert(creatures.class_of(6) == 1 and creatures.class_of(7) == 1,
		"both forms must be hero definitions, not enemy creature definitions")
	assert(not Sacred.Hero.TYPE_DIR.has(7), "a second form must not become a ninth selectable class")

	var app = load("res://main.gd").new()
	app._start_class = "type_npc_vampirelady"
	assert(app.call("_apply_retail_start", install), "Vampiress must resolve through production startup")
	assert(app._player_model == items.name_of(6), "startup must use the native class 6 body")
	assert(app.start_cell == Vector2(3500, 2477) and app._retail_start_layer == 2,
		"Vampiress must keep her authored start position and layer")
	app._shadow_items = items
	app._shadow_creatures = creatures
	assert(app.call("_resolve_player_type") == 6, "native actor type must remain class 6")
	var hero := Sacred.Hero.new(install.path_join("templates").path_join(app._start_template))
	assert(hero.found and hero.character_type == 6 and hero.level == 1,
		"startup must select the class 6 level-one template")
	var attrs := hero.attributes()
	var session := GameSession.new_game(install, app.start_cell, "", app._start_template)
	assert(session.start_class == "type_npc_vampirelady" and session.hero_level == 1,
		"session must retain the selected class")
	assert(session.hero_base_stk == attrs[0] and session.hero_base_rephy == attrs[3],
		"session must derive stats from the Vampiress, not the default hero")

	var day_entry := models.index_of(items.name_of(6))
	var night_entry := models.index_of(items.name_of(7))
	assert(day_entry >= 0 and night_entry >= 0 and day_entry != night_entry,
		"native day/night items must resolve to different mesh entries")
	for entry in [day_entry, night_entry]:
		assert(models.kind_of(entry) == Sacred.Models.KIND_MESH, "a motion cannot substitute for a body")
	var day_idle := models.native_motion_entry(day_entry, 1)
	var night_idle := models.native_motion_entry(night_entry, 1)
	assert(day_idle >= 0 and night_idle >= 0 and day_idle != night_idle,
		"native motion headers must distinguish the two forms")
	assert(models.entry_name(day_idle) == "VMPD_IDLE_BH.GRN"
		and models.entry_name(night_idle) == "VMPN_IDLE_BH.GRN",
		"day and night bodies must use their own authored idle references")
	assert(models.native_motion_entry(day_entry, 0) == -1,
		"an absent native reference must not borrow another form's clip")

	var body := PlayerView.new(models, app._player_model, textures)
	assert(body.node != null and body.model_index == day_entry,
		"production PlayerView must build the actual day body, not a fallback")
	var view := body.node as ModelView
	# Retail character-select output identifies eight ordered day-body batches;
	# every batch's uploaded skin matches our material decoder (research row 902).
	assert(view.surfaces == 8 and view.textured_surfaces == 8,
		"every native day-body batch must retain its decoded skin")
	assert(body.can_face(), "native body must support production biped facing")
	assert(view.play_clip(models, day_idle), "production ModelView must pose the authored day idle")
	print("vampire_body_check\tOK\tmodel=%s\ttype=6\tcell=3500,2477\tlayer=2\thp=%d\tsurfaces=%d\tclip=%s"
		% [app._player_model, session.player_hp_max, view.surfaces, models.entry_name(day_idle)])
	body.node.free()
	app.free()
	finish()
