#!/usr/bin/env python3
"""Exercise the real Settings lanes and drag controller with native AppKit events.

The manager records requests and reads identity from a disposable AX status item.
This proves real UI routing, cancellation, target size and fallback actions.
probe_icons.py separately proves physical moves and saved layout with the real manager.
Requires macOS desktop. Disposable CI restores its keyboard navigation setting.
"""
import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import time
from probe_settings_reopen import DEPENDENCIES, run

SWIFT = r'''
import AppKit
import ApplicationServices
import Combine
import SwiftUI

enum ControlItem { static let usesMacOS27Model = true }
@MainActor
final class MenuBarIconManager: ObservableObject {
    enum MoveDirection { case towardDrawer, towardClock }
    @Published private(set) var isUpdatingIcons = false
    private(set) var pendingVerifications = 0
    struct Icon: Identifiable, Equatable {
        let id: String
        let title: String
        let source: String?
        let section: MenuBarSection
        let isMovable: Bool
        let frame: CGRect
    }
    @Published var icons: [Icon] = []
    var stale = false
    var extra = false
    var extraRows = 0
    var assignments: [String: MenuBarSection] = [:]
    let canHideWithoutAccess = false
    let errorMessage: String? = nil
    func beginIconManagement() { refresh() }
    func endIconManagement() {}
    func requestAccess() { fatalError("Must not request permission") }
    func copyMenuBarReport() { fatalError("Must not write the pasteboard") }
    func canMove(_ icon: Icon, toward direction: MoveDirection) -> Bool { true }
    func move(_ icon: Icon, toward direction: MoveDirection) {
        onMove?(direction == .towardDrawer ? "left" : "right")
    }
    var labels: [[String: String]] = []
    var isTrusted: Bool { AXIsProcessTrusted() }
    var section: MenuBarSection = .shown
    var onMove: ((String) -> Void)?
    var onVerification: (() -> Void)?
    func refresh() {
        icons = []
        labels = []
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.flux.menu-drag-fixture")
        guard apps.count == 1, let app = apps.first else { return }
        let owner = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(owner, 0.15)
        guard let bar = read(owner, kAXExtrasMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID(),
              let children = read(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] else { return }
        for (index, child) in children.enumerated() {
            func text(_ key: String) -> String? {
                guard let raw = read(child, key) as? String else { return nil }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            let title = text(kAXTitleAttribute) ?? text(kAXDescriptionAttribute) ?? app.localizedName ?? "fixture"
            labels.append(["rawTitle": read(child, kAXTitleAttribute) as? String ?? "<nil>",
                           "description": read(child, kAXDescriptionAttribute) as? String ?? "<nil>",
                           "normalized": title])
            guard let p = read(child, kAXPositionAttribute), let s = read(child, kAXSizeAttribute) else { continue }
            var point = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
                  AXValueGetValue(s as! AXValue, .cgSize, &size) else { continue }
            icons.append(Icon(id: "com.flux.menu-drag-fixture|\(index)", title: stale ? "Replaced item" : title,
                              source: app.localizedName, section: assignments["com.flux.menu-drag-fixture|\(index)"] ?? .shown, isMovable: true,
                              frame: CGRect(origin: point, size: size)))
        }
        if extra {
            icons.append(Icon(id: "fixed|0", title: "New fixed item", source: "System", section: .shown,
                              isMovable: false, frame: .zero))
        }
        icons += (0..<extraRows).map { index in
            Icon(id: "fixed|\(index)", title: "Other item \(index)", source: "System", section: .shown,
                 isMovable: false, frame: .zero)
        }
        icons.sort { $0.title == "Flux drag fixture" && $1.title != "Flux drag fixture" }
    }
    func move(_ icon: Icon, to destination: MenuBarSection) {
        beginVerification(after: 0.45)
        assignments[icon.id] = destination
        refresh()
        onMove?(destination.rawValue)
    }
    func beginVerification(after delay: Double) {
        pendingVerifications += 1
        if pendingVerifications == 1 { isUpdatingIcons = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.onVerification?()
            self.refresh()
            self.pendingVerifications -= 1
            if self.pendingVerifications == 0 { self.isUpdatingIcons = false }
        }
    }
    private func read(_ item: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, key as CFString, &value) == .success else { return nil }
        return value
    }
}

@MainActor
func fixture(seconds: Double, emptyTitle: Bool) {
    NSApp.setActivationPolicy(.accessory)
    let a = NSStatusBar.system.statusItem(withLength: 36)
    a.button?.title = "FXD"
    a.button?.setAccessibilityTitle(emptyTitle ? "" : "Flux drag fixture")
    if emptyTitle { a.button?.setAccessibilityLabel("Flux drag fixture") }
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        NSStatusBar.system.removeStatusItem(a)
        exit(0)
    }
    NSApp.run()
}
func drive(statePath: String, source: String, destination: String, kind: String) {
    print("driver pid=\(ProcessInfo.processInfo.processIdentifier)")
    fflush(stdout)
    guard CGPreflightPostEventAccess(),
          let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
          let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let start = state[source] as? [Double], start.count == 2,
          let targets = state["targets"] as? [String: [Double]],
          var target = kind == "scroll" ? state["scrollEdge"] as? [Double] : targets[destination],
          target.count == 2 else { exit(6) }
    print("driver source=\(source) start=\(start) neighbor=\(String(describing: state["neighbor"])) destination=\(destination) target=\(target) kind=\(kind)")
    fflush(stdout)
    let command = kind == "held" || kind == "rapid" || kind == "down-only"
    let eventOffset = (state["events"] as? [String] ?? []).count
    func events() -> [String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = state["events"] as? [String] else { return [] }
        return Array(values.dropFirst(eventOffset))
    }
    func waitFor(_ predicate: ([String]) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            if predicate(events()) { return true }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        return false
    }
    func key(_ code: CGKeyCode, _ down: Bool, _ flags: CGEventFlags = []) {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
    func mouse(_ type: CGEventType, _ point: [Double], _ flags: CGEventFlags = []) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type,
                            mouseCursorPosition: CGPoint(x: point[0], y: point[1]), mouseButton: .left)!
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
    func fail(_ reason: String) -> Never {
        print("FAIL driver \(reason): \(events())")
        key(53, true); key(53, false)
        Thread.sleep(forTimeInterval: 0.12)
        mouse(.leftMouseUp, target)
        key(55, false)
        fflush(stdout)
        exit(7)
    }
    mouse(.mouseMoved, start)
    Thread.sleep(forTimeInterval: 0.12)
    if command && kind != "down-only" {
        key(55, true, .maskCommand)
        if kind == "held" { Thread.sleep(forTimeInterval: 0.25) }
    }
    mouse(.leftMouseDown, start, command ? .maskCommand : [])
    Thread.sleep(forTimeInterval: 0.06)
    if kind == "late-command" { key(55, true, .maskCommand) }
    for step in 1...24 {
        let fraction = Double(step) / 24
        let point = [start[0] + (target[0] - start[0]) * fraction,
                     start[1] + (target[1] - start[1]) * fraction]
        mouse(.leftMouseDragged, point, command || kind == "late-command" ? .maskCommand : [])
        Thread.sleep(forTimeInterval: 0.018)
    }
    if kind == "scroll" {
        let deadline = Date().addingTimeInterval(8)
        var revealed = false
        while Date() < deadline {
            mouse(.leftMouseDragged, target)
            Thread.sleep(forTimeInterval: 0.08)
            if let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
               let current = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let visibleTarget = current["scrollTarget"] as? [Double], visibleTarget.count == 2 {
                target = visibleTarget
                revealed = true
                break
            }
        }
        guard revealed else { fail("drag did not scroll to the offscreen Always Hidden lane") }
        mouse(.leftMouseDragged, target)
    }
    Thread.sleep(forTimeInterval: 0.15)
    if !command && kind != "late-command" && kind != "busy" && destination != "invalid" {
        let section = destination.replacingOccurrences(of: "-header", with: "")
        let valid = kind != "disabled"
        guard waitFor({ $0.contains("entered \(section) valid=\(valid)") }) else {
            fail("destination never accepted the session")
        }
    }
    if kind == "inventory-cancel" {
        FileManager.default.createFile(atPath: statePath + ".update", contents: Data())
        Thread.sleep(forTimeInterval: 0.2)
    }
    if kind == "stale" { FileManager.default.createFile(atPath: statePath + ".stale", contents: Data()) }
    if kind == "close" { FileManager.default.createFile(atPath: statePath + ".close", contents: Data()) }
    if kind == "stale" || kind == "close" { Thread.sleep(forTimeInterval: 0.15) }
    if kind == "escape" || kind == "inventory-cancel" {
        key(53, true); key(53, false)
        guard waitFor({ $0.contains("ended operation=0") }) else { fail("Escape did not end the session") }
    }
    mouse(.leftMouseUp, target, command || kind == "late-command" ? .maskCommand : [])
    key(55, false)
    Thread.sleep(forTimeInterval: 0.35)
}


@MainActor final class Probe {
    let manager = MenuBarIconManager()
    let settings = SettingsStore()
    let state: String
    var window: NSWindow!
    var events: [String] = []
    var commits: [String] = []
    var timer: Timer?
    var configured = false
    var menuChecked = false
    init(state: String) { self.state = state }
    func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap { views($0) } }
    func center(_ view: NSView, x: CGFloat? = nil, y: CGFloat? = nil) -> [Double] {
        let local = NSPoint(x: x ?? view.bounds.midX, y: y ?? view.bounds.midY)
        let point = window.convertPoint(toScreen: view.convert(local, to: nil))
        return [Double(point.x), Double(NSScreen.screens.first!.frame.maxY - point.y)]
    }
    func writeState() {
        let all = views(window.contentView!)
        let lanes = all.compactMap { $0 as? MenuBarIconLaneView }
        let sources = all.compactMap { $0 as? MenuBarDragSourceView }
        let source = sources.first { $0.icon?.title == "Flux drag fixture" }
        let clip = source?.enclosingScrollView?.contentView
        var ancestors: [String] = []
        var ancestor = lanes.first?.superview
        while let view = ancestor, ancestors.count < 30 {
            ancestors.append(String(describing: type(of: view)))
            ancestor = view.superview
        }
        if let controller = lanes.first?.controller, !configured {
            controller.trace = { [weak self] event in self?.events.append(event) }
            configured = true
        }
        var targets: [String: [Double]] = ["invalid": [30, 650]]
        var scrollTarget: [Double] = []
        for lane in lanes {
            targets[lane.section.rawValue] = center(lane, x: lane.bounds.width - 12, y: lane.bounds.height - 12)
            targets[lane.section.rawValue + "-header"] = center(lane, x: 30, y: 16)
            let visible = lane.visibleRect.intersection(lane.bounds)
                .intersection(lane.convert(window.contentView!.bounds, from: window.contentView!))
            if lane.section == .alwaysHidden, !visible.isNull, visible.height >= 60 {
                scrollTarget = center(lane, x: visible.midX, y: visible.midY)
            }
        }
        var tapCount: UInt32 = 0
        guard CGGetEventTapList(0, nil, &tapCount) == .success, tapCount < 2048 else { exit(10) }
        var taps = [CGEventTapInformation](repeating: .init(), count: Int(tapCount) + 8)
        let result = taps.withUnsafeMutableBufferPointer { CGGetEventTapList(UInt32($0.count), $0.baseAddress, &tapCount) }
        guard result == .success, Int(tapCount) <= taps.count else { exit(10) }
        let ownTaps = taps.prefix(Int(tapCount)).filter { $0.tappingProcess == getpid() }.count
        let value: [String: Any] = [
            "ready": configured && source != nil && lanes.count == 3 && NSApp.isActive && window.isKeyWindow,
            "row": source.map { center($0, x: $0.bounds.width * 0.7) } ?? [],
            "sourceWidth": Double(source?.bounds.width ?? 0), "targets": targets,
            "scrollEdge": clip.map { center($0, y: $0.isFlipped ? $0.bounds.maxY - 12 : $0.bounds.minY + 12) } ?? [],
            "scrollTarget": scrollTarget,
            "laneAncestors": ancestors,
            "nativeScrollViews": all.filter { $0 is NSScrollView }.count,
            "windowFrame": NSStringFromRect(window.frame),
            "usableScreen": NSStringFromRect(window.screen?.visibleFrame ?? .zero),
            "sourceIDs": sources.compactMap { $0.icon?.id }.sorted(),
            "managerIDs": manager.icons.map(\.id).sorted(),
            "menu": lanes.flatMap(\.subviews).compactMap { $0 as? NSPopUpButton }.first(where: \.isEnabled).map { center($0) } ?? [],
            "events": events, "commits": commits,
            "moving": lanes.first?.controller?.isDragging == true,
            "busy": manager.isUpdatingIcons, "buttons": NSEvent.pressedMouseButtons,
            "focusedMenu": (window.firstResponder as? NSPopUpButton).map {
                $0.isEnabled && $0.superview is MenuBarIconLaneView
            } ?? false,
            "keyboardAccess": NSApp.isFullKeyboardAccessEnabled,
            "firstResponder": String(describing: window.firstResponder).prefix(300).description,
            "ownTaps": ownTaps, "extraWindows": NSApp.windows.filter { $0 !== window && $0.isVisible }.count,
            "emptyTitle": manager.labels.contains { $0["rawTitle"] == "" && $0["normalized"] == "Flux drag fixture" }
        ]
        try! JSONSerialization.data(withJSONObject: value).write(to: URL(fileURLWithPath: state), options: .atomic)
    }
    func start(seconds: Double) {
        guard AXIsProcessTrusted() else { print("BLOCKED: existing AX access is required"); exit(3) }
        NSApp.setActivationPolicy(.regular)
        manager.onMove = { [weak self] section in self?.commits.append(section) }
        settings.showAlwaysHiddenSection = true
        if CommandLine.arguments.contains("--scroll") { manager.extraRows = 40 }
        if CommandLine.arguments.contains("--disabled-populated") {
            manager.assignments["com.flux.menu-drag-fixture|0"] = .alwaysHidden
        }
        let usable = NSScreen.main!.visibleFrame
        window = NSWindow(contentRect: NSRect(x: 80, y: 90, width: 620, height: min(620, usable.height - 40)),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.autorecalculatesKeyViewLoop = true
        window.title = "Flux Settings drag probe"
        let root = ScrollView { MenuBarTab().environmentObject(settings).environmentObject(manager) }
        window.contentView = NSHostingView(rootView: root)
        window.setFrameTopLeftPoint(NSPoint(x: usable.midX - window.frame.width / 2, y: usable.maxY - 8))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if FileManager.default.fileExists(atPath: self.state + ".stale") {
                    try? FileManager.default.removeItem(atPath: self.state + ".stale")
                    self.manager.stale = true
                }
                if FileManager.default.fileExists(atPath: self.state + ".menu") {
                    try? FileManager.default.removeItem(atPath: self.state + ".menu")
                    self.checkMenu()
                }
                if FileManager.default.fileExists(atPath: self.state + ".show-always") {
                    try? FileManager.default.removeItem(atPath: self.state + ".show-always")
                    self.settings.showAlwaysHiddenSection = true
                }
                if FileManager.default.fileExists(atPath: self.state + ".update") {
                    try? FileManager.default.removeItem(atPath: self.state + ".update")
                    self.manager.extra = true
                    self.manager.refresh()
                }
                if FileManager.default.fileExists(atPath: self.state + ".busy") {
                    try? FileManager.default.removeItem(atPath: self.state + ".busy")
                    self.manager.beginVerification(after: 2)
                }
                if FileManager.default.fileExists(atPath: self.state + ".reset") {
                    try? FileManager.default.removeItem(atPath: self.state + ".reset")
                    self.manager.stale = false
                    self.manager.refresh()
                }
                if FileManager.default.fileExists(atPath: self.state + ".close") {
                    try? FileManager.default.removeItem(atPath: self.state + ".close")
                    self.window.performClose(nil)
                }
                if FileManager.default.fileExists(atPath: self.state + ".stop") { self.stop() }
                self.writeState()
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { self.stop() }
        NSApp.run()
    }
    func checkMenu() {
        guard !menuChecked else { return }
        menuChecked = true
        settings.showAlwaysHiddenSection = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let all = self.views(self.window.contentView!)
            guard let popup = all.compactMap({ $0 as? NSPopUpButton }).first(where: {
                $0.isEnabled && $0.superview is MenuBarIconLaneView
            }),
                  let menu = popup.menu,
                  let item = menu.items.first(where: { $0.title == "Always Hidden" }), !item.isEnabled,
                  let hidden = menu.items.first(where: { $0.title == "Hidden" }), hidden.isEnabled else {
                print("FAIL: disabled Always Hidden is an active Move destination"); exit(11)
            }
            self.events.append("menu ready")
        }
    }
    func stop() {
        timer?.invalidate()
        let controller = views(window.contentView!).compactMap { ($0 as? MenuBarIconLaneView)?.controller }.first
        controller?.close()
        writeState()
        print("STOP buttons=\(NSEvent.pressedMouseButtons)")
        fflush(stdout)
        exit(0)
    }
}

@main struct Main {
    @MainActor static func main() {
        let args = CommandLine.arguments
        switch args[1] {
        case "--fixture":
            let _ = NSApplication.shared
            fixture(seconds: Double(args[2])!, emptyTitle: args.contains("--empty-title"))
        case "--drive": drive(statePath: args[2], source: args[3], destination: args[4], kind: args[5])
        case "--keyboard":
            func key(_ code: CGKeyCode) {
                CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
                CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
                Thread.sleep(forTimeInterval: 0.1)
            }
            var focused = false
            for _ in 0..<24 {
                key(48)
                if let data = try? Data(contentsOf: URL(fileURLWithPath: args[2])),
                   let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   state["focusedMenu"] as? Bool == true { focused = true; break }
            }
            guard focused else {
                print("FAIL: Tab did not reach an enabled Move popup")
                print((try? String(contentsOfFile: args[2], encoding: .utf8)) ?? "missing state")
                exit(12)
            }
            key(49)
            if args[3] == "hidden" { key(4) }
            else { key(119); if args[3] == "left" { key(126) } }
            key(36)
        case "--menu":
            let data = try! Data(contentsOf: URL(fileURLWithPath: args[2]))
            let state = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            let point = state["menu"] as! [Double]
            let location = CGPoint(x: point[0], y: point[1])
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: .left)?.post(tap: .cghidEventTap)
                Thread.sleep(forTimeInterval: 0.1)
            }
            Thread.sleep(forTimeInterval: 0.2)
            for code in [CGKeyCode(4), 36] {
                CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
                CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
                Thread.sleep(forTimeInterval: 0.1)
            }
        case "--release":
            let point = CGEvent(source: nil)!.location
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: false)?.post(tap: .cghidEventTap)
        default:
            let _ = NSApplication.shared
            Probe(state: args[2]).start(seconds: Double(args[3])!)
        }
    }
}
'''

