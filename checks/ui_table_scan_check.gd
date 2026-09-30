extends SceneTree
## R0 acceptance: the scan-based gfx table reader works on both ELF and PE.
## The PE arm needs the Windows binary from the private workspace; if it
## isn't available the PE arm is SKIPPED (not a failure) while the ELF arm
## always runs against the real install.

const PE_SRC := "/home/rlinev/Projects/openheilig/donotpublish/analysis/decomp/win228eng/Sacred.exe"
const PE_TMP := "/tmp/openheilig-pe-test"

func _init() -> void:
	var fails := 0
	var ran := 0
	# ELF (the real install) -- always available.
	var elf := UiElements.new("/home/rlinev/Projects/openheilig/donotpublish/install", null)
	if elf.count_pieces() >= 64 and elf.rect(12) == Rect2i(0, 169, 230, 86) \
			and elf.names_resolved:
		ran += 1
		print("ok\tELF table: pieces=%d names resolved" % elf.count_pieces())
	else:
		fails += 1
		printerr("FAIL ELF: pieces=%d names=%s" % [elf.count_pieces(), elf.names_resolved])
	# PE -- needs the private workspace binary.
	if FileAccess.file_exists(PE_SRC):
		DirAccess.make_dir_recursive_absolute(PE_TMP)
		var dst := PE_TMP + "/sacred"
		if not FileAccess.file_exists(dst):
			var src := FileAccess.open(PE_SRC, FileAccess.READ)
			if src != null:
				var data := src.get_buffer(src.get_length())
				src.close()
				var out := FileAccess.open(dst, FileAccess.WRITE)
				if out != null:
					out.store_buffer(data)
					out.close()
		var pe := UiElements.new(PE_TMP, null)
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
		print("SKIP\tPE arm: binary not available in this checkout")
	print("PASS=%d FAIL=%d (ran=%d)" % [ran - fails, fails, ran])
	quit(1 if fails > 0 else 0)
