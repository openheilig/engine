class_name InstallProfile
extends RefCounted
## R0: WHICH RETAIL INSTALL THIS IS, decided before any reader opens a file.
##
## The old is_install() answered one question with two files: "can the terrain
## reader open something here?" That let a Windows tree (mixed-case PAK/,
## no Linux `sacred` binary) pass discovery and then die inside UiElements,
## which opens `install/sacred` at fixed ELF offsets -- a failure two systems
## away from the decision that caused it. This class answers the questions
## UP FRONT, with reasons:
##
##   family     which build tree this is (LGP_LINUX / WINDOWS_GOLD / UNKNOWN)
##   layout     how file names are cased on disk (LOWERCASE / MIXED / probes)
##   executable the engine binary present, with its format -- ELF32 is what
##              UiElements' table reader needs; a PE tree is a valid install
##              whose UI tables this engine cannot yet read, and that is a
##              DECLARED limitation, not a discovery-time crash
##
## THE RULES THIS ENFORCES (all from the 2026-09-29 revision, R0):
##   - an explicit --install= that fails is a HARD error naming that root;
##     no silent fall-through to a remembered or sibling path
##   - casing is probed ONCE and cached; ambiguous case-fold collisions are
##     reported, not silently resolved
##   - unknown executables do not pass because two UI anchors happen to match
##   - nothing here executes the retail binary
##
## Plain RefCounted, no scene tree, consistent with formats/.

enum Family { LGP_LINUX, WINDOWS_GOLD, UNKNOWN }
enum Layout { LOWERCASE, MIXED, MIXED_AMBIGUOUS, UNPROBED }

## What one file probe found.
class Probe extends RefCounted:
	var found := false
	var resolved := ""            ## the actual on-disk casing that worked
	var collision := ""           ## a second distinct casing folding to the same name, else ""

## The single entry point. `path` must already be simplified/absolute.
static func probe(path: String) -> InstallProfile:
	var p := InstallProfile.new()
	p.root = path
	if path.is_empty() or not DirAccess.dir_exists_absolute(path):
		p.errors.append("root does not exist: %s" % path)
		return p
	# --- the two files the OLD check used, still required: the engine reads
	# terrain and sectors before anything else.
	var tiles := _probe_file(path, "pak/tiles.pak")
	if not tiles.found:
		p.errors.append("missing pak/tiles.pak under any casing")
	var wldx := _probe_file(path, "world/sectors.wldx")
	if not wldx.found:
		p.errors.append("missing world/sectors.wldx under any casing")
	# --- case-fold collisions. Both casings reachable on ONE case-sensitive
	# filesystem is data corruption or a bad overlay; picking either silently
	# is how the wrong corpus gets read. Refuse with the exact names.
	for probe: Probe in [tiles, wldx]:
		if probe.found and probe.collision != "":
			p.errors.append("case-fold collision: both %s and %s exist -- refusing to pick one"
				% [probe.resolved, probe.collision])
	# --- the engine binary, whose FORMAT (not identity) gates the UI table
	# reader. ELF32 magic = 7f 45 4c 46 with ei_class 1; PE = "MZ". Probed
	# BEFORE the family decision so the ui_tables gap below can name it.
	var exe := _probe_file(path, "sacred")
	p.executable_found = exe.found
	p.executable_format = _executable_format(path, exe)
	# --- family. The LGP tree is all-lowercase; the Windows tree carries
	# PAK/, WORLD/, BIN/ in upper case. Decided from what the probes found,
	# never from a marker file with a guessed name.
	var pak := _probe_dir(path, "pak")
	var world := _probe_dir(path, "world")
	var lower_hits := 0
	var upper_hits := 0
	for d: Probe in [pak, world]:
		if not d.found:
			continue
		if d.resolved == d.resolved.to_lower():
			lower_hits += 1
		elif d.resolved == d.resolved.to_upper():
			upper_hits += 1
	if lower_hits == 2:
		p.layout = Layout.LOWERCASE
		# Family is provisional until the exe-format refusal below; a
		# lowercase tree with an ELF32 engine IS the LGP layout.
		if exe.found and p.executable_format == "elf32":
			p.family = Family.LGP_LINUX
	elif upper_hits == 2:
		p.layout = Layout.MIXED
		p.family = Family.WINDOWS_GOLD
		# A valid Windows tree. Its UI tables are NOT readable by this engine
		# yet (audit §8); record the real gap, never a crash and never a
		# silent degrade.
		if p.executable_format == "pe":
			p.capability_gaps.append(
				"ui_tables: PE executable found but this engine reads UI element tables from ELF32 only (formats/ui_elements.gd)")
		elif p.executable_found and p.executable_format != "":
			p.capability_gaps.append(
				"ui_tables: unrecognized executable format '%s'" % p.executable_format)
		else:
			p.capability_gaps.append("ui_tables: no engine executable found in this tree")
	elif lower_hits + upper_hits > 0:
		p.layout = Layout.MIXED_AMBIGUOUS
		p.errors.append("mixed directory casing (%d lower, %d upper) -- refusing to guess which tree this is"
			% [lower_hits, upper_hits])
	elif p.layout == Layout.LOWERCASE and exe.found and p.executable_format != "elf32":
		# A lowercase tree whose engine is not ELF32: not an LGP layout we
		# know, refused rather than treated as one.
		p.family = Family.UNKNOWN
		p.errors.append("lowercase tree but engine format is '%s', not elf32 -- not a recognized LGP install"
			% p.executable_format)
	return p


