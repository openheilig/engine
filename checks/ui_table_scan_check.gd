extends SceneTree
## R0 acceptance: the same scan-based reader must locate and decode the gfx
## table from the Windows PE with both anchors exact, and leave names
## unresolved (declared gap), while the LGP ELF keeps its names.

func _init() -> void:
	var fails := 0
	# PE
	var pe := UiElements.new("/tmp/openheilig-pe-test", null)
	if pe.count_pieces() >= 64 and pe.rect(12) == Rect2i(0, 169, 230, 86) \
			and pe.rect(103).size == Vector2i(63, 63) and not pe.names_resolved:
		print("ok\tPE table: pieces=%d elem12=%s elem103=%s names unresolved" % [
			pe.count_pieces(), pe.rect(12), pe.rect(103)])
	else:
		fails += 1
		printerr("FAIL PE: pieces=%d e12=%s e103=%s names=%s" % [
			pe.count_pieces(), pe.rect(12), pe.rect(103), pe.names_resolved])
	# ELF (the real install)
	var elf := UiElements.new("/home/rlinev/Projects/openheilig/donotpublish/install", null)
	if elf.count_pieces() >= 64 and elf.rect(12) == Rect2i(0, 169, 230, 86) \
			and elf.names_resolved:
		print("ok\tELF table: pieces=%d names resolved" % elf.count_pieces())
	else:
		fails += 1
		printerr("FAIL ELF: pieces=%d names=%s" % [elf.count_pieces(), elf.names_resolved])
	print("PASS=%d FAIL=%d" % [2 - fails, fails])
	quit(1 if fails > 0 else 0)
