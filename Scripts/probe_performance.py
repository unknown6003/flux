#!/usr/bin/env python3
"""Compare real Swift paths with a fixed commit on a macOS desktop.

The default workload measures unchanged denied-access refresh publications,
calendar refresh publications, and a controlled failed-clock lookup burst.
The clock fault is inserted into temporary source copies at the AX boundary.
It measures cache behavior with an injected 2 ms read, not native AX latency.
Optional native scans read the live desktop. They never move or hide icons.

--prepare-only records source hashes on any host before code changes.
--pid samples an existing app's CPU time and RSS. It does not launch or stop it.
--suite runs existing behavioral probes and records whole-command time,
including compilation. Those times are not UI latency measurements.
"""

import argparse
from contextlib import contextmanager, nullcontext
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import signal
import statistics
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
SOURCES = (
    "MenuBar/MenuBarIconManager.swift", "MenuBar/MacOS27Hider.swift",
    "MenuBar/ControlItem.swift", "MenuBar/MenuBarSection.swift",
    "MenuBar/MenuBarIconStyle.swift", "MenuBar/MenuBarGeometry.swift",
    "Support/Theme.swift", "Support/Log.swift", "Support/AccessibilityAccess.swift",
    "Services/CalendarService.swift",
)


def stop_group(process):
    output = ""
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            pass
        try:
            output, _ = process.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            continue
    return output


def run(command, seconds, cwd=ROOT):
    process = subprocess.Popen(command, cwd=cwd, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, start_new_session=True)
    try:
        output, _ = process.communicate(timeout=seconds)
    except BaseException as error:
        output = stop_group(process)
        if isinstance(error, subprocess.TimeoutExpired):
            raise RuntimeError(f"deadline after {seconds}s: {command[0]}\n{output}") from error
        raise
    stop_group(process)
    if process.returncode:
        raise RuntimeError(f"exit {process.returncode}: {command[0]}\n{output}")
    return output


