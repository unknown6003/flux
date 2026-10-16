#!/usr/bin/env python3
"""Probe retained Settings close/reopen through native AppKit and SwiftUI.

Run on a logged-in macOS 14+ desktop with Xcode command-line tools:
    python3 Scripts/probe_settings_reopen.py
    python3 Scripts/probe_settings_reopen.py --controller-ref BASE

Proof boundary: compile the unchanged production SettingsWindowController,
SettingsView and MenuBarTab. Actual NSWindow.performClose and SwiftUI appearance
callbacks drive an in-memory manager recorder. The recorder reports requested
management reveal state, not real menu-bar visibility or the production manager's
permission/hider behavior. Other tabs, services, glyph capture and drag UI are
inert dependencies. No TCC calls, status items, app install or saved preferences.

Reopen requests the SAME tab on the SAME controller. Window and hosting-controller
identity must survive that reopen. The later General/Menu Bar discriminator uses
the public show(tab:) API.
It does not click the sidebar. Every tab request must retain the same hosting
controller. Failures from reopen remain failures if a later tab request recovers. Baseline failure is evidence, not an assumed
result: SwiftUI may deliver fresh appearance callbacks on a given macOS version.

--controller-ref reads the controller and its matching SettingsView from git,
without a checkout or source rewrite. The editor and dependency scaffold stay current.
Native compile/runtime checks cannot run on Linux; --help works on any platform.
"""

import argparse
import os
from pathlib import Path
import platform
import signal
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
CONTROLLER = "Sources/Flux/Settings/SettingsWindowController.swift"
SOURCES = (
    "Sources/Flux/Settings/SettingsView.swift",
    "Sources/Flux/Settings/Tabs/MenuBarTab.swift",
    "Sources/Flux/Settings/SettingsRows.swift",
    "Sources/Flux/Support/Theme.swift",
    "Sources/Flux/MenuBar/MenuBarSection.swift",
    "Sources/Flux/MenuBar/MenuBarIconStyle.swift",
)


def stop_group(process):
    """Stop the whole child group, including children that outlive its leader."""
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        output, _ = process.communicate(timeout=3)
    except subprocess.TimeoutExpired:
        output = None
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    final_output, _ = process.communicate(timeout=3)
    return final_output or output or ""


def run(command, seconds):
    process = subprocess.Popen(command, cwd=ROOT, start_new_session=True,
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True)
    try:
        output, _ = process.communicate(timeout=seconds)
    except subprocess.TimeoutExpired as error:
        output = stop_group(process)
        raise RuntimeError(f"deadline after {seconds}s for {command[0]}\n{output}") from error
    except BaseException:
        stop_group(process)
        raise
    stop_group(process)
    if process.returncode:
        raise RuntimeError(f"{Path(command[0]).name} exited {process.returncode}\n{output}")
    return output


