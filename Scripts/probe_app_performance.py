#!/usr/bin/env python3
"""Measure the full app's idle/Settings CPU and memory with paired source builds.

Uses real AppDelegate, Settings window and services. Only a file-command driver
is added to temporary source copies. Both builds use the current bundled media
helper. Automatic updates and login registration are off in private probe domains.
CPU and RSS cover the main process. Camera, real media and hardware feature loads
are not simulated. Window timing waits for the real key window and a display flush;
it is not GPU presentation time. Native icon/drag correctness has separate probes.
"""
import argparse
from contextlib import ExitStack
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

from probe_performance import ROOT, run, sample_process, stop_group

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
            let start = ProcessInfo.processInfo.systemUptime
            delegate.perfAction(action)
            @MainActor func finishWhenReady() {
                var state = delegate.perfWindowState()
                let ready = (action == "settings" || action == "general")
                    ? state["settingsVisible"] as? Bool == true && state["settingsKey"] as? Bool == true
                    : action != "close" || state["settingsVisible"] as? Bool == false
                if !ready && ProcessInfo.processInfo.systemUptime - start < 10 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { finishWhenReady() }
                    return
                }
                state["sequence"] = number
                state["action"] = action
                state["milliseconds"] = (ProcessInfo.processInfo.systemUptime - start) * 1_000
                state["pid"] = getpid()
                reply(state)
                if action == "quit" { app.terminate(nil) }
            }
            DispatchQueue.main.async { finishWhenReady() }
        }
    }
    commands.setCancelHandler { close(descriptor) }
    commands.resume()
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        reply(["ready": true, "pid": getpid(), "sequence": -1,
               "screens": NSScreen.screens.count,
               "notchedDisplay": NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }])
    }
    withExtendedLifetime(commands) { app.run() }
}
'''
APP_ACCESS = r'''
extension AppDelegate {
    func perfAction(_ action: String) {
        switch action {
        case "settings": settingsWindow.show(tab: .menuBar)
        case "general": settingsWindow.show(tab: .general)
        case "close": settingsWindow.perfClose()
        case "drawer": menuBar?.toggleReveal()
        default: break
        }
    }
    func perfWindowState() -> [String: Any] { settingsWindow.perfState() }
}
'''
WINDOW_ACCESS = r'''
extension SettingsWindowController {
    func perfClose() { window?.performClose(nil) }
    func perfState() -> [String: Any] {
        window?.displayIfNeeded()
        return ["settingsVisible": window?.isVisible == true,
                "settingsKey": window?.isKeyWindow == true,
                "hostingID": window?.contentViewController.map { String(describing: ObjectIdentifier($0)) } ?? "none"]
    }
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
    for name, addition in (("AppDelegate.swift", APP_ACCESS), ("SettingsWindowController.swift", WINDOW_ACCESS)):
        path = next(path for path in files if path.name == name)
        path.write_text(path.read_text() + addition)
    main = source / "Sources/Flux/main.swift"
    main.write_text(FIXTURE)
    app = source / "Flux.app"
    contents = app / "Contents"
    binary = contents / "MacOS/Flux"
    binary.parent.mkdir(parents=True)
    resources = ROOT / "build/Flux.app/Contents"
    for name in ("Resources", "Frameworks"):
        if (resources / name).exists():
            shutil.copytree(resources / name, contents / name)
    info = plistlib.loads((source / "Resources/Info.plist").read_bytes())
    bundle_id = "com.flux.app-performance." + label
    info["CFBundleIdentifier"] = bundle_id
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    log = run(["xcrun", "swiftc", "-O", "-swift-version", "5", *map(str, files), "-o", str(binary)], 240)
    log += run(["codesign", "--force", "--sign", "-", str(app)], 30)
    (output / (label + "-build.log")).write_text(log)
    return binary, bundle_id


def wait_state(path, process, check, seconds=20):
    deadline = time.monotonic() + seconds
    last = None
    while time.monotonic() < deadline:
        try:
            last = json.loads(path.read_text())
            if check(last):
                return last
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        if process.poll() is not None:
            raise RuntimeError(f"app exited {process.returncode}, last state {last}")
        time.sleep(0.03)
    raise RuntimeError(f"app state deadline, last state {last}")


def measure(binary, directory, seconds, cycles):
    directory.mkdir()
    with (directory / "app.log").open("w") as log:
        process = subprocess.Popen([str(binary), str(directory)], stdout=log, stderr=subprocess.STDOUT,
                                   stdin=subprocess.DEVNULL, start_new_session=True)
        try:
            state_path = directory / "state.json"
            ready = wait_state(state_path, process, lambda state: state.get("ready"))
            sequence = 0
            def command(action):
                nonlocal sequence
                sequence += 1
                temporary = directory / "command.tmp"
                temporary.write_text(json.dumps({"sequence": sequence, "action": action}))
                temporary.replace(directory / "command.json")
                return wait_state(state_path, process, lambda state: state.get("sequence") == sequence)
            result = {"desktop": ready, "idle": sample_process(process.pid, seconds)}
            result["settings_open"] = command("settings")
            if not result["settings_open"]["settingsVisible"] or not result["settings_open"]["settingsKey"]:
                raise RuntimeError("real Menu Bar Settings window did not open")
            result["settings"] = sample_process(process.pid, seconds)
            result["close"] = command("close")
            if result["close"]["settingsVisible"]:
                raise RuntimeError("Settings window did not close")
            result["settings_reopen"] = command("settings")
            if not result["settings_reopen"]["settingsVisible"]:
                raise RuntimeError("retained Menu Bar Settings window did not reopen")
            result["settings_reopened"] = sample_process(process.pid, seconds)
            command("close")
            result["settings_cycles"] = []
            for cycle in range(cycles):
                opened = command("settings")
                general = command("general")
                returned = command("settings")
                if directory.name.startswith("candidate") and len({opened["hostingID"], general["hostingID"], returned["hostingID"]}) != 1:
                    raise RuntimeError("a candidate tab request replaced the retained hosting controller")
                closed = command("close")
                if not opened["settingsVisible"] or closed["settingsVisible"]:
                    raise RuntimeError(f"Settings lifecycle failed at cycle {cycle + 1}")
                result["settings_cycles"].append({"cycle": cycle + 1, "open_ms": opened["milliseconds"],
                                                  "close_ms": closed["milliseconds"],
                                                  "general_ms": general["milliseconds"],
                                                  "return_menu_bar_ms": returned["milliseconds"],
                                                  "hosting_retained": len({opened["hostingID"], general["hostingID"], returned["hostingID"]}) == 1})
            result["after_cycles"] = sample_process(process.pid, seconds)
            result["drawer_calls"] = [command("drawer") for _ in range(100)]
            command("quit")
            process.wait(timeout=5)
            if process.returncode:
                raise RuntimeError(f"app exit {process.returncode}")
            return result
        finally:
            stop_group(process)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-ref", default="f286253")
    parser.add_argument("--output", type=Path, default=ROOT / "build/performance/app")
    parser.add_argument("--seconds", type=int, choices=range(3, 31), default=5)
    parser.add_argument("--cycles", type=int, choices=range(1, 101), default=50)
    parser.add_argument("--repeats", type=int, choices=range(1, 4), default=2)
    args = parser.parse_args()
    if sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true":
        raise RuntimeError("requires a disposable GitHub macOS desktop")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    baseline = run(["git", "rev-parse", "--verify", "--end-of-options", args.baseline_ref + "^{commit}"], 10).strip()
    candidate = run(["git", "rev-parse", "HEAD"], 10).strip()
    report = {"baseline": baseline, "candidate": candidate, "seconds_per_state": args.seconds, "settings_cycles_per_round": args.cycles,
              "samples": {"baseline": [], "candidate": []},
              "boundary": "main process CPU/RSS, real Settings and default services; controlled copies with file driver",
              "status": "running"}
    def save():
        (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    save()
    from probe_tcc import accessibility_grant
    try:
        with tempfile.TemporaryDirectory(prefix="flux-app-perf-") as temporary, ExitStack() as stack:
            scratch = Path(temporary)
            binaries = {}
            for label, ref in (("baseline", baseline), ("candidate", candidate)):
                binaries[label], bundle_id = build(ref, label, output, scratch)
                stack.enter_context(accessibility_grant(bundle_id))
            for iteration in range(args.repeats):
                for label in (("baseline", "candidate") if iteration % 2 == 0 else ("candidate", "baseline")):
                    report["samples"][label].append(measure(binaries[label], output / f"{label}-{iteration}", args.seconds, args.cycles))
                    save()
        report["status"] = "measured"
    except BaseException as error:
        report["status"] = "fail"
        report["error"] = str(error)
        raise
    finally:
        save()
    print(f"Measured paired full app workloads: {output / 'results.json'}")


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(128 + signum))
    try:
        main()
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        raise SystemExit(f"FAIL: {error}") from error