@contextmanager
def native_status_fixture(directory, count=12):
    directory.mkdir(parents=True, exist_ok=True)
    source = directory / "main.swift"
    source.write_text(r'''
import AppKit
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let items = (0..<Int(CommandLine.arguments[2])!).map { index -> NSStatusItem in
        let item = NSStatusBar.system.statusItem(withLength: 24)
        item.button?.title = "F\(index)"
        item.button?.setAccessibilityTitle("Performance item \(index)")
        return item
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        let value = ["pid": Int(getpid()), "icons": items.count]
        try! JSONSerialization.data(withJSONObject: value).write(
            to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
    }
    withExtendedLifetime(items) { app.run() }
}
''')
    app = directory / "FluxPerformanceIcons.app"
    binary = app / "Contents/MacOS/FluxPerformanceIcons"
    binary.parent.mkdir(parents=True, exist_ok=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "com.flux.performance-fixture", "CFBundleExecutable": binary.name,
        "CFBundlePackageType": "APPL", "CFBundleName": "Flux performance icons", "LSUIElement": True,
    }))
    (directory / "build.log").write_text(run(["xcrun", "swiftc", str(source), "-o", str(binary)], 60) +
                                        run(["codesign", "--force", "--sign", "-", str(app)], 20))
    ready = directory / "ready.json"
    ready.unlink(missing_ok=True)
    with (directory / "fixture.log").open("w") as log:
        process = subprocess.Popen([str(binary), str(ready), str(count)], stdin=subprocess.DEVNULL,
                                   stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            deadline = time.monotonic() + 10
            while not ready.exists() and time.monotonic() < deadline and process.poll() is None:
                time.sleep(0.03)
            if not ready.exists():
                raise RuntimeError("native status fixture did not become ready")
            yield json.loads(ready.read_text())
        finally:
            stop_group(process)


def read_sources(ref=None):
    return {name: (run(["git", "show", f"{ref}:Sources/Flux/{name}"], 10)
                   if ref else (ROOT / "Sources/Flux" / name).read_text())
            for name in SOURCES}


def hashes(sources):
    return {name: hashlib.sha256(source.encode()).hexdigest()
            for name, source in sources.items()}


MANAGER_ACCESS = r'''
extension MenuBarIconManager {
    func perfSeedInventory() {
        icons = [Icon(id: "perf|0", title: "Fixture", source: nil,
                      section: .shown, isMovable: false,
                      frame: CGRect(x: 1, y: 1, width: 20, height: 20))]
        isTrusted = true
        errorMessage = nil
    }
}
'''

HIDER_ACCESS = r'''
@MainActor private enum PerfClockFault {
    static var enabled = false
}
extension MacOS27Hider {
    func perfResetClock() {
        lastAccessGranted = true
        clockFrameCache = nil
        PerfClockFault.enabled = true
    }
    func perfReadClock() -> CGRect? { clockFrame() }
    func perfSeedClock(_ frame: CGRect) { clockFrameCache = (frame, Date()) }
    func perfExpireClock() {
        if let cached = clockFrameCache {
            clockFrameCache = (cached.frame, .distantPast)
        }
    }
}
'''

FIXTURE = r'''
import AppKit
import Combine
import EventKit

AccessibilityAccess.exitIfRequested()
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    func require(_ condition: Bool, _ message: String) {
        if !condition { print("FAIL: \(message)"); exit(1) }
    }
    func timeMS(_ body: () -> Void) -> Double {
        let start = ProcessInfo.processInfo.systemUptime
        body()
        return (ProcessInfo.processInfo.systemUptime - start) * 1_000
    }
    let count = 100
    var result: [String: Any] = [:]
    var tokens = Set<AnyCancellable>()
    let manager = MenuBarIconManager(trustProvider: { false })
    manager.perfSeedInventory()
    manager.refresh()
    require(!manager.isTrusted && manager.icons.isEmpty && manager.errorMessage != nil,
            "a denied refresh must clear stale trusted inventory and explain access")
    var icons = 0, trust = 0, errors = 0, busy = 0
    manager.$icons.dropFirst().sink { _ in icons += 1 }.store(in: &tokens)
    manager.$isTrusted.dropFirst().sink { _ in trust += 1 }.store(in: &tokens)
    manager.$errorMessage.dropFirst().sink { _ in errors += 1 }.store(in: &tokens)
    manager.$isUpdatingIcons.dropFirst().sink { _ in busy += 1 }.store(in: &tokens)
    var samples: [Double] = []
    for _ in 0..<count { samples.append(timeMS { manager.refresh() }) }
    require(!manager.isTrusted && manager.icons.isEmpty && !manager.isUpdatingIcons,
            "steady refresh changed inventory or left an update open")
    result["denied_refresh"] = ["calls": count, "milliseconds": samples,
        "icons_publications": icons, "trust_publications": trust,
        "error_publications": errors, "busy_publications": busy]
    manager.perfSeedInventory()
    manager.refresh()
    require(!manager.isTrusted && manager.icons.isEmpty && manager.errorMessage != nil,
            "a later denial must still clear changed inventory")

    let calendar = CalendarService()
    if EKEventStore.authorizationStatus(for: .event) != .fullAccess {
        calendar.injectPreviewEvents([CalendarEvent(id: "perf", title: "Fixture",
            start: Date(), end: Date(), isAllDay: false, calendarColor: nil, location: nil)])
        calendar.refreshNow()
        require(calendar.upcoming.isEmpty, "denied calendar refresh retained an event")
        var publications = 0
        calendar.$upcoming.dropFirst().sink { _ in publications += 1 }.store(in: &tokens)
        samples = []
        for _ in 0..<count { samples.append(timeMS { calendar.refreshNow() }) }
        require(calendar.upcoming.isEmpty, "denied calendar refresh created an event")
        result["denied_calendar_refresh"] = ["calls": count,
            "milliseconds": samples, "publications": publications]
    } else {
        result["denied_calendar_refresh"] = ["status": "unavailable",
            "reason": "this probe already has full Calendar access"]
    }

    let suite = "com.flux.performance." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let hider = MacOS27Hider(defaults: defaults, trustProvider: { true },
                            positionReader: { ([], []) })
    let knownClock = CGRect(x: 10, y: 10, width: 50, height: 20)
    hider.perfSeedClock(knownClock)
    require(hider.perfReadClock() == knownClock, "successful clock cache changed")
    hider.perfResetClock()
    var reads = 0, endedReads = 0
    hider.onReadState = { if $0 { reads += 1 } else { endedReads += 1 } }
    samples = []
    for _ in 0..<30 {
        samples.append(timeMS { require(hider.perfReadClock() == nil, "clock fault was not applied") })
    }
    let burstReads = reads
    hider.perfExpireClock()
    require(hider.perfReadClock() == nil && reads == burstReads + 1,
            "an expired clock cache must retry the read")
    require(reads == endedReads, "clock lookup left its busy state open")
    result["clock_miss_burst"] = ["calls": 30, "milliseconds": samples,
        "read_attempts": burstReads, "retry_after_expiry": true,
        "injected_read_ms": 2, "boundary": "controlled fault before native AX lookup"]

    if CommandLine.arguments.contains("--native-scan") {
        if AXIsProcessTrusted() && !NSScreen.screens.isEmpty {
            let native = MenuBarIconManager(trustProvider: { AXIsProcessTrusted() })
            native.refresh()
            var publications = 0
            native.$icons.dropFirst().sink { _ in publications += 1 }.store(in: &tokens)
            samples = []
            for _ in 0..<10 { samples.append(timeMS { native.refresh() }) }
            let fixtureIcons = native.icons.filter { $0.id.hasPrefix("com.flux.performance-fixture|") }.count
            require(fixtureIcons == 12, "native inventory did not read all 12 real fixture icons")
            result["native_inventory_scan"] = ["calls": 10, "milliseconds": samples, "fixture_icons": fixtureIcons,
                "icons": native.icons.count, "icons_publications": publications,
                "boundary": "synchronous AX inventory refresh; no input events"]
        } else {
            result["native_inventory_scan"] = ["status": "unavailable",
                "reason": "native scan requires existing Accessibility access and a desktop"]
        }
    }
    let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    print("PERF_JSON " + String(data: data, encoding: .utf8)!)
    withExtendedLifetime((manager, calendar, hider, tokens)) {}
}
'''


def build_fixture(sources, directory):
    directory.mkdir()
    paths = []
    for name, source in sources.items():
        path = directory / Path(name).name
        if path.name == "MenuBarIconManager.swift":
            source += MANAGER_ACCESS
        if path.name == "MacOS27Hider.swift":
            prefix, marker, clock = source.partition("    private func clockFrame() -> CGRect? {")
            if not marker:
                raise RuntimeError("clockFrame instrumentation point was not found")
            needle = "        guard let agent = NSRunningApplication.runningApplications("
            if clock.count(needle) != 1:
                raise RuntimeError("clock AX instrumentation point was not unique")
            clock = clock.replace(needle, """        if PerfClockFault.enabled {
            Thread.sleep(forTimeInterval: 0.002)
            return nil
        }
""" + needle, 1)
            source = prefix + marker + clock + HIDER_ACCESS
        path.write_text(source)
        paths.append(path)
    main = directory / "main.swift"
    main.write_text(FIXTURE)
    bundle = directory / "FluxPerformanceProbe.app"
    binary = bundle / "Contents/MacOS/FluxPerformanceProbe"
    binary.parent.mkdir(parents=True)
    (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "com.flux.performance-probe", "CFBundleExecutable": binary.name,
        "CFBundlePackageType": "APPL", "LSUIElement": True,
    }))
    log = run(["xcrun", "swiftc", "-O", "-swift-version", "5", str(main),
               *map(str, paths), "-o", str(binary)], 180)
    log += run(["codesign", "--force", "--sign", "-", str(bundle)], 20)
    return binary, log


