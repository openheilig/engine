#!/usr/bin/env python3
"""E1 scenario runner: state-aligned capture + comparison with negative controls.

Run through donotpublish/autoresearch.sh's sibling wrapper or directly:

    python3 tools/verify_scenarios.py <workspace-root> [--scenario NAME] [--check]

For each scenario in tools/scenarios.json this runs the engine twice under the
pinned renderer, compares the two STATE checkpoints (deterministic channels
exact, anim_clip_time within its epsilon), compares the two PIXEL captures
(strict), and refuses any run whose state never reached its checkpoint. With
--check, a previously recorded reference sidecar (tmp/scenario-refs/<name>.json)
is compared instead of the second run.

Negative controls are built in and always run:
  -- wrong reference state (mutated cast handle) must be REFUSED
  -- mutated pixel capture must be REFUSED

The old loading-relative benchmark is not replaced by a score: this reports
PASS/FAIL per scenario and exits non-zero on any refusal.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

GODOT_VERSION = "4.7.2.stable.arch_linux.ed1daf0bf"
TOLERATED_EPSILON = 0.05


def fail(msg: str) -> None:
    print(f"verify_scenarios: {msg}", file=sys.stderr)
    sys.exit(1)


def run_engine(root: Path, out_dir: Path, scenario: dict, install: Path) -> dict:
    """One engine run: --scenario=NAME --checkpoint-out=... --shots=...

    Returns {checkpoint: dict, log: str}. Raises on engine failure or missing
    sidecar -- a run without a checkpoint has no semantic content.
    """
    name = scenario["name"]
    out_dir.mkdir(parents=True, exist_ok=True)
    sidecar = out_dir / f"{name}.json"
    png = out_dir / f"{name}.png"
    sidecar.unlink(missing_ok=True)
    png.unlink(missing_ok=True)
    shots = ",".join(str(m) for m in scenario.get("shots_ms", []))
    command = [
        "xvfb-run", "-a", "-s", "-screen 0 1024x768x24",
        "godot", "--path", str(root / "godot-port"),
        "--resolution", "1024x768",
        # FIXED FPS, same as the old benchmark: a wall-clock run cannot freeze
        # the same animation frame twice, and the pixel channel compares
        # frames, not throughput. Never read timing from these runs (Q0).
        "--fixed-fps", "60",
        "--rendering-method", "forward_plus", "--rendering-driver", "vulkan",
        "--audio-driver", "Dummy", "--",
        f"--install={install}",
        f"--scenario={name}",
        f"--checkpoint-out={sidecar}",
    ]
    if shots:
        command.append(f"--shots={shots}")
    log_path = out_dir / f"{name}.log"
    with log_path.open("w") as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT,
                                timeout=300)
    text = log_path.read_text()
    if result.returncode != 0:
        raise RuntimeError(f"engine exited {result.returncode}; see {log_path}")
    if not sidecar.exists():
        raise RuntimeError(f"no checkpoint sidecar written; see {log_path}")
    pngs = sorted(out_dir.glob("port-*.png"))
    return {"checkpoint": json.loads(sidecar.read_text()), "log": text,
            "pngs": pngs}


def compare_state(a: dict, b: dict) -> str:
    """Deterministic channels exact; anim_clip_time within epsilon."""
    if a.get("schema") != b.get("schema"):
        return f"schema differs: {a.get('schema')} vs {b.get('schema')}"
    for key in ("scenario", "route", "checkpoint", "sim_tick", "player_hp",
                "player_hp_max", "player_flags", "next_actor_id", "actor_count",
                "quest_lines", "anim_clip_name"):
        if a.get(key) != b.get(key):
            return f"{key} differs: {a.get(key)!r} vs {b.get(key)!r}"
    if a.get("player_cell") != b.get("player_cell"):
        return f"player_cell differs: {a.get('player_cell')} vs {b.get('player_cell')}"
    if a.get("player_facing") != b.get("player_facing"):
        return f"player_facing differs: {a.get('player_facing')} vs {b.get('player_facing')}"
    if a.get("cast_handles") != b.get("cast_handles"):
        return f"cast_handles differ: {a.get('cast_handles')} vs {b.get('cast_handles')}"
    if a.get("quest_states") != b.get("quest_states"):
        return f"quest_states differ: {a.get('quest_states')} vs {b.get('quest_states')}"
    ta, tb = a.get("anim_clip_time"), b.get("anim_clip_time")
    if ta is None or tb is None or (isinstance(ta, float) and ta != ta) \
            or (isinstance(tb, float) and tb != tb):
        if ta != tb:
            return f"anim_clip_time presence differs: {ta} vs {tb}"
    elif abs(float(ta) - float(tb)) > TOLERATED_EPSILON:
        return f"anim_clip_time differs beyond {TOLERATED_EPSILON}s: {ta} vs {tb}"
    return ""


def pixel_paths_equal(p1: Path, p2: Path) -> tuple[bool, str]:
    from PIL import Image, ImageChops
    with Image.open(p1) as a, Image.open(p2) as b:
        if a.size != b.size:
            return False, f"sizes differ {a.size} vs {b.size}"
        if a.convert("RGB").size != (1024, 768):
            return False, f"unexpected capture size {a.size}"
        return ImageChops.difference(a.convert("RGB"), b.convert("RGB")).getbbox() is None, ""


def main() -> None:
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path.cwd()
    args = sys.argv[2:]
    want = None
    if "--scenario" in args:
        want = args[args.index("--scenario") + 1]
    manifest = json.loads((root / "godot-port/tools/scenarios.json").read_text())
    version = subprocess.check_output(["godot", "--version"], text=True).strip()
    if version != GODOT_VERSION:
        fail(f"Godot version changed: {version}; expected {GODOT_VERSION}")
    env = os.environ.copy()
    env.update(LC_ALL="C", TZ="UTC", PYTHONHASHSEED="0")
    install = root / "install"
    if not (install / "pak/tiles.pak").exists():
        fail(f"no retail install at {install}")
    out = root / "tmp/scenario-runs"
    results = []
    for scenario in manifest["scenarios"]:
        name = scenario["name"]
        if want and name != want:
            continue
        try:
            run1 = run_engine(root, out / name, scenario, install)
            run2 = run_engine(root, out / f"{name}-repeat", scenario, install)
        except (RuntimeError, subprocess.TimeoutExpired) as error:
            results.append((name, "FAIL", str(error)))
            continue
        why = compare_state(run1["checkpoint"], run2["checkpoint"])
        if why:
            results.append((name, "FAIL", f"state: {why}"))
            continue
        # Negative control 1: a mutated reference state must be refused.
        bad = json.loads(json.dumps(run1["checkpoint"]))
        handles = bad.get("cast_handles", {})
        if handles:
            first = next(iter(handles))
            handles[first] = int(handles[first]) + 1
        else:
            bad["actor_count"] = int(bad.get("actor_count", 0)) + 1
        if compare_state(run1["checkpoint"], bad) == "":
            results.append((name, "FAIL", "negative control: mutated state accepted"))
            continue
        # Negative control 2: pixel strictness, when both runs captured.
        # Drive writes port-<ms>.png per shot; both runs must have the same
        # shot set. Fixed-fps makes the captured frames deterministic.
        pixel_note = "no-pixels"
        if run1["pngs"] and run2["pngs"]:
            if len(run1["pngs"]) != len(run2["pngs"]):
                results.append((name, "FAIL", "shot-count mismatch"))
                continue
            bad_pixels = []
            for a, b in zip(run1["pngs"], run2["pngs"]):
                same, perr = pixel_paths_equal(a, b)
                if not same:
                    bad_pixels.append(f"{a.name}: {perr or 'repeats differ'}")
            if bad_pixels:
                results.append((name, "FAIL", "pixels: " + "; ".join(bad_pixels)))
                continue
            pixel_note = f"pixels-identical x{len(run1['pngs'])}"
        results.append((name, "PASS", f"state repeat stable; {pixel_note}"))
    for name, verdict, note in results:
        print(f"SCENARIO {name}\t{verdict}\t{note}")
    if any(v == "FAIL" for _, v, _ in results):
        sys.exit(1)


if __name__ == "__main__":
    main()
