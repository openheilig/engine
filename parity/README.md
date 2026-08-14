# parity — the Godot side of the gates

Two scripts, both written to be diffed against an independent implementation
in the [tools](../../tools/parity/) repo. Neither forms a verdict; each prints
facts in a fixed order so a diff can.

| Script | Diffed against | Run |
|---|---|---|
| `verify.gd` | `tools/parity/verify_ref.py` | `godot --headless --path . --script res://parity/verify.gd` |
| `grnwalk.gd` | `tools/formats/grn_tagwalk.py`, via `tools/parity/grn_parity.sh` | `... --script res://parity/grnwalk.gd --corpus` |

The two `.GRN` walkers never read each other — that is the whole value of the
comparison. `grnwalk.gd` came first, from a written spec; the Python one was
written from direct byte reads. A transliteration of either would make the
diff structurally incapable of failing.

`verify.gd` also carries `LAYER_RULES`, the architectural gate: `world/` may
not touch the scene tree or threads, `view/` may not name a simulation type or
define a per-frame entry point. It scans those two directories only, which is
why `iso_camera.gd` sits at the project root and the checks sit in
[`../checks/`](../checks/).

Order matters in both files: the gate is a line-for-line diff, not a set
comparison, so a reordered print is a failure.