def stop(process):
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            continue


def bounded(argv, seconds, log):
    with log.open("wb") as output:
        process = subprocess.Popen(argv, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=seconds)
            if code:
                raise RuntimeError(f"exit {code}: {log}\n{log.read_text(errors='replace')[-6000:]}")
        except subprocess.TimeoutExpired as error:
            raise RuntimeError(f"deadline {seconds}s: {log}\n{log.read_text(errors='replace')[-6000:]}") from error
        finally:
            stop(process)


def read_state(path, process, predicate=lambda value: value.get("ready"), seconds=12):
    deadline = time.monotonic() + seconds
    value = {}
    while time.monotonic() < deadline:
        try:
            value = json.loads(path.read_text())
            if predicate(value):
                return value
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        if process.poll() is not None:
            raise RuntimeError(f"probe exited {process.returncode}; see probe.log")
        time.sleep(0.03)
    raise RuntimeError(f"state deadline: {value}")


@contextmanager
def keyboard_navigation():
    if os.environ.get("GITHUB_ACTIONS") != "true":
        yield
        return
    domain = plistlib.loads(run(["/usr/bin/defaults", "export", "-g", "-"], 10).encode())
    before = domain.get("AppleKeyboardUIMode")
    if before is not None and (type(before) is not int or before not in range(4)):
        raise RuntimeError("unexpected keyboard navigation preference; no change made")
    run(["/usr/bin/defaults", "write", "-g", "AppleKeyboardUIMode", "-int", "3"], 10)
    try:
        yield
    finally:
        if before is None:
            run(["/usr/bin/defaults", "delete", "-g", "AppleKeyboardUIMode"], 10)
        else:
            run(["/usr/bin/defaults", "write", "-g", "AppleKeyboardUIMode", "-int", str(before)], 10)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--compile-only", action="store_true")
    parser.add_argument("--case", default="all", choices=("all", "row-hidden", "row-shown", "row-always",
                        "escape", "invalid", "late-command", "busy", "inventory-cancel", "menu", "disabled-populated", "scroll", "keyboard", "order-left", "order-right", "stale", "close"))
    parser.add_argument("--empty-title", action="store_true")
    parser.add_argument("--seconds", type=int, default=55, choices=range(25, 91))
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise RuntimeError("requires native macOS AppKit; no source-only pass")
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    root = Path(__file__).resolve().parents[1]
    stub = args.output / "Dependencies.swift"
    scaffold = DEPENDENCIES[:DEPENDENCIES.index("// This records calls")]
    scaffold += """
private struct MenuBarSnapshotIconsKey: EnvironmentKey {
    static let defaultValue: [MenuBarIconManager.Icon]? = nil
}
extension EnvironmentValues {
    var menuBarSnapshotIcons: [MenuBarIconManager.Icon]? {
        get { self[MenuBarSnapshotIconsKey.self] }
        set { self[MenuBarSnapshotIconsKey.self] = newValue }
    }
}
"""
    stub.write_text(scaffold)
    swift = args.output / "Probe.swift"
    swift.write_text(SWIFT)
    app = args.output / "FluxMenuDragProbe.app"
    binary = app / "Contents/MacOS/FluxMenuDragProbe"
    binary.parent.mkdir(parents=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "com.flux.menu-drag-probe", "CFBundleExecutable": binary.name,
        "CFBundleName": "Flux Settings drag probe", "LSUIElement": False,
    }))
    sources = ["MenuBar/MenuBarDragController.swift", "MenuBar/MenuBarSection.swift",
               "MenuBar/MenuBarIconStyle.swift", "Settings/Tabs/MenuBarTab.swift",
               "Settings/MenuBarIconDropZone.swift", "Settings/SettingsRows.swift", "Support/Theme.swift"]
    bounded(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", str(swift), str(stub),
             *[str(root / "Sources/Flux" / path) for path in sources], "-o", str(binary)],
            90, args.output / "build.log")
    if args.compile_only:
        return
    fixture_app = args.output / "FluxDragFixture.app"
    shutil.copytree(app, fixture_app)
    fixture_binary = fixture_app / "Contents/MacOS" / binary.name
    info_path = fixture_app / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info.update(CFBundleIdentifier="com.flux.menu-drag-fixture", CFBundleName="Flux drag fixture", LSUIElement=True)
    info_path.write_bytes(plistlib.dumps(info))
    state_path = args.output / "state.json"
    processes = []
    results = []
    with keyboard_navigation():
        try:
            for argv, name in (([str(fixture_binary), "--fixture", str(args.seconds + 5)] +
                                 (["--empty-title"] if args.empty_title else []), "fixture.log"),
                               ([str(binary), "--probe", str(state_path), str(args.seconds)] +
                                (["--" + args.case] if args.case in ("disabled-populated", "scroll") else []), "probe.log")):
                with (args.output / name).open("wb") as log:
                    processes.append(subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT, start_new_session=True))
            probe_process = processes[-1]
            state = read_state(state_path, probe_process)
            if state["sourceWidth"] < 180 or state["ownTaps"] or state["extraWindows"]:
                raise RuntimeError(f"wrong drag area or unexpected global capture: {state}")
            if args.empty_title and not state["emptyTitle"]:
                raise RuntimeError("empty AX title fallback was not exercised")
            started = time.monotonic()
            if args.case == "scroll":
                if state["scrollTarget"]:
                    raise RuntimeError("scroll fixture did not put the destination below the viewport")
                bounded([str(binary), "--drive", str(state_path), "row", "alwaysHidden", "scroll"], 13,
                        args.output / "scroll.log")
                state = read_state(state_path, probe_process, lambda value: not value["moving"] and not value["busy"] and not value["buttons"])
                if state["commits"] != ["alwaysHidden"]:
                    raise RuntimeError("offscreen lane drop did not request Always Hidden exactly once")
                results.append("PASS drag scrolls a 41-item editor to an offscreen destination")
            scenarios = [("row-hidden", "hidden-header", "normal", "hidden"), ("row-shown", "shown", "normal", "shown"),
                         ("row-always", "alwaysHidden", "normal", "alwaysHidden"), ("escape", "hidden", "escape", None),
                         ("invalid", "invalid", "normal", None), ("late-command", "hidden", "late-command", None),
                         ("busy", "hidden", "busy", None), ("inventory-cancel", "hidden", "inventory-cancel", None)]
            for index, (label, target, kind, expected) in enumerate(scenarios):
                if args.case not in ("all", label):
                    continue
                if kind == "busy":
                    Path(str(state_path) + ".busy").touch()
                    state = read_state(state_path, probe_process, lambda value: value["busy"])
                if time.monotonic() - started > args.seconds - 15:
                    raise RuntimeError("scenario deadline")
                before = len(state["commits"])
                offset = len(state["events"])
                bounded([str(binary), "--drive", str(state_path), "row", target, kind], 8,
                        args.output / f"drive-{index}.log")
                state = read_state(state_path, probe_process,
                                   lambda value: not value["moving"] and not value["busy"] and not value["buttons"])
                events = state["events"][offset:]
                begins = [event for event in events if event.startswith("begin ")]
                if len(begins) != (0 if kind in ("late-command", "busy") else 1):
                    raise RuntimeError(f"{target}/{kind}: wrong drag callback count: {events}")
                actual = state["commits"][before:]
                if actual != ([expected] if expected else []):
                    raise RuntimeError(f"{target}/{kind}: commits={actual}; events={state['events'][offset:]}")
                if state["ownTaps"] or state["extraWindows"]:
                    raise RuntimeError("Settings drag installed global capture or an extra window")
                if kind == "inventory-cancel":
                    state = read_state(state_path, probe_process, lambda value: value["sourceIDs"] == value["managerIDs"])
                    if "fixed|0" not in state["sourceIDs"]:
                        raise RuntimeError("inventory did not change during the cancelled drag")
                results.append(f"PASS text-area drag to {target}, {kind}")
            if args.case in ("all", "menu", "disabled-populated"):
                # Return to Shown before checking the actual native fallback menu.
                if args.case != "disabled-populated":
                    bounded([str(binary), "--drive", str(state_path), "row", "shown", "normal"], 8,
                            args.output / "restore.log")
                    state = read_state(state_path, probe_process, lambda value: not value["moving"] and not value["busy"])
                before = len(state["commits"])
                Path(str(state_path) + ".menu").touch()
                state = read_state(state_path, probe_process, lambda value: "menu ready" in value["events"])
                if args.case == "disabled-populated":
                    bounded([str(binary), "--drive", str(state_path), "row", "alwaysHidden", "disabled"], 8,
                            args.output / "disabled-drop.log")
                    state = read_state(state_path, probe_process, lambda value: not value["moving"] and not value["buttons"])
                    if len(state["commits"]) != before or "com.flux.menu-drag-fixture|0" not in state["sourceIDs"]:
                        raise RuntimeError("disabled populated lane accepted a drop or lost its item")
                bounded([str(binary), "--menu", str(state_path)], 5, args.output / "menu-click.log")
                state = read_state(state_path, probe_process, lambda value: len(value["commits"]) > before)
                if state["commits"][before:] != ["hidden"]:
                    raise RuntimeError("Move menu did not request Hidden")
                results.append("PASS native Move popup requests Hidden and disables Always Hidden while off")
                Path(str(state_path) + ".show-always").touch()
                state = read_state(state_path, probe_process, lambda value: value["ready"] and not value["busy"])
            for label, expected in (("keyboard", "hidden"), ("order-left", "left"), ("order-right", "right")):
                if args.case not in ("all", label):
                    continue
                before = len(state["commits"])
                bounded([str(binary), "--keyboard", str(state_path), expected], 7,
                        args.output / (label + ".log"))
                state = read_state(state_path, probe_process, lambda value: len(value["commits"]) > before)
                if state["commits"][before:] != [expected]:
                    raise RuntimeError(f"keyboard {label} requested {state['commits'][before:]}")
                state = read_state(state_path, probe_process, lambda value: not value["busy"])
                results.append(f"PASS keyboard-only Move {expected}")
            for index, kind in enumerate(("stale", "close")):
                if args.case not in ("all", kind):
                    continue
                before = len(state["commits"])
                offset = len(state["events"])
                bounded([str(binary), "--drive", str(state_path), "row", "shown", kind], 8,
                        args.output / f"reject-{kind}.log")
                state = read_state(state_path, probe_process, lambda value: not value["moving"] and not value["buttons"])
                events = state["events"][offset:]
                if len(state["commits"]) != before or len([event for event in events if event.startswith("begin ")]) != 1:
                    raise RuntimeError(f"{kind} drag was not exercised or committed a move: {events}")
                results.append(f"PASS {kind} drag made no move")
                if kind == "stale":
                    Path(str(state_path) + ".reset").touch()
                    state = read_state(state_path, probe_process)
            Path(str(state_path) + ".stop").touch()
            probe_process.wait(timeout=3)
            if probe_process.returncode or "STOP buttons=0" not in (args.output / "probe.log").read_text():
                raise RuntimeError("probe did not stop with mouse buttons released")
            print("\n".join(results))
            (args.output / "result.json").write_text(json.dumps({"results": results, "state": state}, indent=2))
        finally:
            try:
                bounded([str(binary), "--release"], 3, args.output / "release.log")
            except (RuntimeError, OSError):
                pass
            for process in reversed(processes):
                stop(process)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(128 + signum))
    try:
        main()
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
