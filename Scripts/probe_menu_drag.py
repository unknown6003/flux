#!/usr/bin/env python3
"""Bounded native drag probe. Uses the production controller and a move recorder.

No TCC writes, permission prompts, installed-app changes, or real icon moves.
The two disposable status items are removed when their process exits. Native
Command tests reorder only those items. Existing AX and event-post access are
required for the probe identity. A denied probe does not test Flux's grant.
"""

import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import time


SWIFT = r'''
import AppKit
import ApplicationServices
import Combine

enum ControlItem {
    static var usesMacOS27Model: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }
}

@MainActor
final class MenuBarIconManager {
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
    var icons: [Icon] = []
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
            icons.append(Icon(id: "com.flux.menu-drag-fixture|\(index)", title: title,
                              source: app.localizedName, section: section, isMovable: true,
                              frame: CGRect(origin: point, size: size)))
        }
        icons.sort { $0.title == "Flux drag fixture" && $1.title != "Flux drag fixture" }
    }
    func move(_ icon: Icon, to destination: MenuBarSection) {
        beginVerification(after: 0.45)
        section = destination
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
final class Probe {
    let controller = MenuBarDragController()
    let manager = MenuBarIconManager()
    var window: NSWindow!
    var row: MenuBarDragSourceView?
    var events: [String] = []
    var commits: [String] = []
    let state: String
    var timer: Timer?
    var screenObserver: NSObjectProtocol?
    var screenSnapshot: [String: Any] = [:]
    var screenRecords: [[String: Any]] = []
    var lastScreenNotification = -Double.infinity
    let busyOnly: Bool
    init(state: String, busyOnly: Bool) { self.state = state; self.busyOnly = busyOnly }
    func screens() -> [String: Any] {
        func rect(_ value: CGRect) -> [Double] {
            [Double(value.minX), Double(value.minY), Double(value.width), Double(value.height)]
        }
        return ["statusBarHeight": Double(NSStatusBar.system.thickness),
                "presentationOptions": NSApp.presentationOptions.rawValue,
                "screens": NSScreen.screens.map { screen -> [String: Any] in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            var value: [String: Any] = ["displayID": id, "frame": rect(screen.frame),
                "visibleFrame": rect(screen.visibleFrame), "scale": Double(screen.backingScaleFactor),
                "safeArea": [Double(screen.safeAreaInsets.top), Double(screen.safeAreaInsets.left),
                             Double(screen.safeAreaInsets.bottom), Double(screen.safeAreaInsets.right)],
                "cgBounds": rect(CGDisplayBounds(id)), "pixels": [CGDisplayPixelsWide(id), CGDisplayPixelsHigh(id)],
                "active": CGDisplayIsActive(id) != 0, "main": CGDisplayIsMain(id) != 0,
                "asleep": CGDisplayIsAsleep(id) != 0]
            if let mode = CGDisplayCopyDisplayMode(id) {
                value["mode"] = ["id": Double(mode.ioDisplayModeID), "width": Double(mode.width),
                    "height": Double(mode.height), "pixelWidth": Double(mode.pixelWidth),
                    "pixelHeight": Double(mode.pixelHeight), "refreshRate": mode.refreshRate]
            }
            return value
        }]
    }
    func signature(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "<invalid snapshot>" }
        return text
    }
    func recordScreens(_ event: String, after: [String: Any]) {
        let same = signature(screenSnapshot) == signature(after)
        screenRecords.append(["event": event, "uptime": ProcessInfo.processInfo.systemUptime,
                              "sameConfiguration": same, "before": screenSnapshot, "after": after,
                              "mode": controller.isMenuBarDragging,
                              "appActive": NSApp.isActive, "keyWindow": NSApp.keyWindow?.windowNumber ?? -1])
        screenSnapshot = after
        if let data = try? JSONSerialization.data(withJSONObject: screenRecords, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: state + ".screens.json"), options: .atomic)
        }
        print("SCREEN event=\(event) t=\(ProcessInfo.processInfo.systemUptime) sameConfiguration=\(same) mode=\(controller.isMenuBarDragging)")
        fflush(stdout)
    }
    func start(seconds: Double) {
        guard AXIsProcessTrusted() else {
            print("BLOCKED: probe identity lacks existing Accessibility access; no permission was requested")
            exit(3)
        }
        NSApp.setActivationPolicy(.regular)
        recordScreens("launch", after: screens())
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.lastScreenNotification = ProcessInfo.processInfo.systemUptime
                    self.recordScreens("notification", after: self.screens())
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.recordScreens("notification next turn", after: self.screens())
                    }
                }
            }
        window = NSWindow(contentRect: NSRect(x: 100, y: 160, width: 620, height: 300),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Flux native menu drag probe"
        window.isReleasedWhenClosed = false
        window.center()
        let content = window.contentView!
        for (i, section) in MenuBarSection.allCases.enumerated() {
            let target = MenuBarDragDestinationView(frame: NSRect(x: 20 + i * 200, y: 25, width: 180, height: 170))
            target.controller = controller
            target.section = section
            target.wantsLayer = true
            target.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
            let label = NSTextField(labelWithString: section.displayName)
            label.frame = NSRect(x: 8, y: 130, width: 160, height: 24)
            target.addSubview(label)
            content.addSubview(target)
        }
        controller.trace = { [weak self] value in
            self?.events.append(value)
            if value.hasPrefix("stop reason=screen changed"), let self {
                self.recordScreens("controller screen guard", after: self.screens())
            }
            print("t=\(ProcessInfo.processInfo.systemUptime) \(value)"); fflush(stdout)
        }
        manager.onMove = { [weak self] value in self?.commits.append(value) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let activationDeadline = ProcessInfo.processInfo.systemUptime + 8
        var retriedActivation = false
        var stableSince = ProcessInfo.processInfo.systemUptime
        var lastConfiguration = signature(screenSnapshot)
        var lastFixture = ""
        var enabledAt: Double?
        var enabledConfiguration = ""
        let readiness = Timer(timeInterval: 0.1, repeats: true) { readiness in
            MainActor.assumeIsolated {
            let now = ProcessInfo.processInfo.systemUptime
            let configuration = self.screens()
            let currentConfiguration = self.signature(configuration)
            if currentConfiguration != lastConfiguration {
                self.recordScreens("readiness geometry changed", after: configuration)
                lastConfiguration = currentConfiguration
                stableSince = now
            }
            guard now < activationDeadline else {
                let front = NSWorkspace.shared.frontmostApplication
                print("BLOCKED readiness deadline active=\(NSApp.isActive) key=\(NSApp.keyWindow?.windowNumber ?? -1) settings=\(self.window.windowNumber) front=\(front?.processIdentifier ?? -1)")
                fflush(stdout)
                self.recordScreens("BLOCKED readiness deadline", after: configuration)
                self.controller.close()
                readiness.invalidate()
                exit(5)
            }
            if let enabledAt {
                guard self.controller.isMenuBarDragging, currentConfiguration == enabledConfiguration else {
                    self.recordScreens("BLOCKED armed readiness invalidated", after: configuration)
                    self.controller.close()
                    readiness.invalidate()
                    exit(5)
                }
                guard now - enabledAt >= 1 else { return }
                readiness.invalidate()
                self.recordScreens("ready for input", after: configuration)
                self.writeState()
                let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        if FileManager.default.fileExists(atPath: self.state + ".stop") { self.stop() }
                        self.writeState()
                    }
                }
                self.timer = timer
                RunLoop.main.add(timer, forMode: .common)
                if self.busyOnly { self.runBusyProbe() }
                return
            }
            guard NSApp.isActive, NSApp.keyWindow === self.window, self.window.isVisible else {
                stableSince = now
                if !retriedActivation && now > activationDeadline - 6 {
                    retriedActivation = true
                    print("readiness retry activation")
                    fflush(stdout)
                    NSApp.activate(ignoringOtherApps: true)
                    self.window.makeKeyAndOrderFront(nil)
                }
                return
            }
            self.manager.refresh()
            guard self.manager.icons.count == 2, let icon = self.manager.icons.first else {
                stableSince = now
                return
            }
            let fixture = self.signature(self.manager.icons.map {
                ["id": $0.id, "title": $0.title, "frame": [Double($0.frame.minX), Double($0.frame.minY),
                                                           Double($0.frame.width), Double($0.frame.height)]] as [String: Any]
            })
            if fixture != lastFixture { lastFixture = fixture; stableSince = now }
            guard now - max(stableSince, self.lastScreenNotification) >= 2 else { return }
            self.recordScreens("stable before enable", after: configuration)
            print("READY stable2s active=\(NSApp.isActive) key=\(self.window.windowNumber) pid=\(ProcessInfo.processInfo.processIdentifier)")
            print("FIXTURE labels=\(self.manager.labels)")
            fflush(stdout)
            let row = self.controller.makeSourceView(for: icon)
            row.showsHandle = true
            row.frame = NSRect(x: 24, y: 230, width: 140, height: 32)
            content.addSubview(row)
            self.row = row
            self.controller.open(manager: self.manager, window: self.window)
            self.controller.setMenuBarDragging(true)
            guard self.controller.isMenuBarDragging else {
                print("BLOCKED: \(self.controller.message ?? "event tap unavailable")"); exit(5)
            }
            enabledAt = now
            enabledConfiguration = currentConfiguration
            self.recordScreens("enabled awaiting quiet1s", after: self.screens())
            }
        }
        RunLoop.main.add(readiness, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { self.stop() }
        NSApp.run()
    }
    func stop() {
        timer?.invalidate()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        controller.close()
        writeState()
        window.close()
        print("STOP buttons=\(NSEvent.pressedMouseButtons)")
        fflush(stdout)
        exit(0)
    }
    func writeState() {
        if let icon = manager.icons.first { row?.icon = icon }
        guard let primary = NSScreen.screens.first else { return }
        func cg(_ point: NSPoint) -> [Double] { [Double(point.x), Double(primary.frame.maxY - point.y)] }
        func center(_ rect: NSRect) -> [Double] { cg(NSPoint(x: rect.midX, y: rect.midY)) }
        let root = window.contentView!
        var targets: [String: [Double]] = [:]
        for (i, section) in MenuBarSection.allCases.enumerated() {
            targets[section.rawValue] = cg(window.convertPoint(toScreen: NSPoint(x: 110 + i * 200, y: 90)))
        }
        let barHeight = max(NSStatusBar.system.thickness, primary.safeAreaInsets.top)
        targets["bar"] = cg(NSPoint(x: primary.frame.midX + 80, y: primary.frame.maxY - barHeight * 1.5 - 8))
        targets["invalid"] = cg(NSPoint(x: primary.frame.minX + 30, y: primary.frame.minY + 80))
        let state: [String: Any] = [
            "ready": row != nil, "pid": ProcessInfo.processInfo.processIdentifier,
            "mode": controller.isMenuBarDragging, "commits": commits, "events": events,
            "moving": manager.isUpdatingIcons, "taps": ownTapStates() ?? [],
            "labels": manager.labels,
            "buttons": NSEvent.pressedMouseButtons,
            "source": manager.icons.first.map { [Double($0.frame.midX), Double($0.frame.midY)] } ?? [],
            "row": center(window.convertToScreen(root.convert(row?.frame ?? .zero, to: nil))),
            "targets": targets,
            "screens": NSScreen.screens.map { ["x": $0.frame.minX, "y": $0.frame.minY,
                                               "width": $0.frame.width, "height": $0.frame.height] }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: self.state), options: .atomic)
        }
    }

    func runBusyProbe() {
        func check(_ busy: Bool, _ phase: String) {
            guard self.manager.isUpdatingIcons == busy, let taps = ownTapStates(), !taps.isEmpty,
                  taps.allSatisfy({ $0 == !busy }) else {
                print("FAIL busy \(phase) moving=\(self.manager.isUpdatingIcons) taps=\(ownTapStates() ?? [])")
                fflush(stdout)
                self.controller.close()
                exit(8)
            }
            print("PASS busy \(phase) moving=\(busy) taps=\(taps)")
            fflush(stdout)
        }
        check(false, "initially armed")
        manager.onVerification = {
            check(true, "before delayed AX verification")
            Thread.sleep(forTimeInterval: 0.3)
            check(true, "after bounded main-thread verification delay")
        }
        manager.beginVerification(after: 0.45)
        check(true, "synchronous willSet emission")
        manager.beginVerification(after: 1.25)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.controller.setMenuBarDragging(false)
            self.controller.setMenuBarDragging(true)
            check(true, "mode re-enabled during overlap")
            self.controller.close()
            self.controller.open(manager: self.manager, window: self.window)
            self.controller.setMenuBarDragging(true)
            check(true, "management reopened during overlap")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
            guard self.manager.pendingVerifications == 1 else {
                print("FAIL busy first verification did not leave one pending"); fflush(stdout); exit(8)
            }
            check(true, "first verification finished with overlap pending")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            check(false, "last verification finished")
            self.manager.onVerification = nil
            self.events.append("busy probe passed")
            self.writeState()
        }
    }
}

func ownTapStates() -> [Bool]? {
    var count: UInt32 = 0
    guard CGGetEventTapList(0, nil, &count) == .success, count < 2048 else { return nil }
    var entries = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count) + 8)
    let result = entries.withUnsafeMutableBufferPointer {
        CGGetEventTapList(UInt32($0.count), $0.baseAddress, &count)
    }
    guard result == .success, Int(count) <= entries.count else { return nil }
    return entries.prefix(Int(count)).filter {
        $0.tappingProcess == ProcessInfo.processInfo.processIdentifier
    }.map(\.enabled)
}

@MainActor
func fixture(seconds: Double, emptyTitle: Bool) {
    NSApp.setActivationPolicy(.accessory)
    let a = NSStatusBar.system.statusItem(withLength: 36)
    a.button?.title = "FXD"
    a.button?.setAccessibilityTitle(emptyTitle ? "" : "Flux drag fixture")
    if emptyTitle { a.button?.setAccessibilityLabel("Flux drag fixture") }
    let b = NSStatusBar.system.statusItem(withLength: 36)
    b.button?.title = "FXE"
    b.button?.setAccessibilityTitle("Flux drag neighbour")
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        NSStatusBar.system.removeStatusItem(a)
        NSStatusBar.system.removeStatusItem(b)
        exit(0)
    }
    NSApp.run()
}

func drive(statePath: String, source: String, destination: String, kind: String) {
    func trace(_ message: String) {
        print("[drop-trace] driver t=\(ProcessInfo.processInfo.systemUptime) \(message)")
        fflush(stdout)
    }
    print("driver pid=\(ProcessInfo.processInfo.processIdentifier)")
    fflush(stdout)
    guard CGPreflightPostEventAccess(),
          let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
          let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let start = state[source] as? [Double], start.count == 2,
          let targets = state["targets"] as? [String: [Double]],
          let target = destination == "native" ? [start[0] - 75, start[1]] : targets[destination] else { exit(6) }
    print("driver source=\(source) start=\(start) destination=\(destination) target=\(target) kind=\(kind)")
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
        trace("failure cleanup reason=\(reason)")
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
    trace("posting mouseDown point=\(start) command=\(command)")
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
    trace("path posted target=\(target)")
    Thread.sleep(forTimeInterval: 0.15)
    if !command && kind != "late-command" && destination != "invalid" {
        let section = destination == "bar" ? "shown" : destination
        guard waitFor({ $0.contains("entered \(section) valid=true") }) else {
            fail("destination never accepted the session")
        }
        trace("observed target entered section=\(section)")
    }
    if kind == "escape" {
        trace("posting Escape")
        key(53, true); key(53, false)
        guard waitFor({ $0.contains("ended operation=0") }) else { fail("Escape did not end the session") }
        trace("observed cancellation end")
    }
    trace("posting mouseUp target=\(target) command=\(command || kind == "late-command")")
    mouse(.leftMouseUp, target, command || kind == "late-command" ? .maskCommand : [])
    trace("posted mouseUp; posting Command keyUp")
    key(55, false)
    Thread.sleep(forTimeInterval: 0.35)
}

@main
struct Main {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if args[1] == "--fixture" { let _ = NSApplication.shared; fixture(seconds: Double(args[2])!, emptyTitle: args.contains("--empty-title")) }
        else if args[1] == "--drive" { drive(statePath: args[2], source: args[3], destination: args[4], kind: args[5]) }
        else if args[1] == "--release" {
            if CGPreflightPostEventAccess() {
                let point = CGEvent(source: nil)!.location
                CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                        mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: false)?.post(tap: .cghidEventTap)
            }
        }
        else { let _ = NSApplication.shared; Probe(state: args[2], busyOnly: args.contains("--busy-only")).start(seconds: Double(args[3])!) }
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
                raise RuntimeError(f"exit {code}: {log}")
        except subprocess.TimeoutExpired as error:
            raise RuntimeError(f"deadline {seconds}s: {log}") from error
        finally:
            stop(process)


def wait_state(path, process, seconds=12):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"probe exited {process.returncode}; see probe.log")
        try:
            state = json.loads(path.read_text())
            if state["ready"]:
                return state
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(0.1)
    raise RuntimeError(f"state readiness deadline {seconds}s: {path}")


def wait_scenario(path, process, offset, kind):
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        state = wait_state(path, process, 1)
        events = state["events"][offset:]
        ended = [event for event in events if event.startswith("ended ")]
        settled = not state["moving"] and state["buttons"] == 0
        if settled and (ended or (kind == "late-command" and "source down command=false" in events)):
            return state, events
        time.sleep(0.05)
    raise RuntimeError(f"session settle deadline for {kind}: {events}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="New scratch directory for bundles and logs")
    parser.add_argument("--compile-only", action="store_true")
    parser.add_argument("--busy-only", action="store_true", help="Test delayed shared move state without dragging")
    parser.add_argument("--case", default="all", choices=(
        "all", "row-hidden", "menu-hidden", "menu-always", "row-bar", "row-hidden-escape",
        "menu-always-escape", "row-bar-escape", "invalid", "late-command",
        "command-held", "command-rapid", "command-down-only"), help="Run one independent native scenario")
    parser.add_argument("--controller-ref", help="Compile the production controller from this Git ref for regression proof")
    parser.add_argument("--empty-title", action="store_true", help="Require the fixture's empty AXTitle fallback")
    parser.add_argument("--seconds", type=int, default=55, choices=range(25, 91), metavar="25..90")
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise RuntimeError("requires native macOS AppKit; no source-only pass")
    args.output.mkdir(parents=True, exist_ok=False)
    root = Path(__file__).resolve().parents[1]
    swift = args.output / "Probe.swift"
    swift.write_text(SWIFT)
    controller = root / "Sources/Flux/MenuBar/MenuBarDragController.swift"
    if args.controller_ref:
        source = args.output / "controller-source.swift"
        bounded(["git", "-C", str(root), "show",
                 f"{args.controller_ref}:Sources/Flux/MenuBar/MenuBarDragController.swift"],
                5, source)
        controller = source
    app = args.output / "FluxMenuDragProbe.app"
    binary = app / "Contents/MacOS/FluxMenuDragProbe"
    binary.parent.mkdir(parents=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "com.flux.menu-drag-probe", "CFBundleExecutable": binary.name,
        "CFBundleName": "Flux menu drag probe", "LSUIElement": False,
    }))
    bounded(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", "-framework", "AppKit",
             "-framework", "ApplicationServices", str(swift),
             str(controller),
             str(root / "Sources/Flux/MenuBar/MenuBarSection.swift"), "-o", str(binary)],
            45, args.output / "build.log")
    fixture_app = args.output / "FluxDragFixture.app"
    shutil.copytree(app, fixture_app)
    fixture_binary = fixture_app / "Contents/MacOS" / binary.name
    info = plistlib.loads((fixture_app / "Contents/Info.plist").read_bytes())
    info.update(CFBundleIdentifier="com.flux.menu-drag-fixture", CFBundleName="Flux drag fixture", LSUIElement=True)
    (fixture_app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    print(f"BUILT production controller from {args.controller_ref or 'working tree'}; move recorder: {app}", flush=True)
    if args.compile_only:
        return
    processes = []
    try:
        fixture_argv = [str(fixture_binary), "--fixture", str(args.seconds + 5)]
        if args.empty_title:
            fixture_argv.append("--empty-title")
        for argv, name in ((fixture_argv, "fixture.log"),
                           ([str(binary), "--probe", str(args.output / "state.json"), str(args.seconds)]
                            + (["--busy-only"] if args.busy_only else []), "probe.log")):
            with (args.output / name).open("wb") as log:
                processes.append(subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT, start_new_session=True))
        probe = processes[-1]
        state_path = args.output / "state.json"
        state = wait_state(state_path, probe)
        if args.empty_title and not any(label["rawTitle"] == "" and label["normalized"]
                                        for label in state["labels"]):
            raise RuntimeError(f"fixture did not expose an empty AXTitle: {state['labels']}")
        started = time.monotonic()
        results = []
        if args.busy_only:
            deadline = time.monotonic() + 6
            while "busy probe passed" not in state["events"] and time.monotonic() < deadline:
                time.sleep(0.05)
                state = wait_state(state_path, probe, 1)
            if "busy probe passed" not in state["events"]:
                raise RuntimeError("shared move-state probe deadline")
            results.append("PASS delayed overlapping manager moves kept the actual event tap disabled")
        scenarios = () if args.busy_only else (
            ("row-hidden", "row", "hidden", "normal", "hidden"),
            ("menu-hidden", "source", "hidden", "normal", "hidden"),
            ("menu-always", "source", "alwaysHidden", "normal", "alwaysHidden"),
            ("row-bar", "row", "bar", "normal", "shown"),
            ("row-hidden-escape", "row", "hidden", "escape", None),
            ("menu-always-escape", "source", "alwaysHidden", "escape", None),
            ("row-bar-escape", "row", "bar", "escape", None),
            ("invalid", "source", "invalid", "normal", None),
            ("late-command", "source", "hidden", "late-command", None),
        )
        for name, source, destination, kind, expected in scenarios:
            if args.case not in ("all", name):
                continue
            if time.monotonic() - started > args.seconds - 15:
                raise RuntimeError("scenario deadline; stopped all probe groups")
            before = len(state["commits"])
            event_offset = len(state["events"])
            if not state["mode"]:
                raise RuntimeError("drag mode stopped before the scenario")
            bounded([str(binary), "--drive", str(state_path), source, destination, kind],
                    8, args.output / f"drive-{len(results)}.log")
            state, events = wait_scenario(state_path, probe, event_offset, kind)
            begins = [event for event in events if event.startswith("begin ")]
            native_begins = [event for event in events if event.startswith("native began ")]
            ends = [event for event in events if event.startswith("ended ")]
            if kind == "late-command":
                if begins or native_begins or ends:
                    raise RuntimeError(f"late Command started a session: {events}")
            else:
                wanted_end = "ended operation=16" if expected else "ended operation=0"
                if len(begins) != 1 or len(native_begins) != 1 or ends != [wanted_end]:
                    raise RuntimeError(f"wrong session callbacks: {events}")
            actual = state["commits"][before:]
            wanted = [expected] if expected else []
            if actual != wanted:
                raise RuntimeError(f"{source} -> {destination} {kind}: commits {actual}, wanted {wanted}")
            results.append(f"PASS {source} -> {destination} {kind}")
        # Both keys arrive before down in these cases, with no run-loop delay in rapid.
        # Reorder only a disposable item, and require actual geometry movement.
        for kind in (() if args.busy_only else ("held", "rapid", "down-only")):
            if args.case not in ("all", f"command-{kind}"):
                continue
            state = wait_state(state_path, probe, 2)
            if not state["mode"] or not state["taps"] or not all(state["taps"]):
                raise RuntimeError("drag mode stopped before the native Command check")
            start = state["source"]
            events_before = len(state["events"])
            # The temporary bar destination exists only in Flux sessions. Native
            # Command gestures must reach the real fixture without a Flux session.
            bounded([str(binary), "--drive", str(state_path), "source", "native", kind],
                    4, args.output / f"command-{kind}.log")
            position_deadline = time.monotonic() + 4
            state = wait_state(state_path, probe, 2)
            while abs(state["source"][0] - start[0]) < 10 and time.monotonic() < position_deadline:
                time.sleep(0.05)
                state = wait_state(state_path, probe, 1)
            new_events = state["events"][events_before:]
            if not state["mode"] or "tap down command=true" not in new_events:
                raise RuntimeError(f"Command {kind} did not exercise the armed event tap")
            if any(e.startswith("source down") or e.startswith("begin ") for e in new_events):
                raise RuntimeError(f"Command {kind} was intercepted: {new_events}")
            if abs(state["source"][0] - start[0]) < 10:
                raise RuntimeError(f"Command {kind} did not move the disposable status item")
            results.append(f"PASS native Command {kind} bypass and fixture movement")
        Path(str(state_path) + ".stop").touch()
        try:
            probe.wait(timeout=3)
        except subprocess.TimeoutExpired as error:
            raise RuntimeError("graceful cleanup deadline") from error
        final = json.loads(state_path.read_text())
        if final["mode"] or "cleanup overlays=0 returns=0 tap=none" not in final["events"][-1:]:
            raise RuntimeError("controller did not clean up its windows and tap")
        if "STOP buttons=0" not in (args.output / "probe.log").read_text():
            raise RuntimeError("mouse button remained down at cleanup")
        results.append("PASS controller close removed overlays, return targets, and event tap")
        print("\n".join(results), flush=True)
        print("PASS focused controller probe only. Flux UI and real manager moves remain root checks.", flush=True)
        (args.output / "result.json").write_text(json.dumps({"results": results, "state": state}, indent=2))
    finally:
        try:
            bounded([str(binary), "--release"], 3, args.output / "release.log")
        except (RuntimeError, OSError):
            pass
        Path(str(args.output / "state.json") + ".stop").touch()
        for process in reversed(processes):
            stop(process)


def interrupted(signum, _frame):
    raise SystemExit(128 + signum)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    try:
        main()
    except (RuntimeError, OSError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
