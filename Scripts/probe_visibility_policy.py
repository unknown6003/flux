#!/usr/bin/env python3
"""Check app-scoped visibility through the real hider's public interface on macOS."""

import argparse
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = "Sources/Flux/MenuBar/MacOS27Hider.swift"


def command(arguments, seconds, quiet=False):
    process = subprocess.Popen(arguments, cwd=ROOT, start_new_session=True,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        output, _ = process.communicate(timeout=seconds)
        if output and not quiet:
            print(output, end="", flush=True)
        if process.returncode:
            raise RuntimeError(f"{arguments[0]} exited {process.returncode}")
        return output
    finally:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=2)


def interrupted(signum, _frame):
    raise SystemExit(128 + signum)


FIXTURE = r'''
import AppKit
import os

enum Log {
    static let menuBar = Logger(subsystem: "com.flux.visibility-policy-probe", category: "test")
}
enum AccessibilityAccess {
    static func isGranted() -> Bool { false }
}
extension NSScreen {
    var menuBarThickness: CGFloat { NSStatusBar.system.thickness }
}

@main
struct VisibilityProbe {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        let suite = "flux.visibility-policy-probe.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "flux.macOS27IconLayout"
        var scans = 0
        var grants = 0
        var canCommit = true
        var readBalance = 0
        var readCalls = 0
        var sourcePositions: [(bundleID: String, x: CGFloat)] = []
        var allowRead = false
        let hider = MacOS27Hider(defaults: defaults, trustProvider: {
            grants += 1
            return allowRead
        }, positionReader: {
            scans += 1
            return (sourcePositions, [])
        })
        hider.onReadState = {
            readCalls += 1
            readBalance += $0 ? 1 : -1
        }
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { print("FAIL: \(label)"); exit(1) }
            print("PASS: \(label)")
        }
        check(hider.isAvailable, "native hiding backend is available")
        check(hider.recordAppSection(.hidden, for: "test.notion", canCommit: { canCommit }),
              "explicit assignment needs no grant, position, or divider")
        check(scans == 0 && grants == 0 && readCalls == 0,
              "explicit assignment performs no AX scan or grant read")
        check(hider.section(for: "test.notion") == .hidden && hider.hasSavedLayout,
              "assignment becomes saved app policy")
        check(hider.section(for: "test.new-app") == .shown, "new apps default to Shown")
        check(defaults.dictionary(forKey: key)?["schemaVersion"] as? Int == 2,
              "commit uses the existing storage key with schema 2")
        let committed = defaults.dictionary(forKey: key)! as NSDictionary
        canCommit = false
        check(!hider.recordAppSection(.alwaysHidden, for: "test.notion", canCommit: { canCommit }),
              "expired transaction cannot change assignment")
        check(committed == (defaults.dictionary(forKey: key)! as NSDictionary),
              "expired transaction cannot change persisted policy")
        check(!hider.recordAppSection(.hidden, for: "com.flux.menubar"),
              "Flux cannot hide itself")
        check(!hider.recordAppSection(.hidden, for: "com.apple.controlcenter"),
              "system bundles cannot be assigned")
        check(!hider.recordAppSection(.hidden, for: ""), "empty bundle is rejected")
        hider.apply(revealHidden: true, revealAlwaysHidden: true,
                    chevronX: { nil }, alwaysX: { nil })
        check(scans == 0 && grants == 0, "reveal does not import physical geometry")
        check(hider.recordAppSection(.shown, for: "test.notion"),
              "logical section can change with unreadable positions")
        let reloaded = MacOS27Hider(defaults: defaults, trustProvider: { false })
        check(reloaded.section(for: "test.notion") == .shown && reloaded.hasSavedLayout,
              "saved policy reloads without access")

        defaults.set(["hidden": ["test.hidden", "test.always", "com.apple.Spotlight",
                                 "com.flux.menubar", "", " bad.id "],
                      "alwaysHidden": ["test.always", "test.orphan"]], forKey: key)
        let legacy = MacOS27Hider(defaults: defaults, trustProvider: { false })
        check(legacy.section(for: "test.hidden") == .hidden
                && legacy.section(for: "test.always") == .alwaysHidden,
              "legacy document preserves valid app assignments")
        check(legacy.section(for: "test.orphan") == .shown
                && legacy.section(for: "com.apple.Spotlight") == .shown
                && legacy.section(for: "com.flux.menubar") == .shown,
              "legacy migration removes orphan and reserved assignments")
        check(defaults.dictionary(forKey: key)?["schemaVersion"] == nil,
              "reading legacy policy leaves saved document unchanged")
        check(legacy.recordAppSection(.hidden, for: "test.new-app"),
              "first legacy edit commits migrated policy")
        let saved = defaults.dictionary(forKey: key)!
        check(Set(saved["hidden"] as! [String]) == ["test.hidden", "test.always", "test.new-app"],
              "migration retains only valid requested assignments")
        defaults.set(["hidden": ["test.hidden"]], forKey: key)
        let malformed = MacOS27Hider(defaults: defaults, trustProvider: { false })
        check(!malformed.hasSavedLayout && malformed.section(for: "test.hidden") == .shown,
              "incomplete store starts with every app Shown")

        allowRead = true
        sourcePositions = [("test.dragged", 30), ("test.other", 20)]
        hider.apply(revealHidden: true, revealAlwaysHidden: true,
                    chevronX: { 100 }, alwaysX: { 10 })
        check(hider.recordLayoutChange(for: "test.dragged"), "observed native drag can import geometry")
        check(hider.section(for: "test.dragged") == .hidden
                && hider.section(for: "test.other") == .shown,
              "native import changes only the requested app")
        sourcePositions = [("test.dragged", 30), ("test.dragged", 130)]
        check(hider.recordLayoutChange(for: "test.dragged")
                && hider.section(for: "test.dragged") == .shown,
              "one shown sibling keeps an imported app visible")
        sourcePositions = [("test.dragged", 30), ("test.dragged", .nan)]
        check(!hider.recordLayoutChange(for: "test.dragged"), "incomplete app geometry cannot be imported")
        sourcePositions = [("test.dragged", 30)]
        check(!hider.recordLayoutChange(for: "test.dragged", canCommit: { false }),
              "native import checks the commit token after its read")
        check(hider.section(for: "test.dragged") == .shown && readBalance == 0,
              "failed imports preserve policy and balance read callbacks")
        check(MacOS27Hider.completePositions(for: "test.dragged", centers: [30, nil]).isEmpty,
              "partial AX replies do not become a complete app")
        print("PASS: visibility policy public-interface suite")
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hider-ref", help="Compile an old hider to check the failing control")
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise SystemExit("FAIL: this probe requires macOS and its Swift toolchain")
    source = ((ROOT / SOURCE).read_text() if not args.hider_ref else
              command(["git", "show", f"{args.hider_ref}:{SOURCE}"], 20, quiet=True))
    with tempfile.TemporaryDirectory(prefix="flux-visibility-policy-") as directory:
        folder = Path(directory)
        hider = folder / "MacOS27Hider.swift"
        fixture = folder / "Probe.swift"
        hider.write_text(source)
        fixture_source = FIXTURE
        if "struct MenuBarVisibilityPolicy" in source:
            policy_checks = r'''
        var policy = MenuBarVisibilityPolicy()
        policy.assign(.hidden, to: "test.hidden")
        policy.assign(.alwaysHidden, to: "test.always")
        check(policy.excluded(revealHidden: false, revealAlwaysHidden: false,
                              alwaysHiddenEnabled: true) == ["test.hidden", "test.always"],
              "collapsed policy hides both saved sections")
        check(policy.excluded(revealHidden: true, revealAlwaysHidden: false,
                              alwaysHiddenEnabled: true) == ["test.always"],
              "normal reveal keeps Always Hidden private")
        check(policy.excluded(revealHidden: true, revealAlwaysHidden: false,
                              alwaysHiddenEnabled: false).isEmpty,
              "disabling Always Hidden makes its apps follow Hidden reveal")
        check(policy.section(for: "test.always") == .alwaysHidden,
              "disabling the section preserves the saved assignment")
        check(policy.excluded(revealHidden: false, revealAlwaysHidden: true,
                              alwaysHiddenEnabled: true).isEmpty,
              "management reveal releases every app")
'''
            fixture_source = fixture_source.replace(
                '        print("PASS: visibility policy public-interface suite")',
                policy_checks + '\n        print("PASS: visibility policy public-interface suite")')
        fixture.write_text(fixture_source)
        binary = folder / "probe"
        command(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                 str(hider), str(ROOT / "Sources/Flux/MenuBar/MenuBarSection.swift"),
                 str(fixture), "-o", str(binary)], 120)
        command([str(binary)], 20)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    main()
