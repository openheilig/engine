## E2: the kill-to-loot roll.
extends RefCounted
## E2: the kill→loot roll, transcribed from the Linux 1.0.02 binary.
## Sacred has NO per-creature loot tables -- creature.pak carries no loot
## columns; what drops is rolled from class + creature level + balance.bin
## chances + static category tables. Proof and addresses:
## tmp/e2-loot/notes.md (sub_81B0BC0 generic roll, sub_835EA48
## getRandomItem, first-kill table at .data 0x8793500).
##
## Named ceiling (ponytail): getRandomItem's level window (±level/3) and
## rarity-flag filter are NOT implemented -- items.gd does not decode the
## items.pak item-level byte yet. v1 picks a uniform valid record of the
## rolled category; the upgrade path is decoding item level and porting
## the window exactly.

## balance.bin file offsets (research/formats/generated/balance-keymap.tsv;
## the executable binds them at 0x8B89CBC/C0/C4/CD4).
const OFF_DROP_WAFFE := 2208   ## 330 permille
const OFF_DROP_RUESTUNG := 2212## 880 permille
const OFF_DROP_GOLD := 2216    ## 300 permille
const OFF_DROP_SAFT := 2232    ## 180 permille

## unk_86E2804: the armour-family categories the generic roll draws from
## (items.pak +0x2e category enum: body/shield/helmet/boots/belt/shoulder/
## arms/legs/gauntlets/wings/mount).
const ARM_CATEGORIES := [6, 13, 17, 18, 19, 21, 22, 23, 24, 25, 29]
## The once-per-type arm's categories.
const OTHER_CATEGORIES := [8, 20]
## Tiered gold piles: items.pak definition ids by creature level.
const GOLD_TIERS := [[5132, 4], [5133, 9], [5134, 19], [5135, 1 << 30]]

const UNIQUE_TABLE_VADDR := 0x8793500
const UNIQUE_COUNT := 123

const Common := preload("res://formats/common.gd")

static var _unique_cache: PackedInt32Array = []


## One generic roll for a killed creature. Returns the items.pak
## definition id to drop, 0 for nothing. `first_of_type` selects the
## unique/set table instead of the generic arms (retail: first kill of a
## creature type per session; the caller owns the seen-types set).
static func roll(items, balance, creature_class: int, creature_level: int,
		rng: RandomNumberGenerator, first_of_type: bool) -> int:
	if first_of_type:
		var uniques := unique_table()
		if uniques.size() == UNIQUE_COUNT:
			return uniques[rng.randi_range(0, UNIQUE_COUNT - 1)]
	var drop_gold: int = balance.i32(OFF_DROP_GOLD, 300)
	var drop_waffe: int = balance.i32(OFF_DROP_WAFFE, 330)
	var drop_ruestung: int = balance.i32(OFF_DROP_RUESTUNG, 880)
	var drop_saft: int = balance.i32(OFF_DROP_SAFT, 180)
	var r := rng.randi_range(0, 999)
	if r < drop_saft:
		return 0  # potion arm: sub_8159AFE's potion pool is unported (named gap).
	r = rng.randi_range(0, 999)
	# Loot arm. Retail rolls the arms in order, each against its own draw.
	if r < drop_gold or creature_class == 6 or creature_class == 11:
		return gold_item(creature_level)
	r = rng.randi_range(0, 999)
	if r < drop_waffe:
		return pick_category(items, 5, rng)
	r = rng.randi_range(0, 999)
	if r < drop_ruestung:
		return pick_category(items,
			ARM_CATEGORIES[rng.randi_range(0, ARM_CATEGORIES.size() - 1)], rng)
	return pick_category(items,
		OTHER_CATEGORIES[rng.randi_range(0, OTHER_CATEGORIES.size() - 1)], rng)


## The tiered gold pile for a creature level (5132 ≤4, 5133 ≤9, 5134 ≤19,
## else 5135).
static func gold_item(creature_level: int) -> int:
	for tier in GOLD_TIERS:
		if creature_level <= int(tier[1]):
			return int(tier[0])
	return int(GOLD_TIERS[-1][0])


## Uniform valid record of `category` (getRandomItem's category filter,
## without the level window). 0 when the category is empty.
static func pick_category(items, category: int, rng: RandomNumberGenerator) -> int:
	var pool: Array[int] = []
	for i in items.record_count():
		if items.category_of(i) == category:
			pool.append(i)
	if pool.is_empty():
		return 0
	return pool[rng.randi_range(0, pool.size() - 1)]


## The 123 unique/set item ids at .data 0x8793500, read at runtime from the
## user's own binary (never shipped). Empty when the binary is unavailable.
static func unique_table() -> PackedInt32Array:
	if not _unique_cache.is_empty():
		return _unique_cache
	var install := Sacred.find_install()
	var off := Common.elf_vaddr_offset(install.path_join("sacred"), UNIQUE_TABLE_VADDR)
	if off < 0:
		return _unique_cache
	var f := FileAccess.open(install.path_join("sacred"), FileAccess.READ)
	if f == null:
		return _unique_cache
	f.seek(off)
	for i in UNIQUE_COUNT:
		_unique_cache.append(f.get_32())
	return _unique_cache
