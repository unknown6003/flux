#!/usr/bin/env python3
"""Measure the real drawer path with a slow access provider and saved layout."""

import argparse
from pathlib import Path
import subprocess
import sys
import tempfile

from probe_hidden_transition import run


FIXTURE = r'''
import AppKit

AccessibilityAccess.exitIfRequested()
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    guard ControlItem.usesMacOS27Model else {
        print("SKIP: the saved-layout drawer path requires macOS 27")
        return
    }
    let suite = "com.flux.drawer-response." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["hidden": [String](), "alwaysHidden": [String]()],
                 forKey: "flux.macOS27IconLayout")
    var accessReads = 0
    var positionReads = 0
    let access = {
        accessReads += 1
        Thread.sleep(forTimeInterval: 0.15)
        return false
    }
    let hider = MacOS27Hider(defaults: defaults, trustProvider: access, positionReader: {
        positionReads += 1
        return ([], [])
    })
    let icons = MenuBarIconManager(trustProvider: access, hider: hider)
    let settings = SettingsStore(defaults: defaults)
    settings.autoRehide = false
    let manager = MenuBarManager(settings: settings, arranger: MenuBarArranger(),
                                 accessibilityTrusted: access, onOpenSettings: {})
    manager.canHideWithoutAccess = { icons.canHideWithoutAccess }
    manager.onDrawerStateChanged = { hidden, always in
        icons.applyDrawerVisibility(revealHidden: hidden, revealAlwaysHidden: always)
    }
    var samples: [Double] = []
    let before = accessReads
    for index in 0..<10 {
        guard !CGEventSource.buttonState(.combinedSessionState, button: .left) else {
            print("FAIL: physical mouse input interrupted the drawer timing probe")
            exit(1)
        }
        let start = ProcessInfo.processInfo.systemUptime
        manager.toggleReveal()
        samples.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
        let expected = index.isMultiple(of: 2)
        guard manager.diagnostics.revealHidden == expected else {
            print("FAIL: toggle \(index) did not apply immediately")
            exit(1)
        }
    }
    let reads = accessReads - before
    let maximum = samples.max()!
    print("DRAWER_MS \(samples.map { String(format: "%.3f", $0) }.joined(separator: ","))")
    print("ACCESS_READS \(reads) POSITION_READS \(positionReads)")
    guard reads == 0, positionReads == 0, maximum < 50 else {
        print("FAIL: saved-layout toggles blocked on access or layout work; max=\(maximum)ms")
        exit(1)
    }
    print("PASS: ten saved-layout toggles each returned within 50ms without access checks or scans")
    withExtendedLifetime((manager, icons, hider)) {}
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-ref")
    options = parser.parse_args()
    if sys.platform != "darwin":
        raise RuntimeError("the drawer response probe requires native macOS AppKit")
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="flux-drawer-response-") as directory:
        temporary = Path(directory)
        main = temporary / "main.swift"
        main.write_text(FIXTURE)
        paths = sorted((root / "Sources/Flux").rglob("*.swift"))
        paths = [path for path in paths if path.name != "main.swift"]
        if options.baseline_ref:
            for index, path in enumerate(paths):
                if path.name not in ("MenuBarManager.swift", "MacOS27Hider.swift", "ControlItem.swift"):
                    continue
                old = temporary / path.name
                old.write_text(subprocess.check_output(
                    ["git", "show", options.baseline_ref + ":" + str(path.relative_to(root))],
                    cwd=root, text=True, timeout=15))
                paths[index] = old
        binary = temporary / "FluxDrawerResponseProbe"
        run(["xcrun", "swiftc", "-swift-version", "5", str(main),
             *map(str, paths), "-o", str(binary)], 180)
        print(run([str(binary)], 15, capture=True), end="")



if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
