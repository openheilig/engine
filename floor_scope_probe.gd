extends SceneTree
## Probe: how much content is behind the UNREAD WldxEntry +0x0c handle into
## world/floor.pak (6,713,136 records, 188 MB)? Row 662 measured +0x0c as zero
## for all 4096 cells of sector 50,39; that is one sector out of 6050. Sample
## widely before concluding anything. Read-only.
##   godot --headless --path godot-port --script res://floor_scope_probe.gd

func _init() -> void:
	var install := Sacred.find_install()
	var world := Sacred.World.new(install.path_join("world"))
	var fp := Sacred.Pak.new(install.path_join("world/floor.pak"))
	print("floor_pak\topen=%s\tcount=%d" % [fp.is_open(), fp.count()])

	var sectors := 0
	var cells := 0
	var nonzero := 0
	var max_handle := 0
	var per_sector_hits: Array = []
	# A deterministic spread: every 7th sector index across the whole grid.
	for gy in range(0, 100, 7):
		for gx in range(0, 100, 7):
			if not world.has_sector(gx, gy):
				continue
			var stream := world.sector(gx, gy)
			if stream.size() < Sacred.NAME + Sacred.SECT * Sacred.SECT * Sacred.CELL:
				continue
			sectors += 1
			var hits := 0
			for i in Sacred.SECT * Sacred.SECT:
				cells += 1
				var h := stream.decode_u32(Sacred.NAME + i * Sacred.CELL + 0x0c)
				if h != 0:
					nonzero += 1
					hits += 1
					max_handle = maxi(max_handle, h)
			if hits > 0 and per_sector_hits.size() < 12:
				per_sector_hits.append("%d,%d=%d" % [gx, gy, hits])
	print("sample\tsectors=%d\tcells=%d\tnonzero_0x0c=%d\tmax_handle=%d\tcount=%d" % [
		sectors, cells, nonzero, max_handle, fp.count()])
	print("sample_hits\t%s" % ", ".join(per_sector_hits))

	# What does a floor.pak record look like? The Xentax page decodes the
	# 16-byte OBJ/135 record as {File Index, Unknown, Tag_CDCDCDCD, Next Index}.
	for i in [1, 2, 3, 100, 1000]:
		var r := fp.blob(i)
		if r.size() < 16:
			print("floor_rec\t%d\tsize=%d" % [i, r.size()])
			continue
		print("floor_rec\t%d\tsize=%d\t+0=%d\t+4=%d\t+8=0x%08x\t+12=%d" % [
			i, r.size(), r.decode_u32(0), r.decode_u32(4), r.decode_u32(8), r.decode_u32(12)])
	quit()
