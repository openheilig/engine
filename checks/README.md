# checks — single-purpose gates

Each script here answers one question against the retail install and exits 0
or 1. They are meant to be run, not read for narrative: a check that passes is
a fact, and a check that fails is a bug report.

```
godot --headless --path . --script res://checks/<name>.gd
```

Every one states its own question and command line in its header comment.

## `check.gd` — why the base class exists

A failed `assert()` halts the script but leaves the SceneTree running, so a
check whose assertion fails does not fail — it **hangs**, produces no output,
and reads as slow rather than broken. That cost one 280-second run and a
misdiagnosis (findings log row 745) before it was spotted.

`check.gd` arms a failsafe on the first processed frame: reaching a frame at
all means `_init` returned without finishing, which is exactly what a failed
assertion looks like, and the run exits 1 immediately.

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
