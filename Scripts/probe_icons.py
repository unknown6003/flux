#!/usr/bin/env python3
"""Verify Settings section moves against real menu-bar icon positions."""

import argparse
import os
from pathlib import Path
import plistlib
import signal
import shutil
import subprocess
import sys
import tempfile
import time
from probe_tcc import _stop


if sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true":
    raise SystemExit("FAIL: icon moves are tested only on a disposable macOS CI desktop")


def command(arguments, seconds):
    process = subprocess.Popen(arguments, start_new_session=True)
    try:
        status = process.wait(timeout=seconds)
        if status:
            raise RuntimeError(f"FAIL: {arguments[0]} exited with {status}")
    finally:
        _stop(process)


def interrupted(signum, _frame):
    raise SystemExit(128 + signum)


signal.signal(signal.SIGTERM, interrupted)
root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--native-close", action="store_true")
parser.add_argument("--move-close", action="store_true")
parser.add_argument("--move-refresh-retry", action="store_true")
parser.add_argument("--move-refresh-failure", action="store_true")
parser.add_argument("--move-save-retry", action="store_true")
parser.add_argument("--move-save-failure", action="store_true")
parser.add_argument("--menu-context", action="store_true")
parser.add_argument("--drag-context", action="store_true")
parser.add_argument("--native-overlap", action="store_true")
parser.add_argument("--native-geometry", action="store_true")
parser.add_argument("--native-sibling", action="store_true")
parser.add_argument("--native-refresh-retry", action="store_true")
parser.add_argument("--move-overlap", action="store_true")
parser.add_argument("--manager-ref", help="Compile a committed manager with the current native fixture")
options = parser.parse_args()
fixture_source = r'''
import AppKit
if CommandLine.arguments.count == 8 && CommandLine.arguments[1] == "--drag-siblings" {
    let values = CommandLine.arguments.dropFirst(2).compactMap(Double.init)
    guard values.count == 6 else { exit(2) }
    func post(_ type: CGEventType, _ point: CGPoint) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type,
                            mouseCursorPosition: point, mouseButton: .left)!
        event.flags = .maskCommand
        event.post(tap: .cghidEventTap)
    }
    let first = CGPoint(x: values[0], y: values[1])
    let second = CGPoint(x: values[2], y: values[3])
    let target = CGPoint(x: values[4], y: values[5])
    post(.leftMouseDown, first)
    Thread.sleep(forTimeInterval: 0.08)
    for step in 1...24 {
        let distance = CGFloat(step <= 12 ? step : 24 - step) / 12 * 8
        post(.leftMouseDragged, CGPoint(x: first.x - distance, y: first.y))
        Thread.sleep(forTimeInterval: 0.02)
    }
    post(.leftMouseUp, first)
    Thread.sleep(forTimeInterval: 0.08)
    post(.leftMouseDown, second)
    Thread.sleep(forTimeInterval: 0.08)
    for step in 1...24 {
        let progress = CGFloat(step) / 24
        post(.leftMouseDragged, CGPoint(x: second.x + (target.x - second.x) * progress,
                                        y: second.y))
        Thread.sleep(forTimeInterval: 0.02)
    }
    post(.leftMouseUp, target)
    exit(0)
}
if CommandLine.arguments.count == 6 && ["--drag", "--drag-overlap", "--drag-held-return", "--drag-row"].contains(CommandLine.arguments[1]) {
    let values = CommandLine.arguments.dropFirst(2).compactMap(Double.init)
    guard values.count == 4 else { exit(2) }
    let start = CGPoint(x: values[0], y: values[1])
    let target = CGPoint(x: values[2], y: values[3])
    func post(_ type: CGEventType, _ point: CGPoint) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left) else { exit(2) }
        event.flags = CommandLine.arguments[1] == "--drag-row" ? [] : .maskCommand
        event.post(tap: .cghidEventTap)
    }
    post(.leftMouseDown, start)
    Thread.sleep(forTimeInterval: 0.08)
    let steps = 24
    for step in 1...steps {
        let progress = CGFloat(step) / CGFloat(steps)
        post(.leftMouseDragged, CGPoint(x: start.x + (target.x - start.x) * progress,
                                        y: start.y + (target.y - start.y) * progress))
        Thread.sleep(forTimeInterval: 0.02)
    }
    if CommandLine.arguments[1] == "--drag-overlap" {
        Thread.sleep(forTimeInterval: 0.8)
    }
    if CommandLine.arguments[1] == "--drag-held-return" {
        Thread.sleep(forTimeInterval: 1)
        for step in 1...24 {
            let progress = CGFloat(step) / 24
            post(.leftMouseDragged, CGPoint(x: target.x + (start.x - target.x) * progress, y: start.y))
            Thread.sleep(forTimeInterval: 0.02)
        }
        post(.leftMouseUp, start)
        exit(0)
    }
    post(.leftMouseUp, target)
    exit(0)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let item = NSStatusBar.system.statusItem(withLength: 28)
item.button?.title = "FXA"
item.button?.setAccessibilityTitle("Flux fixture A")
if let index = CommandLine.arguments.firstIndex(of: "--geometry-output") {
    let output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    let marker = NSImage(size: NSSize(width: 18, height: 18))
    marker.lockFocus()
    NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 18, height: 18).fill()
    marker.unlockFocus()
    marker.isTemplate = false
    item.button?.title = ""
    item.button?.image = marker
    let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
        let value: [String: Any] = ["time": ProcessInfo.processInfo.systemUptime,
            "pid": getpid(), "window": String(describing: item.button?.window?.frame),
            "button": String(describing: item.button?.frame)]
        if let data = try? JSONSerialization.data(withJSONObject: value) {
            try? data.write(to: output, options: .atomic)
        }
    }
    RunLoop.main.add(timer, forMode: .common)
}
var second: NSStatusItem?
if !CommandLine.arguments.contains("--single") {
    second = NSStatusBar.system.statusItem(withLength: 28)
    second?.button?.title = "FXB"
    second?.button?.setAccessibilityTitle("Flux fixture B")
}
DispatchQueue.main.asyncAfter(deadline: .now() + 60) { exit(1) }
app.run()
'''
source = r'''
import AppKit
import ApplicationServices
setbuf(stdout, nil)

@MainActor
final class MenuMoveAction: NSObject {
    var invoke: (() -> Void)?
    @objc func performMove() { invoke?() }
}

@MainActor
func probe() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    guard Bundle.main.bundleIdentifier == "com.flux.icon-probe" else { exit(2) }
    UserDefaults.standard.removePersistentDomain(forName: "com.flux.icon-probe")
    // macOS 27 keeps both dividers narrow. A drop target must still lie in Hidden.
    let compact: MenuBarIconManager.Boundaries = (hidden: 300, alwaysHidden: 297)
    guard let x = MenuBarIconManager.insertionX(for: .hidden, iconWidth: 28, boundaries: compact),
          MenuBarIconManager.section(for: CGRect(x: x, y: 0, width: 28, height: 24),
                                     boundaries: compact) == .hidden else {
        print("FAIL: Move to Hidden targets another section when the dividers are adjacent")
        exit(1)
    }
    let runID = UUID().uuidString
    let chevron = ControlItem(role: .chevron, autosaveName: "flux.icon-probe.\(runID).chevron")
    let hidden = ControlItem(role: .divider, autosaveName: "flux.icon-probe.\(runID).hidden")
    let always = ControlItem(role: .divider, autosaveName: "flux.icon-probe.\(runID).always")
    var inventoryFailures = 0
    var saveFailures = 0
    let saveTest = CommandLine.arguments.contains("--move-save-retry")
        || CommandLine.arguments.contains("--move-save-failure")
    let hider = saveTest ? MacOS27Hider(trustProvider: {
        if saveFailures > 0 {
            saveFailures -= 1
            print("SAVE injected one failed position read")
            return false
        }
        return AccessibilityAccess.isGranted()
    }) : nil
    let manager = MenuBarIconManager(trustProvider: {
        if inventoryFailures > 0 {
            inventoryFailures -= 1
            print("INVENTORY injected one failed read")
            return false
        }
        return AccessibilityAccess.isGranted()
    }, hider: hider)
    manager.boundaryProvider = {
        (hidden: chevron.statusItem.button?.window?.frame.minX,
         alwaysHidden: always.statusItem.button?.window?.frame.minX)
    }
    manager.chevronBoundaryProvider = { chevron.statusItem.button?.window?.frame.minX }
    let closeTest = CommandLine.arguments.contains("--native-close")
        || CommandLine.arguments.contains("--move-close")
        || CommandLine.arguments.contains("--move-refresh-retry")
        || CommandLine.arguments.contains("--move-refresh-failure")
        || CommandLine.arguments.contains("--menu-context")
        || CommandLine.arguments.contains("--drag-context")
        || saveTest
        || CommandLine.arguments.contains("--native-overlap")
        || CommandLine.arguments.contains("--native-geometry")
        || CommandLine.arguments.contains("--native-refresh-retry")
    let sections: [MenuBarSection] = [.hidden, .alwaysHidden, .shown]
    func fixture() -> MenuBarIconManager.Icon? {
        manager.icons.first { $0.title == "Flux fixture A" }
    }
    var captureDeadlines: [String: TimeInterval] = [:]
    @MainActor
    @discardableResult
    func geometry(_ stage: String) -> CGPoint? {
        guard let index = CommandLine.arguments.firstIndex(of: "--geometry-output"),
              let screen = NSScreen.screens.first else { return nil }
        let output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        let image = output.appendingPathComponent(stage + ".png")
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-R0,0,\(Int(screen.frame.width)),48", image.path]
        do { try capture.run() }
        catch { print("FAIL: geometry capture could not start: \(error)"); exit(1) }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while capture.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if capture.isRunning { kill(capture.processIdentifier, SIGKILL) }
        capture.waitUntilExit()
        guard capture.terminationStatus == 0, let data = try? Data(contentsOf: image),
              let bitmap = NSBitmapImageRep(data: data), bitmap.bitsPerSample == 8,
              !bitmap.isPlanar, [3, 4].contains(bitmap.samplesPerPixel),
              let bytes = bitmap.bitmapData else {
            print("FAIL: geometry capture did not produce an RGB bitmap"); exit(1)
        }
        let stride = bitmap.samplesPerPixel
        let alphaFirst = bitmap.bitmapFormat.contains(.alphaFirst)
        let offset = alphaFirst && stride == 4 ? 1 : 0
        var count = 0, sumX = 0, sumY = 0
        var minX = bitmap.pixelsWide, maxX = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let pixel = y * bitmap.bytesPerRow + x * stride
                if bytes[pixel + offset] > 178, bytes[pixel + offset + 1] < 102,
                   bytes[pixel + offset + 2] > 178 {
                    count += 1; sumX += x; sumY += y
                    minX = min(minX, x); maxX = max(maxX, x)
                }
            }
        }
        if count < 20 {
            let deadline = captureDeadlines[stage] ?? ProcessInfo.processInfo.systemUptime + 1
            captureDeadlines[stage] = deadline
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                print("FAIL: geometry control marker is not visible after bounded settling")
                exit(1)
            }
            print("GEOMETRY_SETTLE \(stage) pixels=\(count)")
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            return geometry(stage)
        }
        captureDeadlines.removeValue(forKey: stage)
        let scale = CGFloat(bitmap.pixelsWide) / screen.frame.width
        let center = CGPoint(x: (CGFloat(sumX) / CGFloat(count) + 0.5) / scale,
                             y: (CGFloat(sumY) / CGFloat(count) + 0.5) / scale)
        var hit: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),
                                                      Float(center.x), Float(center.y), &hit)
        var pid: pid_t = 0
        var title: CFTypeRef?
        var hitPosition: CFTypeRef?
        var hitSize: CFTypeRef?
        if let hit {
            AXUIElementGetPid(hit, &pid)
            AXUIElementCopyAttributeValue(hit, kAXTitleAttribute as CFString, &title)
            AXUIElementCopyAttributeValue(hit, kAXPositionAttribute as CFString, &hitPosition)
            AXUIElementCopyAttributeValue(hit, kAXSizeAttribute as CFString, &hitSize)
        }
        var barValue: CFTypeRef?
        var childValue: CFTypeRef?
        let owner = AXUIElementCreateApplication(pid)
        AXUIElementCopyAttributeValue(owner, kAXExtrasMenuBarAttribute as CFString, &barValue)
        var fresh: [String] = []
        if let barValue, CFGetTypeID(barValue) == AXUIElementGetTypeID() {
            AXUIElementCopyAttributeValue(barValue as! AXUIElement, kAXChildrenAttribute as CFString, &childValue)
            for element in childValue as? [AXUIElement] ?? [] {
                var position: CFTypeRef?, size: CFTypeRef?, label: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position)
                AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size)
                AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &label)
                fresh.append("title=\(String(describing: label)) pos=\(String(describing: position)) size=\(String(describing: size)) equalHit=\(hit.map { CFEqual(element, $0) } ?? false)")
            }
        }
        let own = (try? String(contentsOf: output.appendingPathComponent("fixture.json"), encoding: .utf8)) ?? "missing"
        print("GEOMETRY \(stage) t=\(ProcessInfo.processInfo.systemUptime) pixels=\(count) marker=\(center) pixelX=\(CGFloat(minX)/scale)..\(CGFloat(maxX+1)/scale) AX=\(String(describing: fixture()?.frame)) controls=\(manager.boundaryProvider()) chevron=\(String(describing: chevron.statusItem.button?.window?.frame)) hitResult=\(result.rawValue) hitPID=\(pid) hitTitle=\(String(describing: title)) hitPosition=\(String(describing: hitPosition)) hitSize=\(String(describing: hitSize)) freshOwner=\(fresh) own=\(own)")
        if stage == "programmatic-shown" {
            var point = CGPoint.zero, size = CGSize.zero
            guard result == .success, title as? String == "Flux fixture A",
                  NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.flux.icon-fixture",
                  let hitPosition, let hitSize,
                  CFGetTypeID(hitPosition) == AXValueGetTypeID(), CFGetTypeID(hitSize) == AXValueGetTypeID(),
                  AXValueGetValue(hitPosition as! AXValue, .cgPoint, &point),
                  AXValueGetValue(hitSize as! AXValue, .cgSize, &size),
                  abs(center.x - point.x - size.width / 2) <= 1,
                  abs(center.y - point.y - size.height / 2) <= 1,
                  MenuBarIconManager.section(for: CGRect(x: center.x-1, y: center.y-1, width: 2, height: 2),
                                             boundaries: manager.boundaryProvider()) == .shown else {
                print("FAIL: programmatic inventory control did not reach drawn Shown geometry")
                exit(1)
            }
        }
        return center
    }
    @MainActor
    func finish() {
        manager.endIconManagement()
        chevron.removeFromStatusBar()
        hidden.removeFromStatusBar()
        always.removeFromStatusBar()
        exit(0)
    }
    @MainActor
    func moveFromMenu() {
        manager.refresh()
        guard let icon = fixture(), icon.section == .hidden else { exit(1) }
        let target = MenuMoveAction()
        let menu = NSMenu()
        let item = NSMenuItem(title: "Move fixture to Shown", action: #selector(MenuMoveAction.performMove), keyEquivalent: "")
        item.target = target
        menu.addItem(item)
        var invoked = false
        target.invoke = {
            invoked = true
            print("MENU action mode=\(RunLoop.current.currentMode?.rawValue ?? "nil") frame=\(icon.frame) boundaries=\(manager.boundaryProvider())")
            manager.move(icon, to: .shown)
        }
        let select = Timer(timeInterval: 0.2, repeats: false) { _ in
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: down)!
                event.flags = []
                event.post(tap: .cghidEventTap)
            }
        }
        let deadline = Timer(timeInterval: 2, repeats: false) { _ in
            print("FAIL: native menu control did not invoke the selected action")
            exit(1)
        }
        RunLoop.main.add(select, forMode: .common)
        RunLoop.main.add(deadline, forMode: .common)
        app.activate(ignoringOtherApps: true)
        menu.popUp(positioning: item, at: NSPoint(x: 400, y: 400), in: nil)
        deadline.invalidate()
        select.invalidate()
        target.invoke = nil
        guard invoked else { print("FAIL: native menu closed without invoking the move"); exit(1) }
        print("MENU closed mode=\(RunLoop.current.currentMode?.rawValue ?? "nil")")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            manager.refresh()
            let saved = UserDefaults.standard.dictionary(forKey: "flux.macOS27IconLayout")
            guard !manager.isUpdatingIcons, let current = fixture(),
                  MenuBarIconManager.section(for: current.frame, boundaries: manager.boundaryProvider()) == .shown,
                  current.section == .shown,
                  (saved?["hidden"] as? [String])?.contains("com.flux.icon-fixture") == false else {
                print("FAIL: a real menu action did not move and save the fixture as Shown")
                print("MENU actual=\(String(describing: fixture()?.frame)) boundaries=\(manager.boundaryProvider()) error=\(manager.errorMessage ?? "none")")
                manager.copyMenuBarReport()
                print(NSPasteboard.general.string(forType: .string) ?? "report unavailable")
                exit(1)
            }
            print("PASS: a real menu action moves the fixture and saves Shown")
            finish()
        }
    }
    @MainActor
    func moveFromDrag() {
        manager.refresh()
        guard let icon = fixture(), icon.section == .hidden,
              let screen = NSScreen.screens.first else { exit(1) }
        let window = NSWindow(contentRect: NSRect(x: 300, y: 180, width: 500, height: 360),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Flux real manager drag probe"
        window.isReleasedWhenClosed = false
        let controller = MenuBarDragController()
        let row = controller.makeSourceView(for: icon)
        row.frame = NSRect(x: 30, y: 260, width: 160, height: 32)
        let destination = MenuBarDragDestinationView(frame: NSRect(x: 270, y: 60, width: 190, height: 90))
        destination.controller = controller
        destination.section = .shown
        window.contentView!.addSubview(row)
        window.contentView!.addSubview(destination)
        var events: [String] = []
        controller.trace = { value in events.append(value); print("REAL_DRAG \(value)") }
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        let readyDeadline = ProcessInfo.processInfo.systemUptime + 5
        var stableSince: TimeInterval?
        var stableFrame: NSRect?
        @MainActor func start() {
            let now = ProcessInfo.processInfo.systemUptime
            guard now < readyDeadline else {
                print("INVALID: real manager drag window did not settle active and key"); exit(5)
            }
            guard NSApp.isActive, NSApp.keyWindow === window, window.isVisible,
                  !CGEventSource.buttonState(.combinedSessionState, button: .left) else {
                stableSince = nil
                stableFrame = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { start() }
                return
            }
            if stableFrame != window.frame {
                stableFrame = window.frame
                stableSince = now
            }
            guard let stableSince, now - stableSince >= 2 else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { start() }
                return
            }
            print("REAL_DRAG ready time=\(now) pid=\(getpid()) key=\(window.windowNumber) frame=\(window.frame)")
            controller.open(manager: manager, window: window)
            func center(_ view: NSView) -> CGPoint {
                let p = window.convertPoint(toScreen: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
                return CGPoint(x: p.x, y: screen.frame.maxY - p.y)
            }
            let from = center(row), to = center(destination)
            let driver = Process()
            driver.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
            driver.arguments = ["--drag-row", String(Double(from.x)), String(Double(from.y)),
                                String(Double(to.x)), String(Double(to.y))]
            driver.terminationHandler = { driver in
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    manager.refresh()
                    let saved = UserDefaults.standard.dictionary(forKey: "flux.macOS27IconLayout")
                    guard driver.terminationStatus == 0,
                          events.contains(where: { $0.hasPrefix("native began ") }),
                          events.contains("ended operation=16"),
                          events.contains(where: { $0.hasPrefix("commit shown ") }),
                          let current = fixture(), !manager.isUpdatingIcons,
                          MenuBarIconManager.section(for: current.frame, boundaries: manager.boundaryProvider()) == .shown,
                          current.section == .shown,
                          (saved?["hidden"] as? [String])?.contains("com.flux.icon-fixture") == false else {
                        manager.copyMenuBarReport()
                        print(NSPasteboard.general.string(forType: .string) ?? "report unavailable")
                        print("FAIL: real drag callbacks did not move and save the fixture as Shown")
                        exit(1)
                    }
                    controller.close()
                    window.close()
                    print("PASS: real drag callbacks move the actual icon and save Shown")
                    finish()
                }
            }
            do { try driver.run() }
            catch { print("FAIL: real drag driver could not start: \(error)"); exit(1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { start() }
    }
    @MainActor
    func moveAndClose() {
        manager.refresh()
        guard let icon = fixture(), icon.section == .hidden else { exit(1) }
        manager.move(icon, to: .shown)
        let started = ProcessInfo.processInfo.systemUptime
        @MainActor
        func closeAfterMovement() {
            manager.refresh()
            guard let current = fixture(), MenuBarIconManager.section(
                for: current.frame, boundaries: manager.boundaryProvider()) == .shown else {
                guard ProcessInfo.processInfo.systemUptime - started < 0.3 else {
                    print("FAIL: programmatic close test did not reach Shown before verification")
                    exit(1)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { closeAfterMovement() }
                return
            }
            guard manager.isUpdatingIcons, ProcessInfo.processInfo.systemUptime - started < 0.45 else {
                print("FAIL: programmatic close missed the pending verification interval")
                exit(1)
            }
            manager.endIconManagement()
            manager.copyMenuBarReport()
            guard NSPasteboard.general.string(forType: .string)?
                .contains("Current reveal: hidden=true, always=true") == true else {
                print("FAIL: closing management applied hiding before the pending move was verified")
                exit(1)
            }
            print("Closed management during programmatic verification after reaching actual Shown geometry")
            let failedRead = CommandLine.arguments.contains("--move-refresh-retry")
                || CommandLine.arguments.contains("--move-save-retry")
            let exhausted = CommandLine.arguments.contains("--move-refresh-failure")
                || CommandLine.arguments.contains("--move-save-failure")
            if failedRead || exhausted {
                guard geometry("programmatic-shown") != nil else {
                    print("FAIL: programmatic inventory control did not reach drawn Shown geometry")
                    exit(1)
                }
                if saveTest { saveFailures = exhausted ? 3 : 1 }
                else { inventoryFailures = exhausted ? 3 : 1 }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                let saved = UserDefaults.standard.dictionary(forKey: "flux.macOS27IconLayout")
                if exhausted {
                    manager.refresh()
                    guard inventoryFailures == 0, saveFailures == 0, !manager.isUpdatingIcons,
                          manager.errorMessage?.contains("could not save") == true,
                          fixture()?.section == .hidden,
                          (saved?["hidden"] as? [String])?.contains("com.flux.icon-fixture") == true else {
                        print("FAIL: exhausted programmatic inventory retries left a false Shown assignment or no notice")
                        exit(1)
                    }
                    print("PASS: programmatic inventory retries stop, clear the override and retain a save notice")
                    if saveTest {
                        manager.beginIconManagement()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            guard let retry = fixture(), manager.errorMessage?.contains("could not save") == true else {
                                print("FAIL: the same-manager retry lost its failed-save control")
                                exit(1)
                            }
                            manager.move(retry, to: .shown)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                let saved = UserDefaults.standard.dictionary(forKey: "flux.macOS27IconLayout")
                                guard !manager.isUpdatingIcons,
                                      (saved?["hidden"] as? [String])?.contains("com.flux.icon-fixture") == false else {
                                    print("FAIL: the same-manager retry did not save Shown")
                                    exit(1)
                                }
                                guard manager.errorMessage == nil else {
                                    print("FAIL: a successful retry retained the old save warning")
                                    exit(1)
                                }
                                print("PASS: a successful same-app retry clears its saved failure notice")
                                finish()
                            }
                        }
                        return
                    }
                    finish()
                }
                guard !manager.isUpdatingIcons,
                      inventoryFailures == 0,
                      saveFailures == 0,
                      (saved?["hidden"] as? [String])?.contains("com.flux.icon-fixture") == false else {
                    print(failedRead
                        ? (saveTest ? "FAIL: a transient position save lost the programmatic Shown assignment"
                            : "FAIL: a transient programmatic inventory read lost the Shown assignment")
                        : "FAIL: closing management lost the pending programmatic Shown assignment")
                    exit(1)
                }
                let fresh = MenuBarIconManager()
                fresh.boundaryProvider = manager.boundaryProvider
                fresh.refresh()
                let icons = fresh.icons.filter { $0.id.hasPrefix("com.flux.icon-fixture|") }
                guard icons.count == 1, icons[0].section == .shown else {
                    print("FAIL: fresh manager lost the programmatic Shown assignment")
                    exit(1)
                }
                print("PASS: closing management preserves a pending programmatic move and reloads Shown")
                finish()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { closeAfterMovement() }
    }
    @MainActor
    func moveSibling(_ items: [MenuBarIconManager.Icon]) {
        let first = items[0], second = items[1]
        guard let boundary = manager.boundaryProvider().hidden else { exit(1) }
        let targetX = max(boundary + 80, second.frame.midX + 80)
        let driver = Process()
        driver.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
        driver.arguments = ["--drag-siblings", String(Double(first.frame.midX)), String(Double(first.frame.midY)),
                            String(Double(second.frame.midX)), String(Double(second.frame.midY)),
                            String(Double(targetX)), String(Double(second.frame.midY))]
        var releases = 0
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { event in
            if event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) == Int64(driver.processIdentifier) {
                releases += 1
            }
        }
        driver.terminationHandler = { driver in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if let monitor { NSEvent.removeMonitor(monitor) }
                manager.refresh()
                let current = manager.icons.filter { $0.id.hasPrefix("com.flux.icon-fixture|") }
                guard driver.terminationStatus == 0, releases == 2,
                      let a = current.first(where: { $0.title == first.title }),
                      let b = current.first(where: { $0.title == second.title }),
                      abs(a.frame.midX - first.frame.midX) < 1,
                      MenuBarIconManager.section(for: b.frame, boundaries: manager.boundaryProvider()) == .shown else {
                    print("FAIL: sibling native control needs unchanged first icon and a second icon moved to Shown; before=\(items.map { ($0.title, $0.frame) }), after=\(current.map { ($0.title, $0.frame) }), releases=\(releases)")
                    exit(1)
                }
                let saved = UserDefaults.standard.dictionary(forKey: "flux.macOS27IconLayout")
                guard (saved?["hidden"] as? [String])?.contains("com.flux.icon-fixture") == false else {
                    print("FAIL: an unchanged first icon discarded the second icon's native Shown move")
                    exit(1)
                }
                let fresh = MenuBarIconManager()
                fresh.boundaryProvider = manager.boundaryProvider
                fresh.refresh()
                guard fresh.icons.filter({ $0.id.hasPrefix("com.flux.icon-fixture|") })
                    .allSatisfy({ $0.section == .shown }) else {
                    print("FAIL: the sibling native assignment did not survive manager reload")
                    exit(1)
                }
                print("PASS: an unchanged pending icon preserves another icon's completed move from the same app")
                finish()
            }
        }
        do { try driver.run() }
        catch { print("FAIL: sibling native driver could not start: \(error)"); exit(1) }
    }
    @MainActor
    func overlapProgrammaticMove(_ items: [MenuBarIconManager.Icon]) {
        let moving = items[0], other = items[1]
        manager.move(moving, toward: .towardClock)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            manager.refresh()
            guard manager.isUpdatingIcons,
                  let current = manager.icons.first(where: { $0.title == other.title }),
                  let boundary = manager.boundaryProvider().hidden else {
                print("FAIL: programmatic overlap missed pending arrow verification")
                exit(1)
            }
            let driver = Process()
            driver.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
            driver.arguments = ["--drag-held-return", String(Double(current.frame.midX)),
                                String(Double(current.frame.midY)), String(Double(boundary + 140)),
                                String(Double(current.frame.midY))]
            var released = false
            let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { event in
                if event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) == Int64(driver.processIdentifier) {
                    released = true
                }
            }
            driver.terminationHandler = { driver in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    if let monitor { NSEvent.removeMonitor(monitor) }
                    manager.refresh()
                    let saved = UserDefaults.standard.dictionary(forKey: "flux.macOS27IconLayout")
                    let current = manager.icons.filter { $0.id.hasPrefix("com.flux.icon-fixture|") }
                    guard driver.terminationStatus == 0, released, !manager.isUpdatingIcons,
                          current.count == 2, current.allSatisfy({ MenuBarIconManager.section(
                            for: $0.frame, boundaries: manager.boundaryProvider()) == .hidden }),
                          (saved?["hidden"] as? [String])?.contains("com.flux.icon-fixture") == true,
                          (saved?["alwaysHidden"] as? [String])?.contains("com.flux.icon-fixture") == false else {
                        print("FAIL: an overlapping arrow and returned native drag changed the saved Hidden assignment")
                        exit(1)
                    }
                    print("PASS: programmatic verification waits for native input to finish before saving")
                    finish()
                }
            }
            do { try driver.run() }
            catch { print("FAIL: programmatic overlap driver could not start: \(error)"); exit(1) }
            Thread.sleep(forTimeInterval: 0.75)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                manager.refresh()
                let saved = UserDefaults.standard.dictionary(forKey: "flux.macOS27IconLayout")
                guard NSEvent.pressedMouseButtons & 1 != 0,
                      let held = manager.icons.first(where: { $0.title == other.title }),
                      MenuBarIconManager.section(for: held.frame,
                                                boundaries: manager.boundaryProvider()) == .shown else {
                    print("FAIL: programmatic overlap did not hold the sibling in Shown")
                    exit(1)
                }
                guard (saved?["hidden"] as? [String])?.contains("com.flux.icon-fixture") == true else {
                    print("FAIL: programmatic verification saved an unfinished native sibling drag")
                    exit(1)
                }
                print("PASS: a held native sibling drag cannot change saved visibility")
            }
        }
    }
    @MainActor
    func overlappingNativeMove(from icon: MenuBarIconManager.Icon) {
        guard let x = MenuBarIconManager.insertionX(for: .alwaysHidden, iconWidth: icon.frame.width,
                                                    boundaries: manager.boundaryProvider()) else { exit(1) }
        let driver = Process()
        let source = geometry("before-overlap") ?? CGPoint(x: icon.frame.midX, y: icon.frame.midY)
        driver.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
        driver.arguments = ["--drag-overlap", String(Double(source.x)), String(Double(source.y)),
                            String(Double(x + icon.frame.width / 2)), String(Double(icon.frame.midY))]
        var released = false
        var monitor: Any?
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { event in
            if event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) == Int64(driver.processIdentifier) {
                released = true
            }
        }
        driver.terminationHandler = { driver in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let current = monitor { NSEvent.removeMonitor(current); monitor = nil }
                guard driver.terminationStatus == 0, released, NSEvent.pressedMouseButtons & 1 == 0 else {
                    print("FAIL: the overlapping native driver did not deliver mouse-up")
                    exit(1)
                }
                let saved = UserDefaults.standard.dictionary(forKey: "flux.macOS27IconLayout")
                geometry("after-overlap-release")
                let fresh = MenuBarIconManager()
                fresh.boundaryProvider = manager.boundaryProvider
                fresh.refresh()
                let items = fresh.icons.filter { $0.id.hasPrefix("com.flux.icon-fixture|") }
                print("OVERLAP after release saved=\(String(describing: saved)) items=\(items.map { ($0.title, $0.section, $0.frame) }) boundaries=\(manager.boundaryProvider())")
                guard items.count == 1, MenuBarIconManager.section(for: items[0].frame,
                    boundaries: manager.boundaryProvider()) == .alwaysHidden else {
                    print("FAIL: the completed second native drag did not reach Always Hidden")
                    exit(1)
                }
                guard (saved?["hidden"] as? [String])?.contains("com.flux.icon-fixture") == true,
                      (saved?["alwaysHidden"] as? [String])?.contains("com.flux.icon-fixture") == true,
                      items.count == 1, items[0].section == .alwaysHidden,
                      MenuBarIconManager.section(for: items[0].frame,
                                                boundaries: manager.boundaryProvider()) == .alwaysHidden else {
                    print("FAIL: delayed callbacks lost the latest completed native move")
                    exit(1)
                }
                print("PASS: delayed callbacks save the latest completed native move after held input ends")
                finish()
            }
        }
        do { try driver.run() }
        catch { print("FAIL: overlapping native driver launch: \(error)"); exit(1) }
        Thread.sleep(forTimeInterval: 0.75)
        let heldDeadline = ProcessInfo.processInfo.systemUptime + 0.8
        @MainActor func verifyHeld() {
            let pointer = CGEvent(source: nil)?.location
            if NSEvent.pressedMouseButtons & 1 != 0,
               let pointer, pointer.x >= x + icon.frame.width / 2 + 2,
               ProcessInfo.processInfo.systemUptime < heldDeadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { verifyHeld() }
                return
            }
            let saved = UserDefaults.standard.dictionary(forKey: "flux.macOS27IconLayout")
            manager.refresh()
            print("OVERLAP held buttons=\(NSEvent.pressedMouseButtons) pointer=\(String(describing: pointer)) actual=\(String(describing: fixture()?.frame)) controls=\(manager.boundaryProvider()) saved=\(String(describing: saved))")
            guard NSEvent.pressedMouseButtons & 1 != 0, let pointer,
                  let alwaysX = manager.boundaryProvider().alwaysHidden,
                  pointer.x < alwaysX - 12 else {
                print("FAIL: the overlapping native control did not hold its drag across Always Hidden")
                exit(1)
            }
            guard (saved?["hidden"] as? [String])?.contains("com.flux.icon-fixture") == true,
                  (saved?["alwaysHidden"] as? [String])?.contains("com.flux.icon-fixture") == false else {
                print("FAIL: an older native callback saved while a later drag was held")
                exit(1)
            }
            print("PASS: the held second native drag has not overwritten saved assignments")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { verifyHeld() }
    }
    @MainActor
    func nativeMove() {
        let layoutKey = "flux.macOS27IconLayout"
        let fixtureID = "com.flux.icon-fixture"
        guard let layout = UserDefaults.standard.dictionary(forKey: layoutKey),
              (layout["hidden"] as? [String])?.contains(fixtureID) == true,
              (layout["alwaysHidden"] as? [String])?.contains(fixtureID) == false else {
            print("FAIL: Settings moves did not persist the fixture's Hidden assignment")
            exit(1)
        }
        let reloaded = MenuBarIconManager()
        reloaded.boundaryProvider = manager.boundaryProvider
        reloaded.refresh()
        guard reloaded.icons.filter({ $0.id.hasPrefix(fixtureID + "|") })
            .allSatisfy({ $0.section == .hidden }) else {
            print("FAIL: a fresh manager lost the saved Hidden assignment")
            exit(1)
        }
        manager.refresh()
        guard let icon = fixture(),
              MenuBarIconManager.section(for: icon.frame,
                                        boundaries: manager.boundaryProvider()) == .hidden,
              let x = MenuBarIconManager.insertionX(for: .shown, iconWidth: icon.frame.width,
                                                    boundaries: manager.boundaryProvider()) else {
            print("FAIL: native move needs a real Hidden fixture and Shown boundary")
            exit(1)
        }
        let driver = Process()
        let targetX = max(x + icon.frame.width / 2,
                          (chevron.statusItem.button?.window?.frame.maxX ?? x) + icon.frame.width)
        let physicalSource = geometry("before-native") ?? CGPoint(x: icon.frame.midX, y: icon.frame.midY)
        print("Native source=\(icon.frame), physicalSource=\(physicalSource), targetX=\(targetX), boundaries=\(manager.boundaryProvider())")
        driver.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
        driver.arguments = ["--drag", String(Double(physicalSource.x)), String(Double(physicalSource.y)),
                            String(Double(targetX)), String(Double(physicalSource.y))]
        var releasedAt: TimeInterval?
        var releaseMonitor: Any?
        releaseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { event in
            guard event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID)
                == Int64(driver.processIdentifier) else { return }
            releasedAt = ProcessInfo.processInfo.systemUptime
            if CommandLine.arguments.contains("--native-refresh-retry") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { inventoryFailures = 1 }
            }
        }
        @MainActor
        func verifyRelease(until deadline: TimeInterval) {
            guard let releasedAt else {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    print("FAIL: macOS did not deliver the independent native mouse-up")
                    exit(1)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { verifyRelease(until: deadline) }
                return
            }
            if let monitor = releaseMonitor {
                NSEvent.removeMonitor(monitor)
                releaseMonitor = nil
            }
            manager.refresh()
            if CommandLine.arguments.contains("--native-geometry") { geometry("after-native") }
            guard let actual = fixture() else {
                print("FAIL: the native fixture disappeared after mouse-up")
                exit(1)
            }
            guard MenuBarIconManager.section(for: actual.frame,
                                            boundaries: manager.boundaryProvider()) == .shown else {
                if ProcessInfo.processInfo.systemUptime - releasedAt < 0.25 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { verifyRelease(until: deadline) }
                    return
                }
                print("FAIL: the native Command driver did not move the real icon to Shown; actual=\(actual.frame), boundaries=\(manager.boundaryProvider())")
                exit(1)
            }
            print("PASS: native Command changed Hidden to Shown after delivered mouse-up")
            if CommandLine.arguments.contains("--native-overlap") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    manager.refresh()
                    let saved = UserDefaults.standard.dictionary(forKey: layoutKey)
                    guard let settled = fixture(),
                          (saved?["hidden"] as? [String])?.contains(fixtureID) == true,
                          MenuBarIconManager.section(for: settled.frame,
                                                    boundaries: manager.boundaryProvider()) == .shown else {
                        print("FAIL: overlapping native setup missed the first move's pending interval")
                        exit(1)
                    }
                    print("OVERLAP pending first move, settled source=\(settled.frame)")
                    overlappingNativeMove(from: settled)
                }
                return
            }
            if CommandLine.arguments.contains("--native-close") {
                manager.endIconManagement()
                let delay = ProcessInfo.processInfo.systemUptime - releasedAt
                guard delay < 0.35 else {
                    print("FAIL: the close test missed the 350ms verification interval: \(delay)s")
                    exit(1)
                }
                print("Closed management \(delay)s after native mouse-up")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                geometry("after-native-1s")
                let saved = UserDefaults.standard.dictionary(forKey: layoutKey)
                guard (saved?["hidden"] as? [String])?.contains(fixtureID) == false,
                      (saved?["alwaysHidden"] as? [String])?.contains(fixtureID) == false else {
                    print(CommandLine.arguments.contains("--native-refresh-retry")
                        ? "FAIL: a transient inventory read discarded the completed native move"
                        : "FAIL: the native Command move to Shown did not persist")
                    exit(1)
                }
                let fresh = MenuBarIconManager()
                fresh.boundaryProvider = manager.boundaryProvider
                fresh.refresh()
                let items = fresh.icons.filter { $0.id.hasPrefix(fixtureID + "|") }
                guard items.count == 1, items.allSatisfy({ $0.section == .shown }),
                      items.contains(where: {
                          $0.title == icon.title && MenuBarIconManager.section(
                            for: $0.frame, boundaries: manager.boundaryProvider()) == .shown
                      }) else {
                    print("FAIL: a fresh manager or actual geometry lost the native Shown move")
                    exit(1)
                }
                print("PASS: native Command moved the real icon and persisted Shown across manager reload")
                finish()
            }
        }
        driver.terminationHandler = { driver in
            DispatchQueue.main.async {
                guard driver.terminationStatus == 0 else {
                    print("FAIL: the independent native Command driver failed")
                    exit(1)
                }
                verifyRelease(until: ProcessInfo.processInfo.systemUptime + 1)
            }
        }
        do { try driver.run() }
        catch { print("FAIL: could not start the native Command driver: \(error)"); exit(1) }
    }
    manager.endProvider = { [weak manager] in
        manager?.applyDrawerVisibility(revealHidden: false, revealAlwaysHidden: false)
    }
    @MainActor
    func reorder(prepared: Int = 0) {
        manager.refresh()
        let items = manager.icons.filter { $0.id.hasPrefix("com.flux.icon-fixture|") }
        let expected = closeTest ? 1 : 2
        guard items.count == expected else {
            print("FAIL: the reorder fixture needs \(expected) readable icons")
            exit(1)
        }
        if prepared < expected {
            manager.move(items[prepared], to: .hidden)
            guard manager.isUpdatingIcons else {
                print("FAIL: the section move did not publish its pending verification")
                exit(1)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { reorder(prepared: prepared + 1) }
            return
        }
        let ordered = items.sorted { $0.frame.minX < $1.frame.minX }
        let moving = ordered[0]
        if let physical = geometry("prepared-hidden") {
            guard abs(physical.x - moving.frame.midX) <= 1,
                  MenuBarIconManager.section(for: CGRect(x: physical.x-1, y: physical.y-1, width: 2, height: 2),
                                             boundaries: manager.boundaryProvider()) == .hidden else {
                print("FAIL: AX position disagrees with the drawn fixture after moving to Hidden")
                exit(1)
            }
        }
        guard ordered.allSatisfy({ MenuBarIconManager.section(for: $0.frame, boundaries: manager.boundaryProvider()) == .hidden }) else {
            print("FAIL: the reorder fixture could not enter Hidden")
            exit(1)
        }
        if CommandLine.arguments.contains("--menu-context") {
            moveFromMenu()
            return
        }
        if CommandLine.arguments.contains("--drag-context") {
            moveFromDrag()
            return
        }
        if CommandLine.arguments.contains("--native-sibling") {
            moveSibling(ordered)
            return
        }
        if CommandLine.arguments.contains("--move-overlap") {
            overlapProgrammaticMove(ordered)
            return
        }
        if CommandLine.arguments.contains("--native-close") || CommandLine.arguments.contains("--native-overlap")
            || CommandLine.arguments.contains("--native-geometry")
            || CommandLine.arguments.contains("--native-refresh-retry") {
            nativeMove()
            return
        }
        if CommandLine.arguments.contains("--move-close")
            || CommandLine.arguments.contains("--move-refresh-retry")
            || CommandLine.arguments.contains("--move-refresh-failure") {
            moveAndClose()
            return
        }
        if saveTest {
            moveAndClose()
            return
        }
        guard manager.canMove(moving, toward: .towardClock) else { exit(1) }
        manager.move(moving, toward: .towardClock)
        guard manager.isUpdatingIcons else {
            print("FAIL: the arrow move did not publish its pending verification")
            exit(1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            manager.refresh()
            let next = manager.icons.filter { $0.id.hasPrefix("com.flux.icon-fixture|") }
                .sorted { $0.frame.minX < $1.frame.minX }
            guard !manager.isUpdatingIcons, next.last?.title == moving.title,
                  next.allSatisfy({ MenuBarIconManager.section(
                    for: $0.frame, boundaries: manager.boundaryProvider()) == .hidden }) else {
                print("FAIL: the Settings arrow did not change the real icon order")
                print("Actual frames: \(next.map { ($0.title, $0.frame) }); boundaries=\(manager.boundaryProvider())")
                exit(1)
            }
            print("PASS: the Settings arrow changed the real icon order")
            finish()
        }
    }
    @MainActor
    func move(index: Int) {
        manager.refresh()
        guard let icon = fixture() else {
            print("FAIL: the fixture icon was not readable")
            exit(1)
        }
        let section = sections[index]
        print("Moving fixture to \(section.rawValue), from \(icon.frame); boundaries=\(manager.boundaryProvider())")
        manager.move(icon, to: section)
        guard manager.isUpdatingIcons else {
            print("FAIL: the section move did not publish its pending verification")
            exit(1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            manager.refresh()
            guard !manager.isUpdatingIcons, let current = fixture(),
                  MenuBarIconManager.section(for: current.frame, boundaries: manager.boundaryProvider()) == section,
                  current.section == section else {
                print("FAIL: the real fixture did not move to \(section.rawValue); \(manager.errorMessage ?? "no error")")
                if let current = fixture() { print("Actual frame: \(current.frame); boundaries=\(manager.boundaryProvider())") }
                manager.copyMenuBarReport()
                print(NSPasteboard.general.string(forType: .string) ?? "report unavailable")
                exit(1)
            }
            print("PASS: Settings moved the real fixture to \(section.rawValue)")
            if let physical = geometry("section-\(section.rawValue)") {
                guard abs(physical.x - current.frame.midX) <= 1,
                      MenuBarIconManager.section(for: CGRect(x: physical.x-1, y: physical.y-1,
                                                            width: 2, height: 2),
                                                 boundaries: manager.boundaryProvider()) == section else {
                    print("FAIL: AX position disagrees with the drawn fixture after moving to \(section.rawValue)")
                    exit(1)
                }
            }
            if index + 1 < sections.count { move(index: index + 1) }
            else {
                reorder()
            }
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        manager.beginIconManagement()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if closeTest { reorder() }
            else { move(index: 0) }
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
        print("FAIL: the icon move probe reached its deadline")
        exit(1)
    }
    app.run()
}
AccessibilityAccess.exitIfRequested()
MainActor.assumeIsolated { probe() }
'''