def cpu_seconds(value):
    days, _, clock = value.rpartition("-")
    fields = [float(field) for field in (clock or value).split(":")]
    if len(fields) not in (2, 3):
        raise ValueError(f"unexpected ps CPU time: {value}")
    total = 0.0
    for field in fields:
        total = total * 60 + field
    return total + (int(days) * 86_400 if days else 0)


def sample_process(pid, seconds):
    executable = run(["/bin/ps", "-p", str(pid), "-o", "comm="], 5).strip()
    def read():
        fields = run(["/bin/ps", "-p", str(pid), "-o", "time=,rss=,lstart="], 5).split()
        if len(fields) != 7:
            raise RuntimeError(f"PID {pid} exited or ps returned unexpected fields")
        return {"cpu_seconds": cpu_seconds(fields[0]), "rss_kib": int(fields[1]),
                "started": " ".join(fields[2:]), "at": time.monotonic()}

    samples = [read()]
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        time.sleep(min(0.5, max(0, deadline - time.monotonic())))
        sample = read()
        if sample["started"] != samples[0]["started"]:
            raise RuntimeError("sampled PID was reused")
        samples.append(sample)
    elapsed = samples[-1]["at"] - samples[0]["at"]
    cpu = samples[-1]["cpu_seconds"] - samples[0]["cpu_seconds"]
    result = {"pid": pid, "executable": executable, "elapsed_seconds": elapsed, "cpu_seconds": cpu,
              "cpu_percent_one_core": cpu / elapsed * 100,
              "rss_kib_median": statistics.median(s["rss_kib"] for s in samples),
              "rss_kib_max": max(s["rss_kib"] for s in samples), "samples": samples,
              "boundary": "target PID only; excludes helper processes and GPU",
              "wakeups": {"status": "unavailable"}}
    if sys.platform == "darwin":
        try:
            result["wakeups"] = {"status": "raw top idlew samples",
                "raw": run(["/usr/bin/top", "-l", "2", "-s", "1", "-pid", str(pid),
                            "-stats", "pid,idlew"], 8),
                "boundary": "separate 1s top sample; idle wakeups, not all timer fires"}
        except RuntimeError as error:
            result["wakeups"]["reason"] = str(error)
    return result


