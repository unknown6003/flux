#!/usr/bin/env python3
"""Independent idle-resource probe for feature-off startup work.

This is additive to ``probe_app_performance.py`` and targets a different
question. That probe DOES sample idle CPU/RSS before it opens Settings
(``probe_app_performance.py``: ``result["idle"] = sample_process(...)`` ahead of
``command("settings")``) and its launch reply already carries physical
footprint; it is the CPU/RSS authority. This probe instead stays at idle and
observes one concrete startup cost: whether an app launched with the clipboard
feature switched off reads and rewrites its persisted clipboard history.

Both copies are launched with the SAME explicit configuration — clipboard
disabled, persistence enabled — written into the app's own defaults domain by
the fixture before ``AppDelegate()`` is built, so the measurement does not
depend on factory defaults (which the settings owner is changing for fresh
profiles).

For each copy it records, at idle:
  * resident set size and CPU (auxiliary; no pass/fail bound on either),
  * the seeded history file's size, mtime and SHA-256 before and after launch,
  * the physical footprint from the launch reply.

Pass/fail is on observed file state, not on memory: the baseline must show an
observed read+rewrite (bytes/mtime changed, and the seeded entries round-trip),
and the candidate must show no rewrite (bytes, size and mtime identical). RSS is
recorded only as auxiliary data and is never asserted against.

Requires a disposable GitHub macOS desktop and a built app bundle, exactly like
``probe_app_performance.py``. Measurement only; it changes nothing in the app.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time

from probe_performance import ROOT, read_process, run, sample_process, stop_group

HISTORY_PATH = Path.home() / "Library" / "Application Support" / "Flux" / "clipboard-history.json"
SEEDED_ENTRIES = 40
SEEDED_TEXT_CHARS = 4_000

# Mirrors probe_app_performance's fixture, minus its Settings-timing surface,
# and adds the explicit clipboard configuration this probe depends on.
FIXTURE = r'''
import AppKit
import Darwin

AccessibilityAccess.exitIfRequested()
MainActor.assumeIsolated {
    let directory = URL(fileURLWithPath: CommandLine.arguments[1])
    UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
    UserDefaults.standard.set(false, forKey: "flux.automaticUpdateChecks")
    UserDefaults.standard.set(false, forKey: "flux.launchAtLogin")
    UserDefaults.standard.set(false, forKey: "flux.autoRehide")
    // Explicit feature-off config, identical for both copies.
    UserDefaults.standard.set(false, forKey: "flux.notch.clipboard.enabled")
    UserDefaults.standard.set(true, forKey: "flux.notch.clipboard.persistence.enabled")
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    var sequence = -1
    func reply(_ values: [String: Any]) {
        try! JSONSerialization.data(withJSONObject: values).write(
            to: directory.appendingPathComponent("state.json"), options: .atomic)
    }
    let descriptor = open(directory.path, O_EVTONLY)
    guard descriptor >= 0 else { exit(5) }
    let commands = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
    commands.setEventHandler {
        MainActor.assumeIsolated {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("command.json")),
                  let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let number = command["sequence"] as? Int, number > sequence,
                  let action = command["action"] as? String else { return }
            sequence = number
            reply(["ready": true, "sequence": number, "action": action])
            if action == "quit" { app.terminate(nil) }
        }
    }
    commands.setCancelHandler { close(descriptor) }
    commands.resume()
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let memory = status == KERN_SUCCESS
            ? ["physical_footprint_bytes": info.phys_footprint, "resident_bytes": info.resident_size] as [String: Any]
            : ["memory_read_error": status] as [String: Any]
        reply(["ready": true, "pid": getpid(), "sequence": -1, "memory": memory])
    }
    withExtendedLifetime(commands) { app.run() }
}
'''


def build(ref, label, output, scratch):
    source = scratch / label
    source.mkdir()
    archive = source / "source.tar"
    run(["git", "archive", "--format=tar", "--output", str(archive), ref,
         "Sources/Flux", "Resources/Info.plist"], 20)
    run(["tar", "-xf", str(archive), "-C", str(source)], 20)
    files = list((source / "Sources/Flux").rglob("*.swift"))
    (source / "Sources/Flux/main.swift").write_text(FIXTURE)
    app = source / "Flux.app"
    contents = app / "Contents"
    binary = contents / "MacOS/Flux"
    binary.parent.mkdir(parents=True)
    resources = ROOT / "build/Flux.app/Contents"
    for name in ("Resources", "Frameworks"):
        if (resources / name).exists():
            shutil.copytree(resources / name, contents / name)
    info = plistlib.loads((source / "Resources/Info.plist").read_bytes())
    info["CFBundleIdentifier"] = "com.flux.idle-resources." + label
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    log = run(["xcrun", "swiftc", "-O", "-swift-version", "5", *map(str, files), "-o", str(binary)], 240)
    log += run(["codesign", "--force", "--sign", "-", str(app)], 30)
    (output / (label + "-build.log")).write_text(log)
    return binary


def digest(path):
    if not path.exists():
        return {"present": False}
    data = path.read_bytes()
    stat = path.stat()
    return {"present": True, "size": len(data), "sha256": hashlib.sha256(data).hexdigest(),
            "mtime_ns": stat.st_mtime_ns, "texts": [entry["text"] for entry in json.loads(data)["entries"]]}


def seed_history():
    now = time.time()
    entries = [{"capturedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - index * 60)),
                "kind": "text",
                "text": f"entry-{index}-" + ("x" * SEEDED_TEXT_CHARS)}
               for index in range(SEEDED_ENTRIES)]
    HISTORY_PATH.parent.mkdir(parents=True, exist_ok=True)
    with HISTORY_PATH.open("w") as handle:
        json.dump({"version": 1, "entries": entries}, handle)
    # Validate the seed is legal for ClipboardMonitor.restorePersistedEntries.
    seeded = json.loads(HISTORY_PATH.read_text())
    assert seeded["version"] == 1 and len(seeded["entries"]) == SEEDED_ENTRIES
    return digest(HISTORY_PATH)


def wait_ready(state_path, process, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"app exited with {process.returncode} before ready")
        try:
            state = json.loads(state_path.read_text())
        except (OSError, ValueError):
            state = None
        if state and state.get("ready"):
            return state
        time.sleep(0.2)
    raise RuntimeError("app never reported ready")


def launch(binary, directory, seconds):
    directory.mkdir()
    with (directory / "app.log").open("w") as log:
        process = subprocess.Popen([str(binary), str(directory)], stdout=log,
                                   stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                   start_new_session=True)
        try:
            state_path = directory / "state.json"
            ready = wait_ready(state_path, process)
            idle_cpu = sample_process(process.pid, seconds)
            idle_rss = read_process(process.pid)
            temporary = directory / "command.tmp"
            temporary.write_text(json.dumps({"sequence": 1, "action": "quit"}))
            temporary.replace(directory / "command.json")
            process.wait(timeout=10)
            if process.returncode:
                raise RuntimeError(f"app exit {process.returncode}")
            return {"ready": ready, "idle_cpu": idle_cpu, "idle_rss": idle_rss}
        finally:
            stop_group(process)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-ref", required=True,
                        help="commit before the candidate change (the branch base)")
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
              "clipboard_config": {"flux.notch.clipboard.enabled": False,
                                   "flux.notch.clipboard.persistence.enabled": True},
              "boundary": ("idle main-process CPU/RSS before any UI action; whether the seeded "
                           "clipboard history was read+rewritten at idle while the feature is off"),
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
            binaries = {label: build(ref, label, output, scratch)
                        for label, ref in (("baseline", baseline), ("candidate", candidate))}
            for label in ("baseline", "candidate"):
                before = seed_history()  # re-seed per copy so a rewrite is attributable
                result = launch(binaries[label], output / f"{label}-run", args.seconds)
                after = digest(HISTORY_PATH)
                result["history_before"] = {k: v for k, v in before.items() if k != "texts"}
                result["history_after"] = {k: v for k, v in after.items() if k != "texts"}
                result["history_rewritten_at_idle"] = (
                    before["mtime_ns"] != after["mtime_ns"] or before["sha256"] != after["sha256"])
                result["history_content_preserved"] = (
                    after.get("present") and sorted(after["texts"]) == sorted(before["texts"]))
                report.setdefault("samples", {})[label] = result
                save()

        base = report["samples"]["baseline"]
        cand = report["samples"]["candidate"]
        checks = {
            "baseline_observed_read_and_rewrite": bool(base["history_rewritten_at_idle"]),
            "baseline_preserved_seeded_content": bool(base["history_content_preserved"]),
            "candidate_observed_no_rewrite": not cand["history_rewritten_at_idle"],
            "candidate_left_seeded_content_intact": bool(cand["history_content_preserved"]),
        }
        report["checks"] = checks
        report["status"] = "pass" if all(checks.values()) else "fail"
        if report["status"] == "fail":
            raise RuntimeError(f"idle-resource checks failed: {checks}")
    except BaseException as error:
        report.setdefault("status", "fail")
        report["error"] = str(error)
        save()
        raise
    finally:
        if backup is not None:
            HISTORY_PATH.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(backup, HISTORY_PATH)
        else:
            HISTORY_PATH.unlink(missing_ok=True)
        save()
    print(f"Measured idle feature-off resources: {output / 'results.json'}")


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(128 + signum))
    try:
        main()
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        raise SystemExit(f"FAIL: {error}") from error
