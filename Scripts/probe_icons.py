#!/usr/bin/env python3
"""Verify Settings section moves against real menu-bar icon positions."""

import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
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
fixture_source = r'''
import AppKit
if CommandLine.arguments.count == 6 && CommandLine.arguments[1] == "--drag" {
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
    for step in 1...24 {
        let progress = CGFloat(step) / 24
        post(.leftMouseDragged, CGPoint(x: start.x + (target.x - start.x) * progress,
                                        y: start.y + (target.y - start.y) * progress))
        Thread.sleep(forTimeInterval: 0.02)
    }
    post(.leftMouseUp, target)
    exit(0)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let item = NSStatusBar.system.statusItem(withLength: 28)
item.button?.title = "FXA"
item.button?.setAccessibilityTitle("Flux fixture A")
let second = NSStatusBar.system.statusItem(withLength: 28)
second.button?.title = "FXB"
second.button?.setAccessibilityTitle("Flux fixture B")
DispatchQueue.main.asyncAfter(deadline: .now() + 60) { exit(1) }
app.run()
'''
source = r'''
import AppKit

@MainActor
func probe() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    // macOS 27 keeps both dividers narrow. A drop target must still lie in Hidden.
    let compact: MenuBarIconManager.Boundaries = (hidden: 300, alwaysHidden: 297)
    guard let x = MenuBarIconManager.insertionX(for: .hidden, iconWidth: 28, boundaries: compact),
          MenuBarIconManager.section(for: CGRect(x: x, y: 0, width: 28, height: 24),
                                     boundaries: compact) == .hidden else {
        print("FAIL: Move to Hidden targets another section when the dividers are adjacent")
        exit(1)
    }
    let chevron = ControlItem(role: .chevron, autosaveName: "flux.icon-probe.chevron")
    let hidden = ControlItem(role: .divider, autosaveName: "flux.icon-probe.hidden")
    let always = ControlItem(role: .divider, autosaveName: "flux.icon-probe.always")
    let manager = MenuBarIconManager()
    manager.boundaryProvider = {
        (hidden: chevron.statusItem.button?.window?.frame.minX,
         alwaysHidden: always.statusItem.button?.window?.frame.minX)
    }
    manager.chevronBoundaryProvider = { chevron.statusItem.button?.window?.frame.minX }
    let sections: [MenuBarSection] = [.hidden, .alwaysHidden, .shown]
    func fixture() -> MenuBarIconManager.Icon? {
        manager.icons.first { $0.title == "Flux fixture A" }
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
              let x = MenuBarIconManager.insertionX(for: .shown, iconWidth: icon.frame.width,
                                                    boundaries: manager.boundaryProvider()) else {
            print("FAIL: native move needs a readable fixture and Shown boundary")
            exit(1)
        }
        let driver = Process()
        driver.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
        driver.arguments = ["--drag", String(Double(icon.frame.midX)), String(Double(icon.frame.midY)),
                            String(Double(x + icon.frame.width / 2)), String(Double(icon.frame.midY))]
        driver.terminationHandler = { driver in
            DispatchQueue.main.async {
                guard driver.terminationStatus == 0 else {
                    print("FAIL: the independent native Command driver failed")
                    exit(1)
                }
                manager.refresh()
                guard let actual = fixture(),
                      MenuBarIconManager.section(for: actual.frame,
                                                boundaries: manager.boundaryProvider()) == .shown else {
                    print("FAIL: the native Command driver did not move the real icon to Shown")
                    exit(1)
                }
                print("PASS: native Command crossed the real Shown boundary")
                if CommandLine.arguments.contains("--native-close") {
                    manager.endIconManagement()
                    print("Closed management immediately after the native release")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
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
                    guard items.count == 2, items.allSatisfy({ $0.section == .shown }),
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
        guard items.count == 2 else {
            print("FAIL: the reorder fixture needs two readable icons")
            exit(1)
        }
        if prepared < 2 {
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
        guard ordered.allSatisfy({ MenuBarIconManager.section(for: $0.frame, boundaries: manager.boundaryProvider()) == .hidden }),
              manager.canMove(moving, toward: .towardClock) else {
            print("FAIL: the reorder fixture could not enter Hidden")
            exit(1)
        }
        manager.move(moving, toward: .towardClock)
        guard manager.isUpdatingIcons else {
            print("FAIL: the arrow move did not publish its pending verification")
            exit(1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            manager.refresh()
            let next = manager.icons.filter { $0.id.hasPrefix("com.flux.icon-fixture|") }
                .sorted { $0.frame.minX < $1.frame.minX }
            guard !manager.isUpdatingIcons, next.last?.title == moving.title else {
                print("FAIL: the Settings arrow did not change the real icon order")
                exit(1)
            }
            print("PASS: the Settings arrow changed the real icon order")
            nativeMove()
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
            if index + 1 < sections.count { move(index: index + 1) }
            else {
                reorder()
            }
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        manager.beginIconManagement()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { move(index: 0) }
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
                [str(root / dependency) for dependency in dependencies] + ["-o", str(binary)], 120)
        command(["codesign", "--force", "--sign", "-", str(app)], 20)
        return binary

    fixture = bundle("FluxIconFixture", "com.flux.icon-fixture", fixture_source, [])
    binary = bundle("FluxIconProbe", "com.flux.icon-probe", source, [
        "Sources/Flux/MenuBar/MenuBarIconManager.swift", "Sources/Flux/MenuBar/MacOS27Hider.swift",
        "Sources/Flux/MenuBar/ControlItem.swift", "Sources/Flux/MenuBar/MenuBarSection.swift",
        "Sources/Flux/MenuBar/MenuBarIconStyle.swift", "Sources/Flux/MenuBar/MenuBarGeometry.swift",
        "Sources/Flux/Support/Theme.swift", "Sources/Flux/Support/Log.swift",
        "Sources/Flux/Support/AccessibilityAccess.swift"])
    process = subprocess.Popen([str(fixture)], start_new_session=True)
    try:
        command([str(binary), str(fixture)] + sys.argv[1:], 30)
    finally:
        _stop(process)
