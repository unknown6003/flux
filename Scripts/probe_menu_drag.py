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
import struct
import sys
import time
import zlib


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
    let captureOffControl: Bool
    var controlSnapshot = 0
    init(state: String, busyOnly: Bool, captureOffControl: Bool) {
        self.state = state; self.busyOnly = busyOnly; self.captureOffControl = captureOffControl
    }
    func captureIsAbsent() -> Bool {
        guard !controller.isMenuBarDragging, let taps = ownTapStates(), taps.isEmpty,
              returnDestinations().isEmpty else { return false }
        return NSApp.windows.allSatisfy {
            !($0.contentView is MenuBarDragSourceView) && !($0.contentView is MenuBarDragDestinationView)
        }
    }
    func returnDestinations() -> [(NSWindow, MenuBarDragDestinationView)] {
        NSApp.windows.compactMap { candidate in
            guard candidate !== window, candidate.isVisible,
                  let target = candidate.contentView?.subviews.compactMap({ $0 as? MenuBarDragDestinationView })
                    .first(where: { $0.section == .shown && $0.showsReturnHint }) else { return nil }
            return (candidate, target)
        }
    }
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
                guard (self.captureOffControl ? self.captureIsAbsent() : self.controller.isMenuBarDragging),
                      currentConfiguration == enabledConfiguration else {
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
                        if self.captureOffControl, FileManager.default.fileExists(atPath: self.state + ".refresh") {
                            try? FileManager.default.removeItem(atPath: self.state + ".refresh")
                            self.manager.refresh()
                            self.controlSnapshot += 1
                        }
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
            if self.captureOffControl {
                self.controller.close()
                guard self.captureIsAbsent() else {
                    print("BLOCKED: capture-off control still has an input tap or drag window"); fflush(stdout); exit(5)
                }
            } else {
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
        let returnX = min(max(window.frame.maxX + 20, primary.frame.minX),
                          max(primary.frame.minX, primary.frame.maxX - 250))
        let returnY = primary.frame.maxY - max(NSStatusBar.system.thickness, primary.safeAreaInsets.top) - 64 - 8
        targets["bar"] = center(NSRect(x: returnX, y: returnY, width: 230, height: 64))
        targets["invalid"] = cg(NSPoint(x: primary.frame.minX + 30, y: primary.frame.minY + 80))
        let sourceWindow = manager.icons.first.flatMap { icon in
            NSApp.windows.first { window in
                guard window.isVisible, let source = window.contentView as? MenuBarDragSourceView else { return false }
                return source.icon?.id == icon.id && source.icon?.title == icon.title
            }
        }
        let gripFrame = sourceWindow.map { window in
            [Double(window.frame.minX), Double(primary.frame.maxY - window.frame.maxY),
             Double(window.frame.width), Double(window.frame.height)]
        } ?? []
        let nativeSource = manager.icons.first
        let neighbor = manager.icons.dropFirst().first
        let nativeTarget: [Double] = nativeSource.flatMap { source in
            neighbor.map { other in
                [Double(source.frame.midX > other.frame.midX ? other.frame.minX - 12 : other.frame.maxX + 12),
                 Double(source.frame.midY)]
            }
        } ?? []
        var state: [String: Any] = [
            "ready": row != nil || captureOffControl, "pid": ProcessInfo.processInfo.processIdentifier,
            "mode": controller.isMenuBarDragging, "commits": commits, "events": events,
            "moving": manager.isUpdatingIcons, "taps": ownTapStates() ?? [],
            "labels": manager.labels,
            "buttons": NSEvent.pressedMouseButtons,
            "source": sourceWindow.map { center($0.frame) } ?? [],
            "icon": manager.icons.first.map { [Double($0.frame.midX), Double($0.frame.midY)] } ?? [],
            "neighbor": neighbor.map { [Double($0.frame.midX), Double($0.frame.midY)] } ?? [],
            "neighborFrame": neighbor.map { [Double($0.frame.minX), Double($0.frame.minY), Double($0.frame.width), Double($0.frame.height)] } ?? [],
            "nativeTarget": nativeTarget,
            "gripFrame": gripFrame,
            "iconFrame": manager.icons.first.map { [Double($0.frame.minX), Double($0.frame.minY),
                                                    Double($0.frame.width), Double($0.frame.height)] } ?? [],
            "row": center(window.convertToScreen(root.convert(row?.frame ?? .zero, to: nil))),
            "returnTrays": returnDestinations().map { candidate, target -> [String: Any] in
                let targetFrame = candidate.convertToScreen(target.convert(target.bounds, to: nil))
                let windowTop = cg(NSPoint(x: candidate.frame.minX, y: candidate.frame.maxY))
                let targetTop = cg(NSPoint(x: targetFrame.minX, y: targetFrame.maxY))
                return ["window": candidate.windowNumber, "attached": target.window === candidate,
                    "registered": target.registeredDraggedTypes.contains(MenuBarDragController.pasteboardType),
                    "types": target.registeredDraggedTypes.map(\.rawValue),
                    "frame": windowTop + [Double(candidate.frame.width), Double(candidate.frame.height)],
                    "targetFrame": targetTop + [Double(targetFrame.width), Double(targetFrame.height)],
                    "level": candidate.level.rawValue, "opaque": candidate.isOpaque,
                    "panel": candidate is NSPanel, "canKey": candidate.canBecomeKey,
                    "canMain": candidate.canBecomeMain]
            },
            "targets": targets,
            "screens": NSScreen.screens.map { ["x": $0.frame.minX, "y": $0.frame.minY,
                                               "width": $0.frame.width, "height": $0.frame.height] }
        ]
        if captureOffControl {
            state["control"] = ["captureOff": captureIsAbsent(), "tapQuerySucceeded": ownTapStates() != nil,
                "sourceWindows": NSApp.windows.filter { $0.contentView is MenuBarDragSourceView }.count,
                "returnWindows": returnDestinations().count,
                "snapshot": controlSnapshot,
                "fixtureID": manager.icons.first?.id ?? "",
                "fixtureTitle": manager.icons.first?.title ?? "",
                "fixtureFrame": manager.icons.first.map {
                    [Double($0.frame.minX), Double($0.frame.minY), Double($0.frame.width), Double($0.frame.height)]
                } ?? []] as [String: Any]
        }
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
func fixture(seconds: Double, emptyTitle: Bool, geometryPath: String) {
    NSApp.setActivationPolicy(.accessory)
    let a = NSStatusBar.system.statusItem(withLength: 36)
    a.button?.title = "FXD"
    a.button?.setAccessibilityTitle(emptyTitle ? "" : "Flux drag fixture")
    if emptyTitle { a.button?.setAccessibilityLabel("Flux drag fixture") }
    let b = NSStatusBar.system.statusItem(withLength: 36)
    b.button?.title = "FXE"
    b.button?.setAccessibilityTitle("Flux drag neighbour")
    for (item, color) in [(a, NSColor.magenta), (b, NSColor.cyan)] {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 18, height: 18).fill()
        image.unlockFocus()
        image.isTemplate = false
        item.button?.image = image
        item.button?.imagePosition = .imageOnly
    }
    let geometryTimer = Timer(timeInterval: 0.1, repeats: true) { _ in
        MainActor.assumeIsolated {
            guard FileManager.default.fileExists(atPath: geometryPath + ".request") else { return }
            let request = (try? String(contentsOfFile: geometryPath + ".request", encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(atPath: geometryPath + ".request")
            func rect(_ frame: NSRect) -> [Double] {
                [Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)]
            }
            let items: [[String: Any]] = [a, b].map { item in
                guard let button = item.button, let window = button.window else { return ["missingWindow": true] }
                return ["window": window.windowNumber, "windowFrameAppKit": rect(window.frame),
                        "buttonBounds": rect(button.bounds),
                        "buttonScreenFrameAppKit": rect(window.convertToScreen(button.convert(button.bounds, to: nil)))]
            }
            let value: [String: Any] = ["uptime": ProcessInfo.processInfo.systemUptime,
                "request": request, "pid": ProcessInfo.processInfo.processIdentifier, "items": items]
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: geometryPath), options: .atomic)
            }
        }
    }
    RunLoop.main.add(geometryTimer, forMode: .common)
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        NSStatusBar.system.removeStatusItem(a)
        NSStatusBar.system.removeStatusItem(b)
        exit(0)
    }
    NSApp.run()
}

