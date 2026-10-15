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
parser.add_argument("--native-overlap", action="store_true")
parser.add_argument("--native-geometry", action="store_true")
parser.add_argument("--manager-ref", help="Compile a committed manager with the current native fixture")
options = parser.parse_args()
fixture_source = r'''
import AppKit
if CommandLine.arguments.count == 6 && ["--drag", "--drag-overlap"].contains(CommandLine.arguments[1]) {
    let values = CommandLine.arguments.dropFirst(2).compactMap(Double.init)
    guard values.count == 4 else { exit(2) }
    let start = CGPoint(x: values[0], y: values[1])
    let target = CGPoint(x: values[2], y: values[3])
    func post(_ type: CGEventType, _ point: CGPoint) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left) else { exit(2) }
        event.flags = .maskCommand
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
        for down in [true, false] {
            let escape = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)!
            escape.flags = []
            escape.post(tap: .cghidEventTap)
        }
        Thread.sleep(forTimeInterval: 0.08)
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
    let manager = MenuBarIconManager()
    manager.boundaryProvider = {
        (hidden: chevron.statusItem.button?.window?.frame.minX,
         alwaysHidden: always.statusItem.button?.window?.frame.minX)
    }
    manager.chevronBoundaryProvider = { chevron.statusItem.button?.window?.frame.minX }
    let closeTest = CommandLine.arguments.contains("--native-close")
        || CommandLine.arguments.contains("--move-close")
        || CommandLine.arguments.contains("--native-overlap")
        || CommandLine.arguments.contains("--native-geometry")
    let sections: [MenuBarSection] = [.hidden, .alwaysHidden, .shown]
    func fixture() -> MenuBarIconManager.Icon? {
        manager.icons.first { $0.title == "Flux fixture A" }
    }
    var previousHit: AXUIElement?
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
        var previousPosition: CFTypeRef?
        if let previousHit {
            AXUIElementCopyAttributeValue(previousHit, kAXPositionAttribute as CFString, &previousPosition)
        }
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
        let windows = (CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
        if let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first {
            let host = AXUIElementCreateApplication(agent.processIdentifier)
            AXUIElementSetMessagingTimeout(host, 0.1)
            var hostBar: CFTypeRef?
            AXUIElementCopyAttributeValue(host, kAXExtrasMenuBarAttribute as CFString, &hostBar)
            var records: [[String: String]] = []
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            func visit(_ element: AXUIElement, depth: Int) {
                guard depth < 6, records.count < 100, ProcessInfo.processInfo.systemUptime < deadline else { return }
                var record: [String: String] = ["depth": String(depth)]
                var ownerPID: pid_t = 0
                AXUIElementGetPid(element, &ownerPID)
                record["pid"] = String(ownerPID)
                record["equalHit"] = String(hit.map { CFEqual(element, $0) } ?? false)
                for key in [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                            kAXIdentifierAttribute, kAXPositionAttribute, kAXSizeAttribute] {
                    var value: CFTypeRef?
                    let result = AXUIElementCopyAttributeValue(element, key as CFString, &value)
                    record[key] = "\(result.rawValue):\(String(describing: value))"
                }
                records.append(record)
                var children: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
                for child in children as? [AXUIElement] ?? [] { visit(child, depth: depth + 1) }
            }
            if let hostBar, CFGetTypeID(hostBar) == AXUIElementGetTypeID() {
                visit(hostBar as! AXUIElement, depth: 0)
            }
            if let data = try? JSONSerialization.data(withJSONObject: records, options: .prettyPrinted) {
                try? data.write(to: output.appendingPathComponent(stage + "-host.json"), options: .atomic)
            }
            print("GEOMETRY_HOST \(stage) nodes=\(records.count)")
        }
        print("GEOMETRY \(stage) t=\(ProcessInfo.processInfo.systemUptime) pixels=\(count) marker=\(center) pixelX=\(CGFloat(minX)/scale)..\(CGFloat(maxX+1)/scale) AX=\(String(describing: fixture()?.frame)) controls=\(manager.boundaryProvider()) chevron=\(String(describing: chevron.statusItem.button?.window?.frame)) hitResult=\(result.rawValue) hitPID=\(pid) hitTitle=\(String(describing: title)) hitPosition=\(String(describing: hitPosition)) hitSize=\(String(describing: hitSize)) freshOwner=\(fresh) own=\(own) windows=\(windows)")
        print("GEOMETRY_RETAINED \(stage) previousPosition=\(String(describing: previousPosition)) sameHit=\(hit.flatMap { new in previousHit.map { CFEqual(new, $0) } } ?? false)")
        var parents: [[String: String]] = []
        var parent = hit
        let parentDeadline = ProcessInfo.processInfo.systemUptime + 0.75
        for depth in 0..<3 {
            guard let current = parent, ProcessInfo.processInfo.systemUptime < parentDeadline else { break }
            AXUIElementSetMessagingTimeout(current, 0.03)
            var parentValue: CFTypeRef?
            AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentValue)
            guard let parentValue, CFGetTypeID(parentValue) == AXUIElementGetTypeID() else { break }
            let next = parentValue as! AXUIElement
            var childrenValue: CFTypeRef?
            AXUIElementCopyAttributeValue(next, kAXChildrenAttribute as CFString, &childrenValue)
            for item in [next] + Array((childrenValue as? [AXUIElement] ?? []).prefix(40)) {
                guard ProcessInfo.processInfo.systemUptime < parentDeadline else { break }
                AXUIElementSetMessagingTimeout(item, 0.03)
                var ownerPID: pid_t = 0
                AXUIElementGetPid(item, &ownerPID)
                var record = ["depth": String(depth), "pid": String(ownerPID)]
                for key in [kAXRoleAttribute, kAXTitleAttribute, kAXIdentifierAttribute, kAXPositionAttribute, kAXSizeAttribute] {
                    var value: CFTypeRef?
                    let error = AXUIElementCopyAttributeValue(item, key as CFString, &value)
                    record[key] = "\(error.rawValue):\(String(describing: value))"
                }
                parents.append(record)
            }
            parent = next
        }
        if let data = try? JSONSerialization.data(withJSONObject: parents, options: .prettyPrinted) {
            try? data.write(to: output.appendingPathComponent(stage + "-parents.json"), options: .atomic)
        }
        previousHit = hit
        let scanStart = ProcessInfo.processInfo.systemUptime
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.03)
        var scanX = screen.frame.maxX - 1
        var queries = 0
        var visibleFrames: [CGRect] = []
        while scanX >= screen.frame.minX, queries < 256,
              ProcessInfo.processInfo.systemUptime - scanStart < 1 {
            queries += 1
            var value: AXUIElement?
            defer { scanX -= 8 }
            guard AXUIElementCopyElementAtPosition(system, Float(scanX), Float(center.y), &value) == .success,
                  let value else { continue }
            AXUIElementSetMessagingTimeout(value, 0.03)
            var role: CFTypeRef?, position: CFTypeRef?, size: CFTypeRef?
            AXUIElementCopyAttributeValue(value, kAXRoleAttribute as CFString, &role)
            guard role as? String == kAXMenuBarItemRole as String else { continue }
            AXUIElementCopyAttributeValue(value, kAXPositionAttribute as CFString, &position)
            AXUIElementCopyAttributeValue(value, kAXSizeAttribute as CFString, &size)
            guard let position, let size, CFGetTypeID(position) == AXValueGetTypeID(),
                  CFGetTypeID(size) == AXValueGetTypeID() else { continue }
            var point = CGPoint.zero, dimensions = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
                  AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { continue }
            let frame = CGRect(origin: point, size: dimensions)
            guard frame.contains(CGPoint(x: scanX, y: center.y)) else { continue }
            var ownerPID: pid_t = 0
            AXUIElementGetPid(value, &ownerPID)
            if ownerPID == pid, !visibleFrames.contains(frame) { visibleFrames.append(frame) }
            scanX = min(scanX, frame.minX + 7)
        }
        print("GEOMETRY_SCAN \(stage) queries=\(queries) seconds=\(ProcessInfo.processInfo.systemUptime-scanStart) fixtureFrames=\(visibleFrames) marker=\(center)")
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
    func moveAndClose() {
        manager.refresh()
        guard let icon = fixture(), icon.section == .hidden else { exit(1) }
        let started = ProcessInfo.processInfo.systemUptime
        manager.move(icon, to: .shown)
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let saved = UserDefaults.standard.dictionary(forKey: "flux.macOS27IconLayout")
                guard !manager.isUpdatingIcons,
                      (saved?["hidden"] as? [String])?.contains("com.flux.icon-fixture") == false else {
                    print("FAIL: closing management lost the pending programmatic Shown assignment")
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
                    print("FAIL: the overlapping native cancellation did not deliver mouse-up")
                    exit(1)
                }
                let saved = UserDefaults.standard.dictionary(forKey: "flux.macOS27IconLayout")
                geometry("after-overlap-cancel")
                let fresh = MenuBarIconManager()
                fresh.boundaryProvider = manager.boundaryProvider
                fresh.refresh()
                let items = fresh.icons.filter { $0.id.hasPrefix("com.flux.icon-fixture|") }
                guard (saved?["hidden"] as? [String])?.contains("com.flux.icon-fixture") == false,
                      (saved?["alwaysHidden"] as? [String])?.contains("com.flux.icon-fixture") == false,
                      items.count == 1, items[0].section == .shown,
                      MenuBarIconManager.section(for: items[0].frame,
                                                boundaries: manager.boundaryProvider()) == .shown else {
                    print("FAIL: cancelling the second native drag lost the first completed Shown move")
                    exit(1)
                }
                print("PASS: delayed callbacks preserve the completed native move after a later cancelled drag")
                finish()
            }
        }
        do { try driver.run() }
        catch { print("FAIL: overlapping native driver launch: \(error)"); exit(1) }
        Thread.sleep(forTimeInterval: 0.75)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let saved = UserDefaults.standard.dictionary(forKey: "flux.macOS27IconLayout")
            manager.refresh()
            print("OVERLAP held buttons=\(NSEvent.pressedMouseButtons) actual=\(String(describing: fixture()?.frame)) controls=\(manager.boundaryProvider()) saved=\(String(describing: saved))")
            guard NSEvent.pressedMouseButtons & 1 != 0, let current = fixture(),
                  MenuBarIconManager.section(for: current.frame,
                                            boundaries: manager.boundaryProvider()) == .alwaysHidden else {
                print("FAIL: the overlapping native control did not hold an unfinished Always Hidden drag")
                exit(1)
            }
            guard (saved?["alwaysHidden"] as? [String])?.contains("com.flux.icon-fixture") == false else {
                print("FAIL: an older native callback saved the unfinished second drag as Always Hidden")
                exit(1)
            }
            print("PASS: the held second native drag has not overwritten saved assignments")
        }
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
                    print("FAIL: the native Command move to Shown did not persist")
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
        if CommandLine.arguments.contains("--native-close") || CommandLine.arguments.contains("--native-overlap")
            || CommandLine.arguments.contains("--native-geometry") {
            nativeMove()
            return
        }
        if CommandLine.arguments.contains("--move-close") {
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
        "Sources/Flux/Support/Theme.swift", "Sources/Flux/Support/Log.swift",
        "Sources/Flux/Support/AccessibilityAccess.swift"])
    close_test = options.native_close or options.move_close or options.native_overlap or options.native_geometry
    geometry = temporary / "geometry"
    geometry.mkdir()
    fixture_flags = (["--single"] if close_test else [])
    if options.native_geometry:
        fixture_flags += ["--geometry-output", str(geometry / "fixture.json")]
    process = subprocess.Popen([str(fixture)] + fixture_flags, start_new_session=True)
    started_at = time.time()
    try:
        flags = (["--native-close"] if options.native_close else
                 (["--move-close"] if options.move_close else (["--native-overlap"] if options.native_overlap else
                  (["--native-geometry"] if options.native_geometry else []))))
        if options.native_geometry:
            flags += ["--geometry-output", str(geometry)]
        command([str(binary), str(fixture)] + flags, 30)
        if options.native_geometry:
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
