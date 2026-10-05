extends SceneTree
## R0 acceptance: the scan-based gfx table reader works on both ELF and PE.
## Pass --pe-exe=PATH to exercise an owned Windows Gold executable too.
## Without it the PE arm is explicitly SKIPPED; only the ELF arm is proven.
const SacredData := preload("res://sacred.gd")

func _init() -> void:
	var fails := 0
	var ran := 0
	# ELF (the real install) -- always available.
	var elf := UiElements.new(SacredData.find_install(), null)
	if elf.count_pieces() >= 64 and elf.rect(12) == Rect2i(0, 169, 230, 86) \
			and elf.names_resolved:
		ran += 1
		print("ok\tELF table: pieces=%d names resolved" % elf.count_pieces())
	else:
		fails += 1
		printerr("FAIL ELF: pieces=%d names=%s" % [elf.count_pieces(), elf.names_resolved])
	var pe_source := ""
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--pe-exe="):
			pe_source = argument.trim_prefix("--pe-exe=")
	if not pe_source.is_empty():
		var pe_root := ProjectSettings.globalize_path("user://checks/ui-table-%s-%s"
			% [OS.get_process_id(), Time.get_ticks_usec()])
		DirAccess.make_dir_recursive_absolute(pe_root)
		var dst := pe_root + "/sacred"
		if not FileAccess.file_exists(dst):
			var src := FileAccess.open(pe_source, FileAccess.READ)
			if src != null:
				var data := src.get_buffer(src.get_length())
				src.close()
				var out := FileAccess.open(dst, FileAccess.WRITE)
				if out != null:
					out.store_buffer(data)
					out.close()
		var pe := UiElements.new(pe_root, null)
		if pe.count_pieces() >= 64 and pe.rect(12) == Rect2i(0, 169, 230, 86) \
				and pe.rect(103).size == Vector2i(63, 63) and not pe.names_resolved:
			ran += 1
			print("ok\tPE table: pieces=%d elem12=%s elem103=%s names unresolved" % [
				pe.count_pieces(), pe.rect(12), pe.rect(103)])
		else:
			fails += 1
			printerr("FAIL PE: pieces=%d e12=%s e103=%s names=%s" % [
				pe.count_pieces(), pe.rect(12), pe.rect(103), pe.names_resolved])
	else:
		print("SKIP\tPE arm: supply --pe-exe=PATH to qualify it")
	print("PASS=%d FAIL=%d (ran=%d)" % [ran - fails, fails, ran])
	quit(1 if fails > 0 else 0)