@MainActor
func geometry(path: String, x: Double, y: Double) {
    let started = ProcessInfo.processInfo.systemUptime
    let manager = MenuBarIconManager()
    manager.refresh()
    var value: [String: Any] = ["started": started, "pointCG": [x, y], "freshIcons": manager.icons.map {
        ["id": $0.id, "title": $0.title,
         "frameCG": [Double($0.frame.minX), Double($0.frame.minY), Double($0.frame.width), Double($0.frame.height)]] as [String: Any]
    }]
    value["freshOwnerReadFinished"] = ProcessInfo.processInfo.systemUptime
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 0.15)
    var hit: AXUIElement?
    value["hitStarted"] = ProcessInfo.processInfo.systemUptime
    let status = AXUIElementCopyElementAtPosition(system, Float(x), Float(y), &hit)
    value["hitFinished"] = ProcessInfo.processInfo.systemUptime
    value["hitStatus"] = status.rawValue
    if let hit {
        AXUIElementSetMessagingTimeout(hit, 0.15)
        var pid: pid_t = 0
        value["pidStatus"] = AXUIElementGetPid(hit, &pid).rawValue
        value["hitPID"] = pid
        if let app = NSRunningApplication(processIdentifier: pid) {
            value["hitOwner"] = ["bundleID": app.bundleIdentifier ?? "", "name": app.localizedName ?? ""]
        }
        var attributes: [String: Any] = [:]
        for name in [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                     kAXIdentifierAttribute, kAXPositionAttribute, kAXSizeAttribute] {
            var result: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(hit, name as CFString, &result)
            var record: [String: Any] = ["status": error.rawValue]
            if let result {
                if let string = result as? String { record["value"] = string }
                else if CFGetTypeID(result) == AXValueGetTypeID() {
                    var point = CGPoint.zero
                    var size = CGSize.zero
                    if AXValueGetValue(result as! AXValue, .cgPoint, &point) { record["value"] = [point.x, point.y] }
                    else if AXValueGetValue(result as! AXValue, .cgSize, &size) { record["value"] = [size.width, size.height] }
                }
            }
            attributes[name] = record
        }
        value["hitAttributes"] = attributes
        if let owner = NSRunningApplication.runningApplications(withBundleIdentifier: "com.flux.menu-drag-fixture").first {
            value["ownerAfterHitStarted"] = ProcessInfo.processInfo.systemUptime
            let app = AXUIElementCreateApplication(owner.processIdentifier)
            AXUIElementSetMessagingTimeout(app, 0.15)
            var bar: CFTypeRef?
            value["ownerBarStatus"] = AXUIElementCopyAttributeValue(app, kAXExtrasMenuBarAttribute as CFString, &bar).rawValue
            if let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() {
                AXUIElementSetMessagingTimeout(bar as! AXUIElement, 0.15)
                var children: CFTypeRef?
                value["ownerChildrenStatus"] = AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children).rawValue
                if let children = children as? [AXUIElement] {
                    value["hitEqualOwnerChildren"] = children.enumerated().map {
                        ["index": $0.offset, "equal": CFEqual(hit, $0.element)] as [String: Any]
                    }
                    value["ownerChildrenAfterHit"] = children.enumerated().map { pair -> [String: Any] in
                        AXUIElementSetMessagingTimeout(pair.element, 0.15)
                        var record: [String: Any] = ["index": pair.offset, "equalHit": CFEqual(hit, pair.element),
                            "started": ProcessInfo.processInfo.systemUptime]
                        for name in [kAXTitleAttribute, kAXPositionAttribute, kAXSizeAttribute] {
                            var result: CFTypeRef?
                            let status = AXUIElementCopyAttributeValue(pair.element, name as CFString, &result)
                            var attribute: [String: Any] = ["status": status.rawValue]
                            if let result {
                                if let text = result as? String { attribute["value"] = text }
                                else if CFGetTypeID(result) == AXValueGetTypeID() {
                                    var point = CGPoint.zero
                                    var size = CGSize.zero
                                    if AXValueGetValue(result as! AXValue, .cgPoint, &point) { attribute["value"] = [point.x, point.y] }
                                    else if AXValueGetValue(result as! AXValue, .cgSize, &size) { attribute["value"] = [size.width, size.height] }
                                }
                            }
                            record[name] = attribute
                        }
                        record["finished"] = ProcessInfo.processInfo.systemUptime
                        return record
                    }
                }
            }
            value["ownerAfterHitFinished"] = ProcessInfo.processInfo.systemUptime
        }
    }
    if let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] {
        let fixturePIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.flux.menu-drag-fixture").map(\.processIdentifier))
        let agentPIDs = Set(NSWorkspace.shared.runningApplications.filter {
            (($0.bundleIdentifier ?? "") + ($0.localizedName ?? "")).lowercased().contains("menubaragent")
        }.map(\.processIdentifier))
        value["fixtureAndAgentWindows"] = windows.filter {
            let pid = ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? -1
            let name = ($0[kCGWindowOwnerName as String] as? String ?? "").lowercased()
            return fixturePIDs.contains(pid) || agentPIDs.contains(pid) || name.contains("menubaragent")
        }
        let hostDeadline = ProcessInfo.processInfo.systemUptime + 1
        var hostNodes: [[String: Any]] = []
        var hostRoots: [[String: Any]] = []
        for pid in agentPIDs {
            guard hostNodes.count < 100, ProcessInfo.processInfo.systemUptime < hostDeadline else { break }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.03)
            var root: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(app, kAXExtrasMenuBarAttribute as CFString, &root)
            hostRoots.append(["pid": pid, "status": status.rawValue])
            guard let root, CFGetTypeID(root) == AXUIElementGetTypeID() else { continue }
            var queue: [(AXUIElement, Int)] = [(root as! AXUIElement, 0)]
            var visited: [AXUIElement] = []
            while !queue.isEmpty, hostNodes.count < 100, ProcessInfo.processInfo.systemUptime < hostDeadline {
                let (element, depth) = queue.removeFirst()
                guard !visited.contains(where: { CFEqual($0, element) }) else { continue }
                visited.append(element)
                AXUIElementSetMessagingTimeout(element, 0.03)
                var elementPID: pid_t = 0
                let pidStatus = AXUIElementGetPid(element, &elementPID)
                var node: [String: Any] = ["hostPID": pid, "depth": depth, "pid": elementPID,
                    "pidStatus": pidStatus.rawValue, "equalHit": hit.map { CFEqual($0, element) } ?? false]
                for name in [kAXRoleAttribute, kAXTitleAttribute, kAXIdentifierAttribute, kAXPositionAttribute, kAXSizeAttribute] {
                    var result: CFTypeRef?
                    let status = AXUIElementCopyAttributeValue(element, name as CFString, &result)
                    var attribute: [String: Any] = ["status": status.rawValue]
                    if let result {
                        if let text = result as? String { attribute["value"] = text }
                        else if CFGetTypeID(result) == AXValueGetTypeID() {
                            var point = CGPoint.zero
                            var size = CGSize.zero
                            if AXValueGetValue(result as! AXValue, .cgPoint, &point) { attribute["value"] = [point.x, point.y] }
                            else if AXValueGetValue(result as! AXValue, .cgSize, &size) { attribute["value"] = [size.width, size.height] }
                        }
                    }
                    node[name] = attribute
                }
                hostNodes.append(node)
                if depth < 6 {
                    var children: CFTypeRef?
                    let status = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
                    hostNodes[hostNodes.count - 1]["childrenStatus"] = status.rawValue
                    if let children = children as? [AXUIElement] {
                        queue.append(contentsOf: children.prefix(100 - hostNodes.count).map { ($0, depth + 1) })
                    }
                }
            }
        }
        value["hostExtras"] = ["candidatePIDs": Array(agentPIDs), "roots": hostRoots, "nodes": hostNodes,
            "nodeLimit": 100, "depthLimit": 6, "deadlineReached": ProcessInfo.processInfo.systemUptime >= hostDeadline]
        value["windowsAtPoint"] = windows.filter {
            guard let bounds = $0[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return frame.contains(CGPoint(x: x, y: y))
        }.map { ["window": $0[kCGWindowNumber as String] ?? -1, "pid": $0[kCGWindowOwnerPID as String] ?? -1,
                 "layer": $0[kCGWindowLayer as String] ?? -1, "bounds": $0[kCGWindowBounds as String] ?? [:]] }
    }
    value["finished"] = ProcessInfo.processInfo.systemUptime
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { exit(9) }
    do { try data.write(to: URL(fileURLWithPath: path), options: .atomic) } catch { exit(9) }
}

