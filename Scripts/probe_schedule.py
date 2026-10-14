#!/usr/bin/env python3
"""Check automatic update preference changes while the app tracks a menu."""

from pathlib import Path
import sys
import tempfile
from probe_update import run


if sys.platform != "darwin":
    raise SystemExit("FAIL: the update schedule probe requires macOS")

root = Path(__file__).resolve().parents[1]
source = r'''
import AppKit
import Combine

@MainActor
final class Preference: ObservableObject {
    @Published var enabled = false
}

@MainActor
func probe() {
    _ = NSApplication.shared
    CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(rawValue: RunLoop.Mode.eventTracking.rawValue as CFString))
    let preference = Preference()
    var checks = 0
    let scheduler = AutomaticUpdateScheduler(enabled: preference.$enabled.eraseToAnyPublisher(),
        initialDelay: .milliseconds(20), interval: 0.05) { checks += 1 }
    preference.enabled = true
    let deadline = Date().addingTimeInterval(2)
    while checks < 2 && Date() < deadline {
        RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.02))
    }
    guard checks >= 2 else {
        print("FAIL: enabling automatic updates did not keep checks running while tracking a menu, checks=\(checks)")
        exit(1)
    }
    print("PASS: enabling the published preference schedules background checks in menu-tracking mode")
    preference.enabled = false
    let stopped = checks
    let disabledDeadline = Date().addingTimeInterval(0.15)
    while Date() < disabledDeadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    guard checks == stopped else {
        print("FAIL: disabling automatic updates did not cancel pending checks")
        exit(1)
    }
    print("PASS: disabling the published preference cancels launch and periodic checks")
    withExtendedLifetime(scheduler) {}
}
MainActor.assumeIsolated { probe() }
'''

with tempfile.TemporaryDirectory(prefix="flux-schedule-probe-") as directory:
    temporary = Path(directory)
    main = temporary / "main.swift"
    main.write_text(source)
    binary = temporary / "FluxScheduleProbe"
    run(["swiftc", "-swift-version", "5", str(main),
         str(root / "Sources/Flux/App/AutomaticUpdateScheduler.swift"), "-o", str(binary)], 120)
    result = run([str(binary)], 5)
    print(result.stdout, end="", flush=True)