DEPENDENCIES = r'''
import AppKit
import Combine
import SwiftUI

@MainActor final class SettingsStore: ObservableObject {
    @Published var appearance: FluxAppearance = .system
    @Published var showAlwaysHiddenSection = true
    @Published var compactMenuBarSpacing = false
    @Published var autoRehide = true
    @Published var autoRehideDelay = 5.0
    @Published var iconStyle: MenuBarIconStyle = .chevron

    var snapshot: String {
        "\(appearance.rawValue)|\(showAlwaysHiddenSection)|\(compactMenuBarSpacing)|" +
        "\(autoRehide)|\(autoRehideDelay)|\(iconStyle.rawValue)"
    }
}
@MainActor final class MenuBarArranger: ObservableObject {}
@MainActor final class NowPlayingService: ObservableObject {}
enum PermissionKind: Hashable { case unused }
enum PermissionStatus { case notDetermined, granted, denied, restricted, unavailable }
@MainActor final class PermissionCenter: ObservableObject {
    let statuses: [PermissionKind: PermissionStatus] = [:]
    func request(_ kind: PermissionKind) { fatalError("Probe must not request permission") }
    func openSystemSettings(_ kind: PermissionKind) { fatalError("Probe must not open System Settings") }
}
@MainActor final class CrashReporter: ObservableObject {}
@MainActor final class ClipboardMonitor: ObservableObject {}
@MainActor final class UpdateChecker: ObservableObject {
    func clearStaleOutcome() {}
}

// This records calls from the real controller and real MenuBarTab. It does not
// publish changes, drive appearance, run timers or implement the suspected fix.
@MainActor final class MenuBarIconManager: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    enum MoveDirection { case towardDrawer, towardClock }
    struct Icon: Identifiable, Equatable {
        let id: Int
        let title: String
        let source: String?
        let section: MenuBarSection
        let isMovable: Bool
    }
    let icons: [Icon] = []
    let isTrusted = true
    let isUpdatingIcons = false
    let canHideWithoutAccess = true
    let errorMessage: String? = nil
    private(set) var revealHidden = false
    private(set) var revealAlwaysHidden = false
    private(set) var begins = 0
    private(set) var ends = 0
    private(set) var events: [String] = []

    func beginIconManagement() {
        begins += 1
        revealHidden = true
        revealAlwaysHidden = true
        events.append("begin")
        print("CALL begin #\(begins)")
    }
    func endIconManagement() {
        ends += 1
        revealHidden = false
        revealAlwaysHidden = false
        events.append("end")
        print("CALL end #\(ends)")
    }
    func requestAccess() { fatalError("Probe must not request access") }
    func copyMenuBarReport() { fatalError("Probe must not write the pasteboard") }
    func move(_ icon: Icon, toward direction: MoveDirection) {
        fatalError("Probe must not move icons")
    }
    func move(_ icon: Icon, to section: MenuBarSection) {
        fatalError("Probe must not move icons")
    }
    func canMove(_ icon: Icon, toward direction: MoveDirection) -> Bool { false }
}

@MainActor final class MenuBarDragController: ObservableObject {
    var onWindowClose: (() -> Void)?
    let isMenuBarDragging = false
    let message: String? = nil
    func close() {}
    func refreshIcons() {}
    func setMenuBarDragging(_ active: Bool) {}
}
@MainActor final class MenuBarIconImages: ObservableObject {
    let hasAccess = true
    let message: String? = nil
    func open(_ icons: [MenuBarIconManager.Icon]) {}
    func refresh(_ icons: [MenuBarIconManager.Icon], force: Bool = false) {}
    func close() {}
    func requestAccess(_ icons: [MenuBarIconManager.Icon]) { fatalError("Probe must not request access") }
}
enum ControlItem { static let usesMacOS27Model = true }

struct MenuBarDragSettingsAnchor: NSViewRepresentable {
    let controller: MenuBarDragController
    let manager: MenuBarIconManager
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ view: NSView, context: Context) {}
}
struct MenuBarIconLane: NSViewRepresentable {
    let controller: MenuBarDragController
    let manager: MenuBarIconManager
    let images: MenuBarIconImages
    let section: MenuBarSection
    let icons: [MenuBarIconManager.Icon]
    let alwaysHiddenEnabled: Bool
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ view: NSView, context: Context) {}
}
private struct MenuBarSnapshotIconsKey: EnvironmentKey {
    static let defaultValue: [MenuBarIconManager.Icon]? = nil
}
extension EnvironmentValues {
    var menuBarSnapshotIcons: [MenuBarIconManager.Icon]? {
        get { self[MenuBarSnapshotIconsKey.self] }
        set { self[MenuBarSnapshotIconsKey.self] = newValue }
    }
}
struct GeneralTab: View { var body: some View { Text("General") } }
struct NotchTab: View { var body: some View { Text("Notch") } }
struct LockScreenTab: View { var body: some View { Text("Lock Screen") } }
struct AboutTab: View { var body: some View { Text("About") } }
'''