func drive(statePath: String, source: String, destination: String, kind: String) {
    print("driver pid=\(ProcessInfo.processInfo.processIdentifier)")
    fflush(stdout)
    guard CGPreflightPostEventAccess(),
          let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
          let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let start = state[source] as? [Double], start.count == 2,
          let targets = state["targets"] as? [String: [Double]],
          let target = destination == "native" ? state["nativeTarget"] as? [Double] : targets[destination],
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
    func registeredReturnTrays() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let trays = state["returnTrays"] as? [[String: Any]] else { return [] }
        func containsTarget(_ value: Any?) -> Bool {
            guard let frame = value as? [Double], frame.count == 4 else { return false }
            return CGRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3])
                .contains(CGPoint(x: target[0], y: target[1]))
        }
        return trays.filter {
            $0["attached"] as? Bool == true && $0["registered"] as? Bool == true
                && containsTarget($0["frame"]) && containsTarget($0["targetFrame"])
        }
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
    Thread.sleep(forTimeInterval: 0.15)
    if destination == "bar" {
        guard waitFor({ $0.contains(where: { $0.hasPrefix("native began ") }) && !registeredReturnTrays().isEmpty }) else {
            fail("actual registered return tray does not contain the endpoint after native begin")
        }
        print("RETURN TRAY target=\(target) actual=\(registeredReturnTrays())")
        fflush(stdout)
    }
    if !command && kind != "late-command" && destination != "invalid" {
        let section = destination == "bar" ? "shown" : destination
        guard waitFor({ $0.contains("entered \(section) valid=true") }) else {
            fail("destination never accepted the session")
        }
    }
    if kind == "escape" {
        key(53, true); key(53, false)
        guard waitFor({ $0.contains("ended operation=0") }) else { fail("Escape did not end the session") }
    }
    mouse(.leftMouseUp, target, command || kind == "late-command" ? .maskCommand : [])
    key(55, false)
    Thread.sleep(forTimeInterval: 0.35)
}

