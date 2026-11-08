#!/usr/bin/env python3
"""Exercise the compiled menu-bar module against two real disposable status items."""

import argparse
from contextlib import ExitStack
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import uuid
from probe_tcc import _stop, accessibility_grant

ROOT = Path(__file__).resolve().parents[1]
CASES = ("settings", "narrow-reorder", "wide-reorder", "covered-reorder", "drag-insertion", "live-title", "identity-replacement")


def command(arguments, seconds):
    process = subprocess.Popen(arguments, start_new_session=True)
    try:
        status = process.wait(timeout=seconds)
        if status:
            raise RuntimeError(f"{arguments[0]} exited {status}")
    finally:
        _stop(process)


def interrupted(signum, _frame):
    raise SystemExit(128 + signum)


FIXTURE = r'''
import AppKit
import ApplicationServices
setbuf(stdout, nil)
if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--release-input" {
    let point = CGEvent(source: nil)?.location ?? .zero
    for type: CGEventType in [.leftMouseUp, .mouseMoved] {
        let event = CGEvent(mouseEventSource: CGEventSource(stateID: .privateState), mouseType: type,
                            mouseCursorPosition: point, mouseButton: .left)!
        event.flags = []
        event.post(tap: .cghidEventTap)
    }
    exit(0)
}
if CommandLine.arguments.count == 6 && CommandLine.arguments[1] == "--drag-row" {
    let values = CommandLine.arguments.dropFirst(2).compactMap(Double.init)
    guard values.count == 4, CGPreflightPostEventAccess() else { exit(2) }
    let start = CGPoint(x: values[0], y: values[1])
    let target = CGPoint(x: values[2], y: values[3])
    let source = CGEventSource(stateID: .privateState)!
    func post(_ type: CGEventType, _ point: CGPoint) {
        let event = CGEvent(mouseEventSource: source, mouseType: type,
                            mouseCursorPosition: point, mouseButton: .left)!
        event.flags = []
        event.post(tap: .cghidEventTap)
    }
    post(.mouseMoved, start)
    Thread.sleep(forTimeInterval: 0.05)
    post(.leftMouseDown, start)
    Thread.sleep(forTimeInterval: 0.08)
    for step in 1...24 {
        let fraction = CGFloat(step) / 24
        post(.leftMouseDragged, CGPoint(x: start.x + (target.x - start.x) * fraction,
                                        y: start.y + (target.y - start.y) * fraction))
        Thread.sleep(forTimeInterval: 0.02)
    }
    Thread.sleep(forTimeInterval: 0.12)
    post(.leftMouseUp, target)
    exit(0)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var first = NSStatusBar.system.statusItem(withLength: CommandLine.arguments.contains("--wide") ? 200 : 34)
func configureFirst() {
    first.button?.title = "FXA"
    first.button?.setAccessibilityTitle("Flux fixture A")
}
configureFirst()
let second = NSStatusBar.system.statusItem(withLength: 69)
second.button?.title = "FXB"
second.button?.setAccessibilityTitle("Flux fixture B")
let control = URL(fileURLWithPath: CommandLine.arguments[1])
var last = ""
let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
    guard let command = try? String(contentsOf: control, encoding: .utf8), command != last else { return }
    last = command
    if command == "live" {
        first.length = 200
        first.button?.title = "Notion Calendar · in 2 h 37 m"
        first.button?.setAccessibilityTitle("Notion Calendar")
    } else if command == "remove" {
        NSStatusBar.system.removeStatusItem(first)
    } else if command == "restore" {
        first = NSStatusBar.system.statusItem(withLength: 34)
        configureFirst()
    }
}
RunLoop.main.add(timer, forMode: .common)
DispatchQueue.main.asyncAfter(deadline: .now() + 100) { exit(1) }
app.run()
'''