def summarize(measurements):
    result = {}
    for label, rounds in measurements.items():
        result[label] = {}
        for case in rounds[0] if rounds else ():
            rows = [sample[case] for sample in rounds]
            if any("milliseconds" not in row for row in rows):
                result[label][case] = rows
                continue
            timings = sorted(value for row in rows for value in row["milliseconds"])
            result[label][case] = {
                "samples": len(timings), "median_ms": statistics.median(timings),
                "p95_ms": timings[math.ceil(len(timings) * 0.95) - 1],
                "max_ms": timings[-1],
                "total_ms_per_round": [sum(row["milliseconds"]) for row in rows],
                "counts_per_round": [{key: value for key, value in row.items()
                                      if key.endswith("publications") or key == "read_attempts"}
                                     for row in rows],
            }
    return result


def suite(output):
    from probe_tcc import accessibility_grant

    cases = [
        ("settings-reopen", "probe_settings_reopen.py", [], 150),
        ("drawer-response", "probe_drawer_response.py", [], 210),
        ("layout", "probe_layout_scan.py", [], 150),
        ("native-drag", "probe_menu_drag.py", ["--output", str(output / "drag")], 240),
        ("live-activity", "probe_live_activity.py", [], 160),
    ]
    results = []
    for name, script, arguments, deadline in cases:
        start = time.monotonic()
        try:
            grant = accessibility_grant("com.flux.menu-drag-probe") if name == "native-drag" else nullcontext()
            with grant:
                log = run([sys.executable, str(ROOT / "Scripts" / script), *arguments], deadline)
            status = "unavailable" if "SKIP:" in log else "pass"
        except RuntimeError as error:
            log = str(error)
            status = "unavailable" if "SETUP FAIL:" in log else "fail"
        (output / f"{name}.log").write_text(log)
        results.append({"case": name, "status": status,
                        "command_seconds": time.monotonic() - start,
                        "boundary": "behavioral probe including build; not UI latency"})
    return results


def validate(candidate):
    failures = []
    for sample in candidate:
        denied = sample["denied_refresh"]
        if any(denied[key] for key in ("icons_publications", "trust_publications", "error_publications")):
            failures.append("unchanged denied-access refresh still publishes inventory state")
        if denied["busy_publications"] != 2 * denied["calls"]:
            failures.append("refresh changed busy-state behavior")
        calendar = sample["denied_calendar_refresh"]
        if calendar.get("publications", 0):
            failures.append("unchanged denied calendar refresh still publishes events")
        if sample["clock_miss_burst"]["read_attempts"] != 1:
            failures.append("failed clock reads were not cached during a burst")
    return sorted(set(failures))