@main
struct Main {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if args[1] == "--fixture" { let _ = NSApplication.shared; fixture(seconds: Double(args[2])!, emptyTitle: args.contains("--empty-title"), geometryPath: args[3]) }
        else if args[1] == "--geometry" { geometry(path: args[2], x: Double(args[3])!, y: Double(args[4])!) }
        else if args[1] == "--drive" { drive(statePath: args[2], source: args[3], destination: args[4], kind: args[5]) }
        else if args[1] == "--release" {
            if CGPreflightPostEventAccess() {
                let point = CGEvent(source: nil)!.location
                CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                        mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: false)?.post(tap: .cghidEventTap)
            }
        }
        else { let _ = NSApplication.shared; Probe(state: args[2], busyOnly: args.contains("--busy-only"), captureOffControl: args.contains("--capture-off-control")).start(seconds: Double(args[3])!) }
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


def marker_pixels(path, region):
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise RuntimeError("BLOCKED marker capture is not PNG")
    offset, compressed = 8, bytearray()
    while offset + 12 <= len(data):
        size = struct.unpack(">I", data[offset:offset + 4])[0]
        kind, value = data[offset + 4:offset + 8], data[offset + 8:offset + 8 + size]
        if kind == b"IHDR":
            width, height, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", value)
        if kind == b"IDAT":
            compressed.extend(value)
        offset += size + 12
    if depth != 8 or color not in (2, 6) or interlace or width * height > 2_000_000:
        raise RuntimeError(f"BLOCKED unsupported marker PNG: {width}x{height} depth={depth} color={color} interlace={interlace}")
    channels = 3 if color == 2 else 4
    stride = width * channels
    raw = zlib.decompress(compressed)
    if len(raw) != (stride + 1) * height:
        raise RuntimeError("BLOCKED truncated marker PNG")
    previous, masks = bytearray(stride), {"magenta": set(), "cyan": set()}
    def paeth(a, b, c):
        p = a + b - c
        distances = [abs(p - a), abs(p - b), abs(p - c)]
        return (a, b, c)[distances.index(min(distances))]
    for y in range(height):
        method = raw[y * (stride + 1)]
        row = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            left = row[i - channels] if i >= channels else 0
            up, corner = previous[i], previous[i - channels] if i >= channels else 0
            if method == 1: row[i] = (row[i] + left) & 255
            elif method == 2: row[i] = (row[i] + up) & 255
            elif method == 3: row[i] = (row[i] + (left + up) // 2) & 255
            elif method == 4: row[i] = (row[i] + paeth(left, up, corner)) & 255
            elif method != 0: raise RuntimeError(f"BLOCKED unsupported PNG filter {method}")
        for x in range(width):
            r, g, b = row[x * channels:x * channels + 3]
            if channels == 4 and row[x * channels + 3] < 200:
                continue
            if r > 175 and b > 175 and g < 100: masks["magenta"].add((x, y))
            if g > 175 and b > 175 and r < 100: masks["cyan"].add((x, y))
        previous = row
    scale_x, scale_y = width / region[2], height / region[3]
    result = {"pixels": [width, height], "scale": [scale_x, scale_y], "regionCG": region, "markers": {}}
    for name, remaining in masks.items():
        candidates = []
        while remaining:
            stack, component = [remaining.pop()], []
            while stack:
                x, y = stack.pop()
                component.append((x, y))
                for point in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]:
                    if point in remaining:
                        remaining.remove(point)
                        stack.append(point)
            xs, ys = zip(*component)
            w, h = (max(xs) - min(xs) + 1) / scale_x, (max(ys) - min(ys) + 1) / scale_y
            if abs(w - 18) <= 3 and abs(h - 18) <= 3 and len(component) >= 200 * scale_x * scale_y:
                candidates.append({"count": len(component), "sizePoints": [w, h],
                    "centroidCG": [region[0] + (sum(xs) / len(xs) + 0.5) / scale_x,
                                   region[1] + (sum(ys) / len(ys) + 0.5) / scale_y]})
        if len(candidates) != 1:
            raise RuntimeError(f"BLOCKED marker {name} absent or ambiguous: candidates={candidates}; capture={path}")
        result["markers"][name] = candidates[0]
    return result


