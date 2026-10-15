#!/usr/bin/env python3
"""Exercise cached layout changes and overlapping lifecycle calls through the hider."""

from pathlib import Path
import sys
import tempfile

from probe_hidden_transition import run


FIXTURE = r'''
import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let suite = "com.flux.layout-probe." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["hidden": ["test.normal", "test.always"], "alwaysHidden": ["test.always"]],
                 forKey: "flux.macOS27IconLayout")
    var positions: [(bundleID: String, x: CGFloat)] = [("test.normal", 250)]
    var reads = 0
    let hider = MacOS27Hider(defaults: defaults, trustProvider: { true }, positionReader: {
        reads += 1
        return (positions, [])
    })
    func waitForRead() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    }
    func layout() -> (hidden: Set<String>, always: Set<String>) {
        let value = defaults.dictionary(forKey: "flux.macOS27IconLayout")!
        return (Set(value["hidden"] as! [String]), Set(value["alwaysHidden"] as! [String]))
    }
    @MainActor func apply(_ revealed: Bool, _ always: Bool, arrow: @escaping () -> CGFloat? = { 300 }) {
        hider.apply(revealHidden: revealed, revealAlwaysHidden: always,
                    chevronX: arrow, alwaysX: { 200 })
    }
    apply(true, false)
    waitForRead()
    positions = [("test.normal", 350)]
    apply(false, false)
    waitForRead()
    let moved = layout()
    guard reads > 0, !moved.hidden.contains("test.normal"),
          moved.hidden.contains("test.always"), moved.always.contains("test.always") else {
        print("FAIL: a visible icon moved to Shown kept its cached Hidden assignment; reads=\(reads)")
        exit(1)
    }
    print("PASS: cached toggles read moved positions and preserve unread Always Hidden items")

    positions = [("test.normal", 250), ("test.always", 150)]
    apply(true, true)
    waitForRead()
    var arrow: CGFloat? = nil
    let before = reads
    apply(false, false, arrow: { arrow })
    apply(false, false, arrow: { arrow })
    hider.retry()
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didLaunchApplicationNotification,
                                               object: nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    arrow = 300
    waitForRead()
    let managed = layout()
    guard reads > before, managed.hidden == ["test.normal", "test.always"],
          managed.always == ["test.always"] else {
        print("FAIL: duplicate lifecycle calls discarded the management layout scan; reads=\(reads), before=\(before)")
        exit(1)
    }
    print("PASS: duplicate end, retry and workspace callbacks retain a pending layout read")
    apply(true, true)
    waitForRead()
}
'''


def main():
    if sys.platform != "darwin":
        raise RuntimeError("layout scheduling needs native AppKit")
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="flux-layout-probe-") as directory:
        temporary = Path(directory)
        source = temporary / "main.swift"
        source.write_text(FIXTURE)
        binary = temporary / "FluxLayoutProbe"
        files = ["MenuBar/MacOS27Hider.swift", "MenuBar/MenuBarGeometry.swift",
                 "Support/Log.swift", "Support/AccessibilityAccess.swift"]
        run(["xcrun", "swiftc", "-swift-version", "5", str(source),
             *[str(root / "Sources/Flux" / path) for path in files], "-o", str(binary)], 120)
        run([str(binary)], 10)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