def write_report(output, report):
    (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--baseline-ref", default="f286253")
    parser.add_argument("--output", type=Path, default=ROOT / "build/performance")
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--repeats", type=int, choices=range(1, 10), default=3)
    parser.add_argument("--native-scan", action="store_true")
    parser.add_argument("--suite", action="store_true")
    parser.add_argument("--pid", type=int)
    parser.add_argument("--sample-only", action="store_true",
                        help="only sample --pid; do not compile or run fixtures")
    parser.add_argument("--seconds", type=int, choices=range(1, 61), default=10)
    parser.add_argument("--sample-label", default="idle")
    args = parser.parse_args()
    if args.pid is not None and args.pid <= 0:
        parser.error("--pid must be positive")
    if args.sample_only and not args.pid:
        parser.error("--sample-only requires --pid")
    if args.suite and os.environ.get("GITHUB_ACTIONS") != "true":
        parser.error("--suite needs a disposable GitHub macOS desktop for native input probes")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    baseline_ref = run(["git", "rev-parse", "--verify", "--end-of-options",
                        args.baseline_ref + "^{commit}"], 10).strip()
    baseline, candidate = read_sources(baseline_ref), read_sources()
    report = {"baseline_ref": baseline_ref,
              "candidate_head": run(["git", "rev-parse", "HEAD"], 10).strip(),
              "source_sha256": {"baseline": hashes(baseline), "candidate": hashes(candidate)},
              "platform": platform.platform(), "machine": platform.machine(),
              "recorded_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
              "python": sys.version, "status": "sources recorded; runtime not measured",
              "proof_boundary": "source hashes identify inputs; they are not runtime metrics"}
    write_report(output, report)
    if args.prepare_only:
        print(f"Recorded exact baseline and candidate inputs in {output / 'results.json'}")
        return 0
    if args.pid:
        report["process_sample"] = {"label": args.sample_label, **sample_process(args.pid, args.seconds)}
        if args.sample_only:
            report["status"] = "target process sampled; native fixtures not run"
        write_report(output, report)
        if args.sample_only:
            print(f"{report['status']}: {output / 'results.json'}")
            return 0
    if sys.platform != "darwin":
        report["status"] = "blocked: native Swift/AppKit measurements require macOS"
        write_report(output, report)
        print(report["status"], file=sys.stderr)
        return 2
    report["swift"] = run(["xcrun", "swiftc", "--version"], 10).strip()
    report["measurements"] = {"baseline": [], "candidate": []}
    try:
        with tempfile.TemporaryDirectory(prefix="flux-performance-") as scratch:
            binaries = {}
            for label, sources in (("baseline", baseline), ("candidate", candidate)):
                binary, log = build_fixture(sources, Path(scratch) / label)
                binaries[label] = binary
                (output / f"{label}-build.log").write_text(log)
            grant = nullcontext()
            if args.native_scan and os.environ.get("GITHUB_ACTIONS") == "true":
                from probe_tcc import accessibility_grant
                grant = accessibility_grant("com.flux.performance-probe")
            with grant, (native_status_fixture(output / "fixture") if args.native_scan else nullcontext()) as fixture:
                report["status_fixture"] = fixture
                for iteration in range(args.repeats):
                    order = ("baseline", "candidate") if iteration % 2 == 0 else ("candidate", "baseline")
                    for label in order:
                        log = run([str(binaries[label])] + (["--native-scan"] if args.native_scan else []), 45)
                        (output / f"{label}-{iteration}.log").write_text(log)
                        rows = [line[10:] for line in log.splitlines() if line.startswith("PERF_JSON ")]
                        if len(rows) != 1:
                            raise RuntimeError(f"{label} did not emit exactly one measurement record")
                        report["measurements"][label].append(json.loads(rows[0]))
                        write_report(output, report)
        report["summary"] = summarize(report["measurements"])
        report["failures"] = validate(report["measurements"]["candidate"])
        if args.suite:
            report["suite"] = suite(output)
            report["failures"] += [case["case"] for case in report["suite"] if case["status"] == "fail"]
        report["status"] = "fail" if report["failures"] else "pass within recorded proof boundaries"
    except (OSError, RuntimeError) as error:
        report["status"] = "fail"
        report["error"] = str(error)
        raise
    finally:
        write_report(output, report)
    print(f"{report['status']}: {output / 'results.json'}")
    return int(bool(report["failures"]))


if __name__ == "__main__":
    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, interrupted)
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        raise SystemExit(f"FAIL: {error}") from error