def observe_geometry(binary, output, state, phase):
    screens = state["screens"]
    if len(screens) != 1 or screens[0]["x"] != 0 or screens[0]["y"] != 0:
        raise RuntimeError("BLOCKED marker control requires one primary display at origin")
    region = [0, 0, int(screens[0]["width"]), min(96, int(screens[0]["height"]))]
    started = time.monotonic()
    fixture_path = output / "fixture-geometry.json"
    request = f"{phase}:{started}"
    Path(str(fixture_path) + ".request").write_text(request)
    deadline = time.monotonic() + 1.5
    own = None
    while time.monotonic() < deadline:
        try:
            value = json.loads(fixture_path.read_text())
            if value["request"] == request:
                own = value
                break
        except (OSError, ValueError):
            pass
        time.sleep(0.02)
    if own is None:
        raise RuntimeError("BLOCKED fixture own-window snapshot deadline")
    png, capture_log = output / f"{phase}.png", output / f"{phase}-capture.log"
    capture_started = time.monotonic()
    try:
        bounded(["/usr/sbin/screencapture", "-x", "-t", "png", "-R" + ",".join(map(str, region)), str(png)], 3, capture_log)
    except RuntimeError as error:
        detail = capture_log.read_text(errors="replace") if capture_log.exists() else "no capture log"
        raise RuntimeError(f"BLOCKED native screenshot: {error}; {detail}") from error
    capture_finished = time.monotonic()
    pixels = marker_pixels(png, region)
    point = pixels["markers"]["magenta"]["centroidCG"]
    ax_path = output / f"{phase}-ax.json"
    bounded([str(binary), "--geometry", str(ax_path), str(point[0]), str(point[1])], 3, output / f"{phase}-ax.log")
    ax = json.loads(ax_path.read_text())
    if len(ax["freshIcons"]) != 2:
        raise RuntimeError(f"BLOCKED fresh owner AX inventory missing: {ax}")
    frame = ax["freshIcons"][0]["frameCG"]
    record = {"phase": phase, "started": started, "finished": time.monotonic(), "own": own,
              "captureStarted": capture_started, "captureFinished": capture_finished, "screen": screens[0],
              "pixels": pixels, "ax": ax, "cachedIconFrame": state["iconFrame"],
              "originalDriverIconPoint": state["icon"],
              "neighborFrame": state["neighborFrame"], "nativeTarget": state["nativeTarget"],
              "pixelMinusFreshAXCenter": [point[0] - frame[0] - frame[2] / 2,
                                          point[1] - frame[1] - frame[3] / 2]}
    (output / f"{phase}-geometry.json").write_text(json.dumps(record, indent=2))
    print("GEOMETRY " + json.dumps(record, sort_keys=True), flush=True)
    return record


