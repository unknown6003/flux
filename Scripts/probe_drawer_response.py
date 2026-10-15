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
    if CommandLine.arguments.contains("spacing") {
        let statusBar = NSStatusBar.system
        var items: [NSStatusItem] = []
        var dividers: [ControlItem] = []
        defer {
            items.forEach(statusBar.removeStatusItem)
            dividers.forEach { $0.removeFromStatusBar() }
        }
        func marker(_ color: NSColor) {
            let image = NSImage(size: NSSize(width: 14, height: 14))
            image.lockFocus()
            color.setFill()
            NSRect(x: 0, y: 0, width: 14, height: 14).fill()
            image.unlockFocus()
            let item = statusBar.statusItem(withLength: 24)
            item.button?.image = image
            items.append(item)
        }
        for _ in 0..<3 { marker(NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)) }
        for index in 0..<3 {
            marker(NSColor(srgbRed: 0, green: 1, blue: 1, alpha: 1))
            if index < 2 {
                dividers.append(ControlItem(role: .divider, autosaveName: "spacing.\(index).\(UUID())"))
                dividers.last!.setCollapsed(index == 0)
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", CommandLine.arguments[2]]
        try! capture.run()
        capture.waitUntilExit()
        guard capture.terminationStatus == 0,
              let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])),
              let bitmap = NSBitmapImageRep(data: data) else {
            print("FAIL: the spacing probe could not capture the menu bar")
            exit(1)
        }
        var reference: [Int] = []
        var divided: [Int] = []
        for x in 0..<bitmap.pixelsWide {
            var magenta = 0
            var cyan = 0
            for y in 0..<min(100, bitmap.pixelsHigh) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.9 && color.blueComponent > 0.9 && color.greenComponent < 0.1 { magenta += 1 }
                if color.greenComponent > 0.9 && color.blueComponent > 0.9 && color.redComponent < 0.1 { cyan += 1 }
            }
            if magenta >= 8 { reference.append(x) }
            if cyan >= 8 { divided.append(x) }
        }
        func centers(_ columns: [Int]) -> [Double] {
            var groups: [[Int]] = []
            for x in columns {
                if let last = groups.last?.last, x == last + 1 { groups[groups.count - 1].append(x) }
                else { groups.append([x]) }
            }
            return groups.map { Double($0.first! + $0.last!) / 2 }
        }
        let control = centers(reference)
        let actual = centers(divided)
        print("REFERENCE_CENTERS \(control) DIVIDED_CENTERS \(actual)")
        guard control.count == 3, actual.count == 3 else {
            print("FAIL: all six marker controls must be visible before measuring spacing")
            exit(1)
        }
        let normal = [control[1] - control[0], control[2] - control[1]]
        let gaps = [actual[1] - actual[0], actual[2] - actual[1]]
        let scale = bitmap.size.width > 0 ? Double(bitmap.pixelsWide) / Double(bitmap.size.width) : 2
        print("REFERENCE_GAPS \(normal) DIVIDED_GAPS \(gaps)")
        guard normal.max()! - normal.min()! <= scale,
              gaps.allSatisfy({ abs($0 - normal[0]) <= 2 * scale }) else {
            print("FAIL: an invisible divider adds a gap between menu bar icons")
            exit(1)
        }
        print("PASS: both invisible dividers match normal icon spacing in captured pixels")
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
    parser.add_argument("--case", choices=("timing", "spacing", "all"), default="all")
    parser.add_argument("--artifacts-dir", type=Path)
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
        if options.case in ("timing", "all"):
            print(run([str(binary)], 15, capture=True), end="")
        if options.case in ("spacing", "all"):
            output = options.artifacts_dir or root / "build/drawer-response"
            output.mkdir(parents=True, exist_ok=True)
            print(run([str(binary), "spacing", str(output / "spacing.png")], 15, capture=True), end="")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