PROBE = r'''
import AppKit
import Combine
import SwiftUI

@MainActor func probe() {
    let app = NSApplication.shared
    guard !NSScreen.screens.isEmpty else {
        print("FAIL: a logged-in macOS desktop is required")
        exit(2)
    }
    let settings = SettingsStore()
    let saved = settings.snapshot
    let manager = MenuBarIconManager()
    let controller = SettingsWindowController(
        settings: settings, arranger: MenuBarArranger(), iconManager: manager,
        updater: UpdateChecker(), nowPlaying: NowPlayingService(),
        permissions: PermissionCenter(), crashReporter: CrashReporter(),
        clipboardMonitor: ClipboardMonitor())
    var visibility: [Bool] = []
    controller.onVisibilityChanged = { visibility.append($0) }
    var failures: [String] = []

    func check(_ condition: Bool, _ message: String) {
        print("\(condition ? "PASS" : "FAIL"): \(message)")
        if !condition { failures.append(message) }
    }
    func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        // Deliver actual AppKit/SwiftUI work. Elapsed time is not an assertion.
        while Date() < deadline {
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.01)))
        }
    }
    func waitFor(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { pump(0.01) }
        pump(0.2)
    }
    func state(_ label: String, _ expected: Bool) {
        waitFor {
            manager.revealHidden == expected && manager.revealAlwaysHidden == expected
        }
        print("STATE \(label) reveal=\(manager.revealHidden),\(manager.revealAlwaysHidden) " +
              "begins=\(manager.begins) ends=\(manager.ends) events=\(manager.events)")
        check(manager.revealHidden == expected && manager.revealAlwaysHidden == expected,
              "\(label): management reveal must be \(expected)")
    }

    print("OS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("BOUNDARY: real controller + SettingsView + MenuBarTab; recorder manager, inert services")
    controller.show(tab: .menuBar)
    pump(0.25)
    guard let window = app.windows.first(where: { $0.title == "Flux Settings" }),
          window.contentViewController != nil else {
        print("FAIL: production controller did not create a Settings hosting window")
        exit(2)
    }
    check(window.autorecalculatesKeyViewLoop, "dynamic native controls join the keyboard focus loop")
    var nativeCloses = 0
    let closeObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification, object: window, queue: .main
    ) { _ in nativeCloses += 1 }

    func close(_ label: String) {
        let before = nativeCloses
        window.performClose(nil)
        waitFor { !window.isVisible && nativeCloses == before + 1 }
        check(!window.isVisible && nativeCloses == before + 1,
              "\(label): native window closed and emitted willClose")
        check(visibility.last == false, "\(label): controller reported closed")
        state(label, false)
    }

    for cycle in 1...3 {
        if cycle > 1 { controller.show(tab: .menuBar) }
        // Keep identity only. Retaining an old hosting controller could change
        // the disappearance/deallocation behavior that this probe observes.
        let hostingID = window.contentViewController.map { ObjectIdentifier($0) }
        state("\(cycle) initial Menu Bar", true)
        check(window.isVisible, "\(cycle): Settings visible before close")
        close("\(cycle) first close")

        let beginsBeforeReopen = manager.begins
        controller.show(tab: .menuBar)
        waitFor { window.isVisible }
        check(app.windows.contains(where: { $0 === window }) && window.isVisible,
              "\(cycle): same native window reopened")
        check(hostingID != nil && window.contentViewController.map { ObjectIdentifier($0) } == hostingID,
              "\(cycle): hosting controller retained on same-tab reopen")
        check(visibility.last == true, "\(cycle): controller reported reopened")
        state("\(cycle) same-tab reopen", true)
        print("REOPEN begin delta=\(manager.begins - beginsBeforeReopen)")

        // Public tab requests are a separate discriminator after measuring reopen.
        controller.show(tab: .general)
        state("\(cycle) leave Menu Bar", false)
        check(window.contentViewController.map { ObjectIdentifier($0) } == hostingID,
              "\(cycle): hosting controller retained after General request")
        controller.show(tab: .menuBar)
        state("\(cycle) reenter Menu Bar", true)
        check(window.contentViewController.map { ObjectIdentifier($0) } == hostingID,
              "\(cycle): hosting controller retained after Menu Bar request")
        close("\(cycle) final close")
    }

    check(settings.snapshot == saved, "in-memory settings unchanged")
    check(nativeCloses == 6, "all six closes used native NSWindow lifecycle")
    check(visibility == Array(repeating: [true, false, true, true, true, false], count: 3).flatMap { $0 },
          "show/close visibility callbacks match the requested lifecycle")
    NotificationCenter.default.removeObserver(closeObserver)
    if window.isVisible { window.performClose(nil); pump(0.2) }
    app.setActivationPolicy(.accessory)
    print("\(failures.isEmpty ? "PASS" : "FAIL"): Settings reopen probe, failures=\(failures.count)")
    fflush(stdout)
    exit(failures.isEmpty ? 0 : 1)
}

MainActor.assumeIsolated {
    setbuf(stdout, nil)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    // Start from a run-loop timer so the probe's nested run-loop settling does
    // not hold a main-dispatch-queue block and prevent other main work running.
    let start = Timer(timeInterval: 0.01, repeats: false) { _ in
        MainActor.assumeIsolated { probe() }
    }
    RunLoop.main.add(start, forMode: .common)
    app.run()
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--controller-ref", metavar="BASE",
                        help="compile the unchanged controller and matching root view at this git ref")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.exit(2, "FAIL: native compile/runtime requires a macOS 14+ desktop\n")

    if args.controller_ref:
        ref = run(["git", "rev-parse", "--verify", "--end-of-options",
                   args.controller_ref + "^{commit}"], 10).strip()
        source = run(["git", "show", f"{ref}:{CONTROLLER}"], 10)
        print(f"Controller ref: {ref}", flush=True)
    else:
        source = (ROOT / CONTROLLER).read_text()
        print("Controller: current working tree", flush=True)

    with tempfile.TemporaryDirectory(prefix="flux-settings-reopen-") as temp:
        work = Path(temp)
        controller = work / "SettingsWindowController.swift"
        controller.write_text(source)
        dependencies = work / "Dependencies.swift"
        dependencies.write_text(DEPENDENCIES)
        main_swift = work / "main.swift"
        main_swift.write_text(PROBE)
        binary = work / "SettingsReopenProbe"
        sources = [ROOT / path for path in SOURCES]
        if args.controller_ref:
            old_view = work / "SettingsView.swift"
            old_view.write_text(run(["git", "show", f"{ref}:Sources/Flux/Settings/SettingsView.swift"], 10))
            sources[0] = old_view
        output = run(["xcrun", "swiftc", "-swift-version", "5", "-Onone",
                      "-target", f"{platform.machine()}-apple-macosx14.0",
                      "-module-cache-path", str(work / "module-cache"),
                      "-o", str(binary), str(controller),
                      *map(str, sources),
                      str(dependencies), str(main_swift)], 90)
        if output:
            print(output, end="", flush=True)
        print(run([str(binary)], 40), end="", flush=True)


if __name__ == "__main__":
    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, interrupted)
    try:
        main()
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        raise SystemExit(f"FAIL: {error}") from error
