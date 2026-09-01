# checks — single-purpose gates

Each script here answers one question against the retail install and exits 0
or 1. They are meant to be run, not read for narrative: a check that passes is
a fact, and a check that fails is a bug report.

```
godot --headless --path . --script res://checks/<name>.gd
```

Every one states its own question and command line in its header comment.

~~**All 43 pass, and every one needs nothing but the retail install** —
measured by running the loop below end to end on 2026-08-25.~~
**STALE since before 2026-09-01:** `clip_layout_check` is RED on master —
`HORS_DYING_A.GRN`, its own pinned sampled-variant entry, refuses to
decode (`Models.clip: entry … not a walkable motion entry`), failing the
check's line-94 assert. Stash-proven pre-existing: identical failure on
the tree before the interpolation commit (2d52ff6) touched either file it
did. Logged as an open decoder defect (findings row 1220,
open-questions.md); everything else in this directory passed the loop the
last time it was run end to end. The lesson this file itself teaches
applies to its own claim: a README that describes a gate as green hides a
gate that has gone red.

This file used to say that `pax_check` was the exception, needing a
third-party `$SACRED_CHARS` corpus and exiting 1 without one. That stopped
being true when the check was rewritten to read the install's own
`templates/hero00.ptx` … `hero07.ptx`, which are `.pax` files in all but
extension; see that check's own header for why a template *is* a savegame.
`$SACRED_CHARS` is still honoured when set, as an EXTRA corpus. The claim
here outlived the code by long enough to be worth naming: a README that
describes a gate as conditionally red hides a gate that has gone green.

```
for f in checks/*_check.gd; do
  godot --headless --path . --script "res://$f" || echo "FAILED $f"
done
```

## `check.gd` — why the base class exists

A failed `assert()` halts the script but leaves the SceneTree running, so a
check whose assertion fails does not fail — it **hangs**, produces no output,
and reads as slow rather than broken. That cost one 280-second run and a
misdiagnosis (findings log row 745) before it was spotted.

`check.gd` arms a failsafe on the first processed frame: reaching a frame at
all means `_init` returned without finishing, which is exactly what a failed
assertion looks like, and the run exits 1 immediately.

**An assertion outside `_init` must use `expect()`, not `assert()`** — found
2026-08-15 by mutation, not by reading. A failed `assert()` inside a helper
function does not abort `_init`: Godot prints `SCRIPT ERROR`, the function
returns, and `_init` goes on to print its OK line and exit 0. The check reports
success while its assertions fail on screen, which is worse than the hang this
base class was written to fix, because a hang is at least visible. Eight
assertions across four checks sat behind that hole, including the BEAR/WOLF
spot checks that exist precisely so a human recognises a wrong result.
`expect()` records the failure and makes `finish()` exit 1 whatever code it is
handed.

Two rules every check follows, both learned by measurement:

1. Call `super()` as the **first** line of its own `_init`. GDScript does not
   call a base `_init` when the child defines one; without it the failsafe is
   never armed and the hang comes straight back.
2. Exit through `finish()`, never `quit()`. `quit()` leaves the failsafe armed,
   so a *successful* run reports exit 1.

Enforcing rule 2 by overriding `SceneTree.quit()` was tried first and is not
possible: this project treats the "overrides a native method" warning as an
error.

## Related

The byte-for-byte parity harness lives in [`../parity/`](../parity/); the
one-shot investigations that preceded these gates are in
[`../probes/`](../probes/).