def validate_native_start(state, observation):
    markers = observation["pixels"]["markers"]
    source = markers["magenta"]["centroidCG"]
    neighbor = markers["cyan"]["centroidCG"]
    fresh = observation["ax"]["freshIcons"]
    for frame, point in [(state["iconFrame"], source), (state["neighborFrame"], neighbor),
                         (fresh[0]["frameCG"], source), (fresh[1]["frameCG"], neighbor)]:
        if len(frame) != 4 or abs(frame[0] + frame[2] / 2 - point[0]) > 2 or abs(frame[1] + frame[3] / 2 - point[1]) > 2:
            raise RuntimeError(f"INVALID native start AX/marker mismatch: frame={frame} marker={point}")
    if (observation["ax"].get("hitPID") != observation["own"]["pid"]
            or observation["ax"].get("hitAttributes", {}).get("AXTitle", {}).get("value") != "Flux drag fixture"):
        raise RuntimeError("INVALID magenta marker hit does not identify the disposable primary fixture")
    target = state["nativeTarget"]
    frame = state["neighborFrame"]
    if (len(target) != 2 or state["buttons"] or abs(state["icon"][0] - source[0]) > 2
            or abs(state["icon"][1] - source[1]) > 2 or abs(target[1] - source[1]) > 2
            or not 0 < target[0] < state["screens"][0]["width"]
            or not (target[0] < frame[0] if source[0] > neighbor[0] else target[0] > frame[0] + frame[2])):
        raise RuntimeError(f"INVALID native target does not cross current neighbor: source={source} neighbor={frame} target={target}")
    print(f"NATIVE START source={source} neighbor={neighbor} nativeTarget={target} freshAX={fresh}", flush=True)