PROBE = r'''
import AppKit
import ApplicationServices
setbuf(stdout, nil)

@MainActor
final class CheckedDestination: MenuBarDragDestinationView {
    var inspect: (() -> Void)?
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let result = super.performDragOperation(sender)
        if result { inspect?() }
        return result
    }
}

@MainActor
func probe() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let arguments = CommandLine.arguments
    let selected = arguments[1]
    let fixtureBundle = arguments[2]
    let helper = arguments[3]
    let control = URL(fileURLWithPath: arguments[4])
    let suite = "flux.icon-policy.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let key = "flux.macOS27IconLayout"
    var occluder: NSPanel?
    let hider = MacOS27Hider(defaults: defaults)
    let manager = MenuBarIconManager(hider: hider)
    manager.alwaysHiddenEnabledProvider = { true }
    manager.boundaryProvider = { (nil, nil) }
    manager.chevronBoundaryProvider = { nil }
    func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else {
            print("FAIL: \(selected): \(label)")
            occluder?.orderOut(nil)
            defaults.removePersistentDomain(forName: suite)
            exit(1)
        }
        print("PASS: \(selected): \(label)")
    }
    func owned(_ source: MenuBarIconManager? = nil) -> [MenuBarIconManager.Icon] {
        (source ?? manager).icons.filter { $0.id.hasPrefix(fixtureBundle + "|") }.sorted { $0.frame.minX < $1.frame.minX }
    }
    func readFrames() -> [CGRect] {
        guard let owner = NSRunningApplication.runningApplications(withBundleIdentifier: fixtureBundle).first else { return [] }
        let application = AXUIElementCreateApplication(owner.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.2)
        func attribute(_ item: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(item, name as CFString, &value) == .success ? value : nil
        }
        guard let bar = attribute(application, kAXExtrasMenuBarAttribute),
              CFGetTypeID(bar) == AXUIElementGetTypeID(),
              let children = attribute(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] else { return [] }
        return children.compactMap { child in
            guard let position = attribute(child, kAXPositionAttribute),
                  let size = attribute(child, kAXSizeAttribute),
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero
            var dimensions = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
                  AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
            return CGRect(origin: point, size: dimensions)
        }
    }
    func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
    @MainActor func coverCenter(of icon: MenuBarIconManager.Icon) async {
        occluder?.orderOut(nil)
        await pause(0.1)
        guard let identity = MenuBarIconManager.appIconIdentity(from: icon.id) else {
            check(false, "covered source has an owner identity"); return
        }
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        let application = AXUIElementCreateApplication(identity.processID)
        AXUIElementSetMessagingTimeout(application, 0.2)
        guard let bar = attribute(application, kAXExtrasMenuBarAttribute),
              CFGetTypeID(bar) == AXUIElementGetTypeID(),
              let children = attribute(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement],
              children.indices.contains(identity.index) else {
            check(false, "covered source has a current app-owner AX element"); return
        }
        let source = children[identity.index]
        func hit(_ point: CGPoint) -> AXUIElement? {
            var element: AXUIElement?
            return AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),
                Float(point.x), Float(point.y), &element) == .success ? element : nil
        }
        func belongsToSource(_ candidate: AXUIElement?) -> Bool {
            guard var element = candidate else { return false }
            for _ in 0..<8 {
                if CFEqual(element, source) { return true }
                guard let parent = attribute(element, kAXParentAttribute),
                      CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
                element = parent as! AXUIElement
            }
            return false
        }
        let center = CGPoint(x: icon.frame.midX, y: icon.frame.midY)
        check(belongsToSource(hit(center)), "uncovered center resolves to the exact source AX item")
        let panel = occluder ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .screenSaver
        let frame = NSRect(x: center.x - 4, y: NSScreen.screens[0].frame.maxY - icon.frame.maxY,
                           width: 8, height: icon.frame.height)
        panel.setFrame(frame, display: true)
        panel.contentView = NSButton(title: "Cover", target: nil, action: nil)
        panel.orderFrontRegardless()
        occluder = panel
        await pause(0.2)
        var coveredPID: pid_t = 0
        if let covered = hit(center) { AXUIElementGetPid(covered, &coveredPID) }
        check(coveredPID == getpid(), "a real foreign-owner panel covers the source center")
        let fractions: [CGFloat] = [0.1, 0.25, 0.75, 0.9]
        let edges = fractions.map {
            CGPoint(x: icon.frame.minX + icon.frame.width * $0, y: center.y)
        }
        check(edges.contains { belongsToSource(hit($0)) },
              "an uncovered edge still resolves to the exact source AX item")
        print("COVER source=\(icon.frame) panel=\(frame) centerOwner=\(coveredPID)")
    }
    func completed(_ label: String) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 7
        while manager.isUpdatingIcons && ProcessInfo.processInfo.systemUptime < deadline { await pause(0.05) }
        check(!manager.isUpdatingIcons, "\(label) completes before its deadline")
        if manager.errorMessage != nil {
            manager.copyMenuBarReport()
            print(NSPasteboard.general.string(forType: .string) ?? "report unavailable")
        }
        check(manager.errorMessage == nil, "\(label) has no error before any Refresh: \(manager.errorMessage ?? "none")")
    }
    func policyIs(_ section: MenuBarSection) {
        check(owned().count == 2 && owned().allSatisfy { $0.section == section },
              "both same-app icons follow \(section.rawValue)")
        check(hider.section(for: fixtureBundle) == section, "policy readback agrees")
    }
    let controller = MenuBarDragController()
    let window = NSWindow(contentRect: NSRect(x: 300, y: 250, width: 520, height: 300),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Flux native arrangement fixture"
    var traces: [String] = []
    controller.trace = { traces.append($0); print("DRAG \($0)") }
    manager.beginIconManagement()
    Task { @MainActor in
        defer { controller.close(); manager.endIconManagement(); defaults.removePersistentDomain(forName: suite) }
        let readyBy = ProcessInfo.processInfo.systemUptime + 8
        while ProcessInfo.processInfo.systemUptime < readyBy {
            manager.refresh()
            if owned().count == 2 && !manager.isUpdatingIcons { break }
            await pause(0.15)
        }
        await pause(0.6)
        check(ControlItem.usesMacOS27Model, "runner exercises macOS 27 app policy")
        check(manager.isTrusted && CGPreflightPostEventAccess(), "Accessibility and event posting are ready")
        check(owned().count == 2, "both real fixture status items are readable")
        guard let original = owned().first(where: { $0.title.contains("fixture A") || $0.title == "FXA" }) else {
            check(false, "fixture A has a stable accessible title"); return
        }
        let firstID = original.id
        let initialCommand = CGEventSource.flagsState(.hidSystemState).contains(.maskCommand)
        var hit: AXUIElement?
        let hitResult = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),
            Float(original.frame.midX), Float(original.frame.midY), &hit)
        if let hit {
            var hitPID: pid_t = 0
            AXUIElementGetPid(hit, &hitPID)
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(hit, kAXRoleAttribute as CFString, &role)
            print("SOURCE HIT result=\(hitResult.rawValue) pid=\(hitPID) role=\(String(describing: role)) frame=\(original.frame)")
        } else {
            print("SOURCE HIT unavailable=\(hitResult.rawValue) frame=\(original.frame)")
        }
        let initialOrder = owned().map(\.id)
        let initialFrames = readFrames()
        check(initialFrames.count == 2, "fresh app-owner AX frames are complete")
        if selected == "settings" {
            let downs = CGEventSource.counterForEventType(.combinedSessionState, eventType: .leftMouseDown)
            let guardedDriver = MenuBarNativeDrag()
            let offBar = await guardedDriver.perform(from: CGRect(x: 100, y: 200, width: 34, height: 24),
                                                     to: CGPoint(x: 180, y: 212), canContinue: { true })
            check(!offBar && !guardedDriver.isRunning,
                  "off-menu-bar AX frames cannot start native input")
            let wrongOwner = await guardedDriver.perform(from: original.frame,
                                                         to: CGPoint(x: original.frame.midX, y: original.frame.midY),
                                                         expectedProcessID: getpid(), canContinue: { true })
            check(!wrongOwner && !guardedDriver.isRunning,
                  "a mismatched visible owner cannot start native input")
            check(CGEventSource.counterForEventType(.combinedSessionState, eventType: .leftMouseDown) == downs,
                  "rejected source frames post zero mouse-down events")
            for section: MenuBarSection in [.hidden, .alwaysHidden, .shown, .hidden, .shown] {
                guard let item = owned().first(where: { $0.id == firstID }) else { check(false, "source exists"); return }
                manager.move(item, to: section)
                await completed(section.rawValue)
                policyIs(section)
                check(owned().map(\.id) == initialOrder && readFrames() == initialFrames,
                      "section assignment preserves physical order and geometry")
            }
            check(CGEventSource.counterForEventType(.combinedSessionState, eventType: .leftMouseDown) == downs,
                  "section-only changes post no native mouse input")
            manager.endIconManagement()
            let reopenedHider = MacOS27Hider(defaults: defaults)
            let reopened = MenuBarIconManager(hider: reopenedHider)
            reopened.beginIconManagement()
            await pause(0.7)
            check(owned(reopened).count == 2 && owned(reopened).allSatisfy { $0.section == .shown },
                  "reopened management retains saved app policy")
            check(owned(reopened).map(\.id) == initialOrder, "reopen preserves physical order")
            reopened.endIconManagement()
        } else if selected == "identity-replacement" {
            try! Data("remove".utf8).write(to: control, options: .atomic)
            await pause(0.3)
            manager.refresh()
            check(owned().count == 1, "source removal is observed before the AX slot is reused")
            try! Data("restore".utf8).write(to: control, options: .atomic)
            await pause(0.5)
            manager.move(original, to: .hidden)
            let deadline = ProcessInfo.processInfo.systemUptime + 7
            while manager.isUpdatingIcons && ProcessInfo.processInfo.systemUptime < deadline { await pause(0.05) }
            check(!manager.isUpdatingIcons && manager.errorMessage != nil,
                  "removed AX element cannot assign its replacement")
            check(hider.section(for: fixtureBundle) == .shown, "replacement retains Shown policy")
            check(defaults.dictionary(forKey: key) == nil, "rejected stale row writes no policy")
        } else {
            manager.move(original, to: .hidden)
            await completed("prepare Hidden")
            policyIs(.hidden)
            if selected == "live-title" {
                try! Data("live".utf8).write(to: control, options: .atomic)
                await pause(0.5)
            }
            let leftInitially = initialOrder.first == firstID
            if selected == "drag-insertion" {
                window.makeKeyAndOrderFront(nil)
                app.activate(ignoringOtherApps: true)
                controller.open(manager: manager, window: window)
                await pause(0.4)
                check(app.isActive && NSApp.keyWindow === window, "real drag source window is active")
                for iteration in 0..<2 {
                    let rows = owned()
                    guard let moving = rows.first(where: { $0.id == firstID }),
                          let peer = rows.first(where: { $0.id != firstID }) else { check(false, "drag rows exist"); return }
                    let towardClock = rows.first?.id == firstID
                    let slot = MenuBarIconManager.Insertion(section: .hidden,
                        before: towardClock ? nil : peer, after: towardClock ? peer : nil)
                    let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 300))
                    let source = controller.makeSourceView(for: moving)
                    source.frame = NSRect(x: 30, y: 170, width: 60, height: 50)
                    let destination = CheckedDestination(frame: NSRect(x: 190, y: 100, width: 260, height: 160))
                    destination.controller = controller
                    destination.section = .hidden
                    destination.insertionAt = { _ in slot }
                    var staged = false
                    let physicalBefore = readFrames()
                    destination.inspect = {
                        staged = true
                        check(!traces.contains(where: { $0.hasPrefix("commit ") }), "drop is staged before native session end")
                        check(readFrames() == physicalBefore, "staged drop posts no physical menu-bar move")
                    }
                    root.addSubview(source); root.addSubview(destination)
                    window.contentView = root
                    traces = []
                    @MainActor func global(_ view: NSView) -> CGPoint {
                        let local = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
                        let point = window.convertPoint(toScreen: local)
                        return CGPoint(x: point.x, y: NSScreen.screens[0].frame.maxY - point.y)
                    }
                    let start = global(source), target = global(destination)
                    let helperProcess = Process()
                    helperProcess.executableURL = URL(fileURLWithPath: helper)
                    helperProcess.arguments = ["--drag-row", "\(start.x)", "\(start.y)", "\(target.x)", "\(target.y)"]
                    try! helperProcess.run()
                    let helperBy = ProcessInfo.processInfo.systemUptime + 4
                    while helperProcess.isRunning && ProcessInfo.processInfo.systemUptime < helperBy { await pause(0.02) }
                    if helperProcess.isRunning { helperProcess.terminate(); check(false, "row input helper deadline") }
                    check(helperProcess.terminationStatus == 0, "row input helper finishes")
                    let commitBy = ProcessInfo.processInfo.systemUptime + 5
                    while !traces.contains(where: { $0.hasPrefix("commit ") })
                            && ProcessInfo.processInfo.systemUptime < commitBy { await pause(0.05) }
                    check(staged, "actual NSDraggingSession reached its destination")
                    guard let stage = traces.firstIndex(where: { $0.hasPrefix("staged ") }),
                          let end = traces.firstIndex(where: { $0.hasPrefix("ended ") }),
                          let commit = traces.firstIndex(where: { $0.hasPrefix("commit ") }) else {
                        check(false, "stage, native end and commit receipts exist"); return
                    }
                    check(stage < end && end < commit, "native session ends before transaction submission")
                    await completed("row drop \(iteration)")
                    check(owned().first?.id == (towardClock ? peer.id : firstID), "row drop changes real neighbor order")
                    policyIs(.hidden)
                }
            } else {
                // Keep the original snapshot through a live title/width change. The
                // public move must resolve the same AX item at its current frame.
                let argument = selected == "live-title" ? original : owned().first { $0.id == firstID }!
                if selected == "covered-reorder" { await coverCenter(of: argument) }
                let firstDowns = CGEventSource.counterForEventType(.combinedSessionState, eventType: .leftMouseDown)
                manager.move(argument, toward: leftInitially ? .towardClock : .towardDrawer)
                await completed("first physical reorder")
                if selected == "covered-reorder" {
                    check(CGEventSource.counterForEventType(.combinedSessionState, eventType: .leftMouseDown) == firstDowns + 1,
                          "covered-source reorder posts exactly one native drag")
                }
                check(CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand) == initialCommand,
                      "native move restores the original Command state")
                check(owned().map(\.id) == Array(initialOrder.reversed()), "fresh AX inventory proves physical peer swap")
                let reorderedFrames = readFrames()
                check(reorderedFrames.count == 2 && zip(reorderedFrames, initialFrames).contains {
                    abs($0.0.midX - $0.1.midX) >= 3
                }, "independent app-owner AX scan confirms physical movement")
                policyIs(.hidden)
                let moved = owned().first { $0.id == firstID }!
                if selected == "live-title" {
                    check(moved.identity == original.identity && moved.frame.width > original.frame.width,
                          "live title and width preserve item identity")
                }
                if selected == "covered-reorder" { await coverCenter(of: moved) }
                let reverseDowns = CGEventSource.counterForEventType(.combinedSessionState, eventType: .leftMouseDown)
                manager.move(moved, toward: leftInitially ? .towardDrawer : .towardClock)
                await completed("consecutive reverse reorder")
                if selected == "covered-reorder" {
                    check(CGEventSource.counterForEventType(.combinedSessionState, eventType: .leftMouseDown) == reverseDowns + 1,
                          "covered-source reverse reorder posts exactly one native drag")
                }
                check(owned().map(\.id) == initialOrder, "second move restores peer order without Refresh")
                policyIs(.hidden)
            }
        }
        occluder?.orderOut(nil)
        print("PASS: native product interface \(selected)")
        controller.close()
        manager.endIconManagement()
        defaults.removePersistentDomain(forName: suite)
        exit(0)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 75) { print("FAIL: product fixture deadline"); exit(1) }
    app.run()
}
AccessibilityAccess.exitIfRequested()
MainActor.assumeIsolated { probe() }
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", choices=CASES)
    parser.add_argument("--insertion", action="store_true", help="Alias for narrow-reorder")
    parser.add_argument("--wide-item", action="store_true", help="Select wide-reorder")
    parser.add_argument("--drag-context", action="store_true", help="Select actual drag-insertion")
    parser.add_argument("--saved-section-reorder", action="store_true", help="Compatibility alias; all reorders use saved policy")
    args = parser.parse_args()
    selected = args.case or ("drag-insertion" if args.drag_context else "wide-reorder" if args.wide_item
                             else "narrow-reorder" if args.insertion or args.saved_section_reorder else "settings")
    if sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true":
        raise SystemExit("FAIL: icon fixtures and grants require a disposable GitHub macOS runner")
    fixture_id = "com.flux.icon-fixture." + uuid.uuid4().hex
    probe_id = "com.flux.icon-probe." + uuid.uuid4().hex
    with tempfile.TemporaryDirectory(prefix="flux-icon-probe-") as directory:
        temporary = Path(directory)

        def bundle(name, bundle_id, source, dependencies):
            app = temporary / (name + ".app")
            binary = app / "Contents/MacOS" / name
            binary.parent.mkdir(parents=True)
            with (app / "Contents/Info.plist").open("wb") as stream:
                plistlib.dump({"CFBundleIdentifier": bundle_id, "CFBundleExecutable": name,
                              "CFBundlePackageType": "APPL", "LSUIElement": True}, stream)
            # Top-level executable statements use main.swift in a separate folder.
            source_folder = temporary / name
            source_folder.mkdir()
            main_source = source_folder / "main.swift"
            main_source.write_text(source)
            command(["xcrun", "swiftc", "-swift-version", "5", str(main_source)] +
                    [str(ROOT / "Sources/Flux" / item) for item in dependencies] + ["-o", str(binary)], 120)
            command(["codesign", "--force", "--sign", "-", str(app)], 20)
            return binary

        fixture = bundle("FluxIconFixture", fixture_id, FIXTURE, [])
        dependencies = ["MenuBar/MenuBarIconManager.swift", "MenuBar/MenuBarArrangement.swift",
                        "MenuBar/MenuBarNativeDrag.swift", "MenuBar/MacOS27Hider.swift",
                        "MenuBar/ControlItem.swift", "MenuBar/MenuBarSection.swift", "MenuBar/MenuBarIconStyle.swift",
                        "MenuBar/MenuBarGeometry.swift", "MenuBar/MenuBarDragController.swift",
                        "Support/Theme.swift", "Support/Log.swift", "Support/AccessibilityAccess.swift"]
        binary = bundle("FluxIconProbe", probe_id, PROBE, dependencies)
        control = temporary / "control"
        with ExitStack() as grants:
            grants.enter_context(accessibility_grant(fixture_id))
            grants.enter_context(accessibility_grant(probe_id))
            process = subprocess.Popen([str(fixture), str(control)] +
                                       (["--wide"] if selected == "wide-reorder" else []), start_new_session=True)
            try:
                command([str(binary), selected, fixture_id, str(fixture), str(control)], 85)
            finally:
                try:
                    # Release only during teardown, after the real consecutive-move checks.
                    command([str(fixture), "--release-input"], 5)
                finally:
                    _stop(process)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    main()
