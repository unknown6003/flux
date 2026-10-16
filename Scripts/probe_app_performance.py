#!/usr/bin/env python3
"""Measure the full app's idle/Settings CPU and memory with paired source builds.

Uses real AppDelegate, Settings window and services. A file-command driver and
native tab markers are added to temporary source copies. Both builds use the current bundled media
helper. Automatic updates and login registration are off in private probe domains.
CPU and RSS cover the main process. Camera, real media and hardware feature loads
are not simulated. Window timing waits for the real key window, the requested
tab's native view, completed layout and a display flush. It is not GPU presentation
time. Native icon/drag correctness has separate probes.
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

from probe_performance import ROOT, native_status_fixture, run, sample_process, stop_group

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
            if command["skipAction"] as? Bool != true { delegate.perfAction(action) }
            @MainActor func finishWhenReady() {
                var state = delegate.perfWindowState()
                let expectedTab = action == "settings" ? "menuBar" : action == "general" ? "general" : nil
                let ready: Bool
                if let expectedTab {
                    ready = state["settingsVisible"] as? Bool == true && state["settingsKey"] as? Bool == true
                        && state["renderedTabs"] as? [String] == [expectedTab]
                } else {
                    ready = action != "close" || state["settingsVisible"] as? Bool == false
                }
                if !ready && ProcessInfo.processInfo.systemUptime - start < 10 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { finishWhenReady() }
                    return
                }
                state["sequence"] = number
                state["action"] = action
                state["actionReady"] = ready
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
    func perfWindowState() -> [String: Any] {
        var state = settingsWindow.perfState()
        state["fixtureIcons"] = menuBarIcons.icons.filter { $0.id.hasPrefix("com.flux.performance-fixture|") }.count
        return state
    }
}
'''
WINDOW_ACCESS = r'''
extension SettingsWindowController {
    func perfClose() { window?.performClose(nil) }
    func perfState() -> [String: Any] {
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.displayIfNeeded()
        func renderedTabs(in view: NSView) -> [String] {
            var tabs: [String] = []
            if let marker = view as? PerfRenderedTabView,
               marker.window === window, marker.hasLaidOut,
               !marker.isHiddenOrHasHiddenAncestor,
               marker.bounds.width > 0, marker.bounds.height > 0,
               !marker.visibleRect.isEmpty {
                tabs.append(marker.tab)
            }
            return tabs + view.subviews.flatMap { renderedTabs(in: $0) }
        }
        return ["settingsVisible": window?.isVisible == true,
                "settingsKey": window?.isKeyWindow == true,
                "renderedTabs": window?.contentView.map { renderedTabs(in: $0).sorted() } ?? [],
                "hostingID": window?.contentViewController.map { String(describing: ObjectIdentifier($0)) } ?? "none"]
    }
}
'''

TAB_MARKER = r'''
@MainActor
struct PerfRenderedTabMarker: NSViewRepresentable {
    let tab: String
    func makeNSView(context: Context) -> PerfRenderedTabView {
        let view = PerfRenderedTabView(frame: .zero)
        view.tab = tab
        view.needsLayout = true
        return view
    }
    func updateNSView(_ view: PerfRenderedTabView, context: Context) {}
}

@MainActor
final class PerfRenderedTabView: NSView {
    var tab = ""
    private(set) var hasLaidOut = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hasLaidOut = false
        needsLayout = true
    }
    override func layout() {
        super.layout()
        hasLaidOut = true
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
'''


def instrument_tab(source, tab):
    anchor = "        .padding(20)"
    if anchor not in source:
        raise RuntimeError(f"{tab} tab marker anchor was not found")
    return source.replace(anchor, anchor + f'\n        .background(PerfRenderedTabMarker(tab: "{tab}"))', 1)


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
    for name, tab in (("GeneralTab.swift", "general"), ("MenuBarTab.swift", "menuBar")):
        path = next(path for path in files if path.name == name)
        path.write_text(instrument_tab(path.read_text(), tab) + (TAB_MARKER if tab == "general" else ""))
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
            def command(action, skip_action=False, require_ready=True):
                nonlocal sequence
                sequence += 1
                temporary = directory / "command.tmp"
                temporary.write_text(json.dumps({"sequence": sequence, "action": action, "skipAction": skip_action}))
                temporary.replace(directory / "command.json")
                state = wait_state(state_path, process, lambda state: state.get("sequence") == sequence)
                if require_ready and not state.get("actionReady"):
                    raise RuntimeError(f"{action} did not reach its rendered window state: {state}")
                return state
            result = {"desktop": ready, "idle": sample_process(process.pid, seconds)}
            result["settings_open"] = command("settings")
            if not result["settings_open"]["settingsVisible"] or not result["settings_open"]["settingsKey"]:
                raise RuntimeError("real Menu Bar Settings window did not open")
            if result["settings_open"]["fixtureIcons"] != 12:
                raise RuntimeError("Settings did not load all 12 real menu bar fixture icons")
            negative = command("general", skip_action=True, require_ready=False)
            if negative.get("actionReady") or negative.get("renderedTabs") != ["menuBar"] or negative["milliseconds"] < 10_000:
                raise RuntimeError("tab readiness gate accepted a skipped General navigation")
            result["skipped_general_control"] = negative
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
                                                  "rendered_tabs": [opened["renderedTabs"], general["renderedTabs"], returned["renderedTabs"]],
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
              "boundary": "main process CPU/RSS, real Settings and default services; tab timing through native view layout and display flush, not GPU presentation; controlled copies with file driver",
              "status": "running"}
    def save():
        (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    save()
    from probe_tcc import accessibility_grant
    try:
        with tempfile.TemporaryDirectory(prefix="flux-app-perf-") as temporary, ExitStack() as stack:
            scratch = Path(temporary)
            report["status_fixture"] = stack.enter_context(native_status_fixture(output / "fixture"))
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
