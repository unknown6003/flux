#!/usr/bin/env python3
"""Exercise cached layout changes and overlapping lifecycle calls through the hider."""

import argparse
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
    print("PROBE_SUITE \(suite)")
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let overlapOnly = CommandLine.arguments.contains("overlap")
    defaults.set(["hidden": overlapOnly ? ["test.always"] : ["test.normal", "test.always"],
                  "alwaysHidden": ["test.always"]],
                 forKey: "flux.macOS27IconLayout")
    let batchOnly = CommandLine.arguments.contains("batch")
    if batchOnly {
        defaults.set(["hidden": ["test.normal", "test.always", "test.kept"],
                      "alwaysHidden": ["test.always", "test.kept"]],
                     forKey: "flux.macOS27IconLayout")
    }
    var positions: [(bundleID: String, x: CGFloat)] = [("test.normal", 250)]
    var reads = 0
    var allowCommit = true
    var invalidateRead = false
    let hider = MacOS27Hider(defaults: defaults, trustProvider: { true }, positionReader: {
        reads += 1
        if invalidateRead { allowCommit = false }
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
    if batchOnly {
        apply(true, true)
        waitForRead()
        let before = layout()
        positions = [("test.normal", 350), ("test.always", 250), ("test.kept", 50)]
        invalidateRead = true
        guard !hider.recordLayoutChanges(for: ["test.normal", "test.always"], canCommit: { allowCommit }),
              layout().hidden == before.hidden, layout().always == before.always,
              hider.section(for: "test.normal") == .hidden else {
            print("FAIL: input during a layout read saved a partial native move")
            exit(1)
        }
        invalidateRead = false
        allowCommit = true
        guard hider.recordLayoutChanges(for: ["test.normal", "test.always"], canCommit: { allowCommit }),
              layout().hidden == ["test.always", "test.kept"], layout().always == ["test.kept"] else {
            print("FAIL: the completed native batch lost a move or an unrelated assignment")
            exit(1)
        }
        print("PASS: native layout batch validates input after reads and saves all edits together")
        return
    }
    if CommandLine.arguments.contains("no-edit") {
        positions = [("test.normal", 150), ("test.always", 350)]
        apply(true, true)
        waitForRead()
        let opened = layout()
        guard opened.hidden == ["test.normal", "test.always"],
              opened.always == ["test.always"] else {
            defaults.removePersistentDomain(forName: suite)
            print("FAIL: opening management without a move rewrote the saved layout; hidden=\(opened.hidden.sorted()), always=\(opened.always.sorted())")
            exit(1)
        }
        hider.retry()
        waitForRead()
        let refreshed = layout()
        guard refreshed.hidden == opened.hidden, refreshed.always == opened.always else {
            defaults.removePersistentDomain(forName: suite)
            print("FAIL: a no-edit refresh rewrote the saved layout")
            exit(1)
        }
        let relaunched = MacOS27Hider(defaults: defaults, trustProvider: { true },
                                      positionReader: { (positions, []) })
        relaunched.apply(revealHidden: true, revealAlwaysHidden: true,
                         chevronX: { 300 }, alwaysX: { 200 })
        waitForRead()
        let reloaded = layout()
        guard reloaded.hidden == opened.hidden, reloaded.always == opened.always else {
            defaults.removePersistentDomain(forName: suite)
            print("FAIL: relaunch rewrote the saved layout")
            exit(1)
        }
        print("PASS: no-edit management and refresh preserve saved sections despite changed AX geometry")
        return
    }
    if !overlapOnly {
        apply(true, false)
        waitForRead()
        positions = [("test.normal", 350), ("test.always", 350)]
        guard hider.recordLayoutChange(for: "test.normal") else {
            print("FAIL: the explicit move could not save its layout")
            exit(1)
        }
        apply(false, false)
        waitForRead()
        let moved = layout()
        guard reads > 0, !moved.hidden.contains("test.normal"),
              moved.hidden.contains("test.always"), moved.always.contains("test.always") else {
            defaults.removePersistentDomain(forName: suite)
            print("FAIL: a visible icon moved to Shown kept its cached Hidden assignment; reads=\(reads)")
            exit(1)
        }
        print("PASS: an explicit move saves its section and preserves unrelated Always Hidden items")
        if CommandLine.arguments.contains("moves") { return }
    }

    positions = [("test.normal", 350), ("test.always", 150)]
    apply(true, true)
    waitForRead()
    positions = [("test.normal", 250), ("test.always", 150)]
    var arrow: CGFloat? = nil
    let before = reads
    apply(false, false, arrow: { arrow })
    apply(false, false, arrow: { arrow })
    hider.retry()
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didLaunchApplicationNotification,
                                               object: nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    arrow = 300
    guard hider.recordLayoutChange(for: "test.normal") else {
        print("FAIL: the verified management move could not save its layout")
        exit(1)
    }
    waitForRead()
    let managed = layout()
    guard reads > before, managed.hidden == ["test.normal", "test.always"],
          managed.always == ["test.always"] else {
        defaults.removePersistentDomain(forName: suite)
        print("FAIL: duplicate lifecycle calls discarded the management layout scan; reads=\(reads), before=\(before)")
        exit(1)
    }
    print("PASS: duplicate end, retry and workspace callbacks preserve a verified layout edit")
    apply(true, true)
    waitForRead()
}
'''


def main():
    if sys.platform != "darwin":
        raise RuntimeError("layout scheduling needs native AppKit")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", choices=("all", "moves", "overlap", "no-edit", "batch"), default="all")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="flux-layout-probe-") as directory:
        temporary = Path(directory)
        source = temporary / "main.swift"
        source.write_text(FIXTURE)
        binary = temporary / "FluxLayoutProbe"
        files = ["MenuBar/MacOS27Hider.swift", "MenuBar/MenuBarGeometry.swift", "MenuBar/MenuBarSection.swift",
                 "Support/Log.swift", "Support/AccessibilityAccess.swift"]
        run(["xcrun", "swiftc", "-swift-version", "5", str(source),
             *[str(root / "Sources/Flux" / path) for path in files], "-o", str(binary)], 120)
        if args.case == "all":
            run([str(binary), "no-edit"], 10)
            run([str(binary), "batch"], 10)
        run([str(binary), args.case], 10)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