with tempfile.TemporaryDirectory(prefix="flux-icon-probe-") as directory:
    temporary = Path(directory)
    manager_path = "Sources/Flux/MenuBar/MenuBarIconManager.swift"
    manager_source = root / manager_path
    if options.manager_ref:
        manager_source = temporary / "MenuBarIconManager.swift"
        manager_source.write_text(subprocess.check_output(
            ["git", "show", options.manager_ref + ":" + manager_path],
            cwd=root, text=True, timeout=15))

    def bundle(name, bundle_id, code, dependencies):
        app = temporary / f"{name}.app"
        binary = app / f"Contents/MacOS/{name}"
        binary.parent.mkdir(parents=True)
        with (app / "Contents/Info.plist").open("wb") as output:
            plistlib.dump({"CFBundleIdentifier": bundle_id, "CFBundleExecutable": name,
                          "CFBundlePackageType": "APPL", "LSUIElement": True}, output)
        sources = temporary / name
        sources.mkdir()
        main = sources / "main.swift"
        if "private let injectedHider:" not in manager_source.read_text():
            code = code.replace("}, hider: hider)", "})")
        main.write_text(code)
        command(["swiftc", "-swift-version", "5", str(main)] +
                [str(manager_source if dependency == manager_path else root / dependency)
                 for dependency in dependencies] + ["-o", str(binary)], 120)
        command(["codesign", "--force", "--sign", "-", str(app)], 20)
        return binary

    fixture = bundle("FluxIconFixture", "com.flux.icon-fixture", fixture_source, [])
    binary = bundle("FluxIconProbe", "com.flux.icon-probe", source, [
        "Sources/Flux/MenuBar/MenuBarIconManager.swift", "Sources/Flux/MenuBar/MacOS27Hider.swift",
        "Sources/Flux/MenuBar/ControlItem.swift", "Sources/Flux/MenuBar/MenuBarSection.swift",
        "Sources/Flux/MenuBar/MenuBarIconStyle.swift", "Sources/Flux/MenuBar/MenuBarGeometry.swift",
        "Sources/Flux/MenuBar/MenuBarDragController.swift",
        "Sources/Flux/Support/Theme.swift", "Sources/Flux/Support/Log.swift",
        "Sources/Flux/Support/AccessibilityAccess.swift"])
    close_test = (options.native_close or options.move_close or options.native_overlap
                  or options.native_geometry or options.native_refresh_retry
                  or options.move_refresh_retry or options.move_refresh_failure
                  or options.move_save_retry or options.move_save_failure or options.menu_context or options.drag_context)
    capture_geometry = (options.native_geometry or options.move_refresh_retry or options.move_refresh_failure
                        or options.move_save_retry or options.move_save_failure)
    geometry = temporary / "geometry"
    geometry.mkdir()
    fixture_flags = (["--single"] if close_test else [])
    if capture_geometry:
        fixture_flags += ["--geometry-output", str(geometry / "fixture.json")]
    process = subprocess.Popen([str(fixture)] + fixture_flags, start_new_session=True)
    started_at = time.time()
    try:
        selected = [("--native-sibling", options.native_sibling), ("--native-close", options.native_close),
                    ("--move-close", options.move_close), ("--native-overlap", options.native_overlap),
                    ("--move-refresh-retry", options.move_refresh_retry),
                    ("--move-refresh-failure", options.move_refresh_failure),
                    ("--move-save-retry", options.move_save_retry),
                    ("--move-save-failure", options.move_save_failure),
                    ("--menu-context", options.menu_context),
                    ("--drag-context", options.drag_context),
                    ("--native-geometry", options.native_geometry), ("--native-refresh-retry", options.native_refresh_retry),
                    ("--move-overlap", options.move_overlap)]
        flags = [flag for flag, enabled in selected if enabled]
        if capture_geometry:
            flags += ["--geometry-output", str(geometry)]
        command([str(binary), str(fixture)] + flags, 30)
        if capture_geometry:
            shutil.copytree(geometry, root / "build/icon-probe/geometry", dirs_exist_ok=True)
    except BaseException:
        label = (options.manager_ref or "current")[:8] + ("-overlap" if options.native_overlap else
                ("-native" if options.native_close else ("-close" if options.move_close else "-settings")))
        evidence = root / "build/icon-probe" / label
        shutil.copytree(temporary, evidence, dirs_exist_ok=True)
        reports = Path.home() / "Library/Logs/DiagnosticReports"
        deadline = time.monotonic() + 3
        while True:
            crashes = [path for path in reports.glob("FluxIconProbe*.ips")
                       if path.stat().st_mtime >= started_at]
            if crashes or time.monotonic() >= deadline:
                break
            time.sleep(0.1)
        for path in crashes:
            shutil.copy2(path, evidence / path.name)
        print(f"FAIL evidence: {evidence}", flush=True)
        raise
    finally:
        _stop(process)