var root := ""
var family: int = Family.UNKNOWN
var layout: int = Layout.UNPROBED
var executable_found := false
var executable_format := ""            ## "elf32" | "pe" | "" (absent/unreadable)
var errors: PackedStringArray = []     ## why this root is NOT usable
var capability_gaps: PackedStringArray = []  ## usable, with named gaps


func ok() -> bool:
	return errors.is_empty() and layout != Layout.UNPROBED


## One line per problem, for the install-selection error surface.
func error_text() -> String:
	return "\n".join(errors)


func summary_line() -> String:
	var fam := "unknown"
	match family:
		Family.LGP_LINUX: fam = "lgp_linux"
		Family.WINDOWS_GOLD: fam = "windows_gold"
	return "install\troot=%s\tfamily=%s\tlayout=%d\texe=%s%s" % [
		root, fam, layout, executable_format if executable_found else "absent",
		"" if capability_gaps.is_empty()
			else "\tgaps=" + ",".join(capability_gaps)]


## --- probes. Each returns the FIRST casing that exists, and flags a second
## distinct casing folding to the same name (a real ambiguity: two files both
## reachable on a case-sensitive FS is data corruption or a bad overlay, and
## silently picking one is how the wrong corpus gets read).

static func _probe_file(root: String, rel: String) -> Probe:
	return _probe_generic(root, rel, func(p: String) -> bool: return FileAccess.file_exists(p))


static func _probe_dir(root: String, rel: String) -> Probe:
	return _probe_generic(root, rel, func(p: String) -> bool: return DirAccess.dir_exists_absolute(p))


static func _probe_generic(root: String, rel: String, exists: Callable) -> Probe:
	var p := Probe.new()
	var lower := root.path_join(rel)
	var upper := root.path_join(_upper_path(rel))
	if exists.call(lower):
		p.found = true
		p.resolved = rel
		if exists.call(upper) and upper != lower:
			p.collision = _upper_path(rel)
	elif exists.call(upper):
		p.found = true
		p.resolved = _upper_path(rel)
	return p


## Uppercases each path SEGMENT ("pak/tiles.pak" -> "PAK/TILES.PAK") -- not
## the whole string, which would mangle nothing here but keeps the rule
## explicit for future callers with extension-sensitive names.
static func _upper_path(rel: String) -> String:
	var parts := rel.split("/")
	for i in parts.size():
		parts[i] = parts[i].to_upper()
	return "/".join(parts)


## Reads just enough of the engine binary to classify it. Never executes it.
static func _executable_format(root: String, exe: Probe) -> String:
	if not exe.found:
		return ""
	var f := FileAccess.open(root.path_join(exe.resolved), FileAccess.READ)
	if f == null:
		return ""
	var head := f.get_buffer(6)
	f.close()
	if head.size() >= 6 and head.decode_u32(0) == 0x464C457F:
		return "elf32" if head[4] == 1 else "elf-non32"
	if head.size() >= 2 and head[0] == 0x4D and head[1] == 0x5A:
		return "pe"
	return "unknown"
