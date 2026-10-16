#!/usr/bin/env python3
"""Independent idle-resource probe for the persisted-history load path.

This is additive to, and does not overlap, ``probe_app_performance.py``: that
probe times the Settings window and samples CPU/RSS while Settings is open.
This one stays entirely at idle before any UI action and measures one concrete
startup cost — whether the app reads, decodes and rewrites the persisted
clipboard history while the clipboard feature is switched off (the factory
default).

It builds a baseline and a candidate app from the same controlled-copy harness
``probe_app_performance`` uses, seeds a known clipboard-history file with a
payload large enough to show up in RSS, launches each app with default settings
(clipboard off, persistence on), then records at idle:

  * resident set size and physical footprint (the launch reply's task_info),
  * whether the seeded history file was read back and rewritten (size, mtime,
    and a SHA-256 of its bytes) — baseline rewrites it via
    ``ClipboardMonitor.restorePersistedEntries`` -> ``persistHistory``; the
    candidate does not, because loading is deferred to first use.

The enabled-path guarantee ("first use still restores the stored content") is
deterministic and covered by ``--selftest``; this probe does not duplicate it.

Requires a disposable GitHub macOS desktop and a built app bundle, exactly like
``probe_app_performance.py``. It is a measurement script only: it changes
nothing in the app and prices no behavior beyond what it prints.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

from probe_performance import ROOT, read_process, run, sample_process, stop_group
from probe_app_performance import build, wait_state

# The path `ClipboardMonitor.defaultPersistenceURL()` resolves to — derived from
# Application Support, NOT from the bundle identifier, so both probe builds and
# a real install share it. The probe snapshots and restores any existing file.
HISTORY_PATH = Path.home() / "Library" / "Application Support" / "Flux" / "clipboard-history.json"
SEEDED_ENTRIES = 60
SEEDED_TEXT_CHARS = 4_000


def history_digest(path):
    if not path.exists():
        return {"present": False}
    data = path.read_bytes()
    stat = path.stat()
    return {"present": True, "size": len(data), "sha256": hashlib.sha256(data).hexdigest(),
            "mtime_ns": stat.st_mtime_ns}


def seed_history():
    """Writes a legal, within-budget persisted history and returns its digest."""
    now = time.time()
    entries = []
    for index in range(SEEDED_ENTRIES):
        text = f"entry-{index}-" + ("x" * SEEDED_TEXT_CHARS)
        stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - index * 60))
        entries.append({"capturedAt": stamp, "kind": "text", "text": text})
    HISTORY_PATH.parent.mkdir(parents=True, exist_ok=True)
    with HISTORY_PATH.open("w") as handle:
        json.dump({"version": 1, "entries": entries}, handle)
    return history_digest(HISTORY_PATH)


def launch(binary, directory, seconds):
    directory.mkdir()
    with (directory / "app.log").open("w") as log:
        process = subprocess.Popen([str(binary), str(directory)], stdout=log,
                                   stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                   start_new_session=True)
        try:
            state_path = directory / "state.json"
            ready = wait_state(state_path, process, lambda state: state.get("ready"))
            idle_cpu = sample_process(process.pid, seconds)
            idle_rss = read_process(process.pid)
            def command(action):
                temporary = directory / "command.tmp"
                temporary.write_text(json.dumps({"sequence": 1, "action": action}))
                temporary.replace(directory / "command.json")
                return wait_state(state_path, process, lambda state: state.get("sequence") == 1)
            command("quit")
            process.wait(timeout=5)
            if process.returncode:
                raise RuntimeError(f"app exit {process.returncode}")
            return {"ready": ready, "idle_cpu": idle_cpu, "idle_rss": idle_rss}
        finally:
            stop_group(process)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-ref",
                        default="3d7e24cce908f2b0e6fd4be1bd28f94b8be750e1",
                        help="commit before the candidate change (branch base)")
    parser.add_argument("--output", type=Path, default=ROOT / "build/performance/idle-resources")
    parser.add_argument("--seconds", type=int, choices=range(3, 31), default=8)
    args = parser.parse_args()
    if sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true":
        raise RuntimeError("requires a disposable GitHub macOS desktop")

    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    baseline = run(["git", "rev-parse", "--verify", "--end-of-options", args.baseline_ref + "^{commit}"], 10).strip()
    candidate = run(["git", "rev-parse", "HEAD"], 10).strip()

    report = {"baseline": baseline, "candidate": candidate, "seconds": args.seconds,
              "history_path": str(HISTORY_PATH), "seeded_entries": SEEDED_ENTRIES,
              "seeded_text_chars": SEEDED_TEXT_CHARS,
              "boundary": ("idle main-process CPU/RSS/footprint before any UI action; "
                           "whether the seeded clipboard history was read+rewritten at idle"),
              "status": "running"}

    def save():
        (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")

    save()
    backup = None
    try:
        if HISTORY_PATH.exists():
            backup = output / "clipboard-history.pre-existing.json"
            shutil.copy2(HISTORY_PATH, backup)
        with tempfile.TemporaryDirectory(prefix="flux-idle-resources-") as temporary:
            scratch = Path(temporary)
            binaries = {}
            for label, ref in (("baseline", baseline), ("candidate", candidate)):
                binaries[label], _ = build(ref, label, output, scratch)
            for label in ("baseline", "candidate"):
                # Re-seed immediately before each launch so a rewrite by the
                # previous build cannot be mistaken for this build's work.
                before = seed_history()
                result = launch(binaries[label], output / f"{label}-run", args.seconds)
                after = history_digest(HISTORY_PATH)
                result["history_before"] = before
                result["history_after"] = after
                result["history_rewritten_at_idle"] = (
                    before.get("sha256") != after.get("sha256") or before.get("mtime_ns") != after.get("mtime_ns"))
                report.setdefault("samples", {})[label] = result
                save()
        report["status"] = "measured"
    except BaseException as error:
        report["status"] = "fail"
        report["error"] = str(error)
        raise
    finally:
        if backup is not None:
            HISTORY_PATH.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(backup, HISTORY_PATH)
        else:
            HISTORY_PATH.unlink(missing_ok=True)
        save()
    print(f"Measured idle persisted-history resources: {output / 'results.json'}")


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(128 + signum))
    try:
        main()
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        raise SystemExit(f"FAIL: {error}") from error