def record_native_pixels(before, after, output, phase):
    a = before["pixels"]["markers"]
    b = after["pixels"]["markers"]
    result = {"magentaPixelDelta": [y - x for x, y in zip(a["magenta"]["centroidCG"], b["magenta"]["centroidCG"])],
              "beforeMagenta": a["magenta"]["centroidCG"], "beforeCyan": a["cyan"]["centroidCG"],
              "afterMagenta": b["magenta"]["centroidCG"], "afterCyan": b["cyan"]["centroidCG"],
              "orderSwapped": ((a["magenta"]["centroidCG"][0] - a["cyan"]["centroidCG"][0])
                               * (b["magenta"]["centroidCG"][0] - b["cyan"]["centroidCG"][0]) < 0),
              "before": before["pixelMinusFreshAXCenter"], "after": after["pixelMinusFreshAXCenter"]}
    (output / f"{phase}-geometry-comparison.json").write_text(json.dumps(result, indent=2))
    print("GEOMETRY comparison " + json.dumps(result), flush=True)
    return result


def require_native_pixels(result):
    if abs(result["magentaPixelDelta"][0]) < 10 or not result["orderSwapped"]:
        raise RuntimeError(f"native fixture pixels did not move across the disposable neighbor: {result}")


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
        "command-held", "command-rapid", "command-down-only", "command-down-only-control"), help="Run one independent native scenario")
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
        fixture_argv = [str(fixture_binary), "--fixture", str(args.seconds + 5), str(args.output / "fixture-geometry.json")]
        if args.empty_title:
            fixture_argv.append("--empty-title")
        for argv, name in ((fixture_argv, "fixture.log"),
                           ([str(binary), "--probe", str(args.output / "state.json"), str(args.seconds)]
                            + (["--busy-only"] if args.busy_only else [])
                            + (["--capture-off-control"] if args.case == "command-down-only-control" else []), "probe.log")):
            with (args.output / name).open("wb") as log:
                processes.append(subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT, start_new_session=True))
        probe = processes[-1]
        state_path = args.output / "state.json"
        state = wait_state(state_path, probe)
        if args.case != "command-down-only-control":
            grip, icon = state["gripFrame"], state["iconFrame"]
            if len(grip) != 4 or len(icon) != 4 or not state["source"]:
                raise RuntimeError("production grip window was not found")
            intersects = (grip[0] < icon[0] + icon[2] and icon[0] < grip[0] + grip[2]
                          and grip[1] < icon[1] + icon[3] and icon[1] < grip[1] + grip[3])
            if intersects or grip[1] < icon[1] + icon[3]:
                raise RuntimeError(f"grip overlaps or is not below the actual icon: {grip} vs {icon}")
            print(f"GRIP {grip}; original icon {icon}; native Command targets ICON CENTER {state['icon']}", flush=True)
        if args.empty_title and not any(label["rawTitle"] == "" and label["normalized"]
                                        for label in state["labels"]):
            raise RuntimeError(f"fixture did not expose an empty AXTitle: {state['labels']}")
        started = time.monotonic()
        results = []
        if args.case == "command-down-only-control":
            def snapshot():
                previous = wait_state(state_path, probe, 1)["control"]["snapshot"]
                Path(str(state_path) + ".refresh").touch()
                deadline = time.monotonic() + 2
                while time.monotonic() < deadline:
                    value = wait_state(state_path, probe, 1)
                    control = value["control"]
                    if control["snapshot"] > previous:
                        if (value["mode"] or value["taps"] or not control["captureOff"]
                                or not control["tapQuerySucceeded"] or control["sourceWindows"]
                                or control["returnWindows"]):
                            raise RuntimeError(f"capture-off control is armed: {value}")
                        return value
                    time.sleep(0.02)
                raise RuntimeError("capture-off fresh AX snapshot deadline")

            before_state = snapshot()
            before_control = before_state["control"]
            frame_before = before_control["fixtureFrame"]
            if len(frame_before) != 4 or not before_control["fixtureTitle"] or before_state["buttons"]:
                raise RuntimeError(f"capture-off missing original fixture frame: {before_control}")
            print(f"CONTROL before mode={before_state['mode']} taps={before_state['taps']} {before_control}", flush=True)
            geometry_before = observe_geometry(binary, args.output, before_state, "command-down-only-control-before")
            validate_native_start(before_state, geometry_before)
            event_offset = len(before_state["events"])
            bounded([str(binary), "--drive", str(state_path), "icon", "native", "down-only"],
                    4, args.output / "command-down-only-control.log")
            deadline = time.monotonic() + 4
            geometry_after = observe_geometry(binary, args.output, wait_state(state_path, probe, 2), "command-down-only-control-after")
            movement = record_native_pixels(geometry_before, geometry_after, args.output, "command-down-only-control")
            state = snapshot()
            while (len(state["control"]["fixtureFrame"]) == 4
                   and abs(state["control"]["fixtureFrame"][0] - frame_before[0]) < 10
                   and time.monotonic() < deadline):
                time.sleep(0.05)
                state = snapshot()
            after_control = state["control"]
            frame_after = after_control["fixtureFrame"]
            evidence = {"before": before_state, "after": state}
            (args.output / "control.json").write_text(json.dumps(evidence, indent=2))
            print(f"CONTROL after mode={state['mode']} taps={state['taps']} {after_control}", flush=True)
            if state["screens"] != before_state["screens"]:
                raise RuntimeError("capture-off display geometry changed during the control")
            if (after_control["fixtureTitle"] != before_control["fixtureTitle"] or len(frame_after) != 4
                    or frame_after[2:] != frame_before[2:] or frame_after[1] != frame_before[1]):
                raise RuntimeError(f"capture-off fixture identity/size/row changed: {frame_before} -> {frame_after}")
            if any(event.startswith(("tap down", "source down", "begin ", "native began ", "commit "))
                   for event in state["events"][event_offset:]) or state["commits"] or state["buttons"]:
                raise RuntimeError(f"capture-off input was captured or left held: {state}")
            if abs(frame_after[0] - frame_before[0]) < 10:
                raise RuntimeError(f"capture-off down-only driver did not move fixture: {frame_before} -> {frame_after}")
            require_native_pixels(movement)
            results.append(f"PASS capture-off down-only native frame movement {frame_before} -> {frame_after}")
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
            observe_geometry(binary, args.output, state, f"{name}-before")
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
            prepared = [event for event in events if event.startswith("prepared ")]
            performed = [event for event in events if event.startswith("performed ")]
            if expected and (prepared != [f"prepared {expected} valid=true"]
                             or performed != [f"performed {expected} valid=true"]):
                raise RuntimeError(f"native prepare/perform callbacks missing: {events}")
            if not expected and performed:
                raise RuntimeError(f"cancelled or invalid drag performed a drop: {events}")
            results.append(f"PASS {source} -> {destination} {kind}")
        # Both keys arrive before down in these cases, with no run-loop delay in rapid.
        # Reorder only a disposable item, and require actual geometry movement.
        for kind in (() if args.busy_only else ("held", "rapid", "down-only")):
            if args.case not in ("all", f"command-{kind}"):
                continue
            state = wait_state(state_path, probe, 2)
            if not state["mode"] or not state["taps"] or not all(state["taps"]):
                raise RuntimeError("drag mode stopped before the native Command check")
            geometry_before = observe_geometry(binary, args.output, state, f"command-{kind}-before")
            validate_native_start(state, geometry_before)
            start = state["icon"]
            events_before = len(state["events"])
            commits_before = len(state["commits"])
            # The temporary bar destination exists only in Flux sessions. Native
            # Command gestures must reach the real fixture without a Flux session.
            bounded([str(binary), "--drive", str(state_path), "icon", "native", kind],
                    4, args.output / f"command-{kind}.log")
            position_deadline = time.monotonic() + 4
            geometry_after = observe_geometry(binary, args.output, wait_state(state_path, probe, 2), f"command-{kind}-after")
            movement = record_native_pixels(geometry_before, geometry_after, args.output, f"command-{kind}")
            state = wait_state(state_path, probe, 2)
            while abs(state["icon"][0] - start[0]) < 10 and time.monotonic() < position_deadline:
                time.sleep(0.05)
                state = wait_state(state_path, probe, 1)
            new_events = state["events"][events_before:]
            if not state["mode"] or "tap down command=true" not in new_events:
                raise RuntimeError(f"Command {kind} did not exercise the armed event tap")
            if any(e.startswith("source down") or e.startswith("begin ") for e in new_events):
                raise RuntimeError(f"Command {kind} was intercepted: {new_events}")
            if (any(e.startswith(("native began ", "commit ", "ended ")) for e in new_events)
                    or len(state["commits"]) != commits_before or not state["taps"] or not all(state["taps"])):
                raise RuntimeError(f"Command {kind} lost tap or started a Flux operation: {state}")
            if abs(state["icon"][0] - start[0]) < 10:
                raise RuntimeError(f"Command {kind} did not move the disposable status item")
            require_native_pixels(movement)
            results.append(f"PASS native Command {kind} bypass and fixture movement")
        Path(str(state_path) + ".stop").touch()
        try:
            probe.wait(timeout=3)
        except subprocess.TimeoutExpired as error:
            raise RuntimeError("graceful cleanup deadline") from error
        final = json.loads(state_path.read_text())
        if final["mode"] or final["returnTrays"] or "cleanup overlays=0 returns=0 tap=none" not in final["events"][-1:]:
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
