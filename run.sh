#!/usr/bin/env sh
# Launch the port, or run the gates. No arguments needed: the retail install is
# found by Sacred.find_install() (a sibling of the workspace, or whatever
# --install= last recorded), so this only has to point Godot at this directory.
#
#   ./run.sh                       play it
#   ./run.sh --sector=50,39        any main.gd flag; everything is passed through
#   ./run.sh --checks              run every gate in checks/, print PASS/FAIL
#   ./run.sh --flags               list the flags main.gd actually parses
#
# --checks is here because it is the one thing worth running before believing a
# change, and `godot --headless --script res://checks/<x>_check.gd` one file at
# a time is the version people skip.
set -eu
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
GODOT=${GODOT:-godot}

case "${1:-}" in
--checks)
	pass=0 fail=0
	for c in "$DIR"/checks/*_check.gd; do
		name=$(basename "$c" .gd)
		# A failed assert() HANGS rather than exits, which is why every gate
		# is under a timeout: a hung gate must be a red line, not a red evening.
		if timeout 300 "$GODOT" --headless --path "$DIR" \
			--script "res://checks/$name.gd" >/dev/null 2>&1; then
			pass=$((pass + 1))
		else
			fail=$((fail + 1))
			printf 'FAIL %s\n' "$name"
		fi
	done
	printf 'PASS=%d FAIL=%d\n' "$pass" "$fail"
	[ "$fail" -eq 0 ]
	;;
--flags)
	# Read out of main.gd rather than listed here, so this cannot go stale.
	grep -oE '"--[a-z-]+=?' "$DIR/main.gd" | tr -d '"' | sort -u
	;;
--layers)
	exec "$GODOT" --headless --path "$DIR" --script res://parity/verify.gd
	;;
*)
	exec "$GODOT" --path "$DIR" -- "$@"
	;;
esac
