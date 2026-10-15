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
parser.add_argument("--manager-ref", help="Compile a committed manager with the current native fixture")
options = parser.parse_args()
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
        print("Native source=\(icon.frame), targetX=\(targetX), boundaries=\(manager.boundaryProvider())")
        driver.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
        driver.arguments = ["--drag", String(Double(icon.frame.midX)), String(Double(icon.frame.midY)),
                            String(Double(targetX)), String(Double(icon.frame.midY))]
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
        guard ordered.allSatisfy({ MenuBarIconManager.section(for: $0.frame, boundaries: manager.boundaryProvider()) == .hidden }) else {
            print("FAIL: the reorder fixture could not enter Hidden")
            exit(1)
        }
        if CommandLine.arguments.contains("--native-close") {
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
    close_test = options.native_close or options.move_close
    process = subprocess.Popen([str(fixture)] + (["--single"] if close_test else []), start_new_session=True)
    started_at = time.time()
    try:
        flags = ["--native-close"] if options.native_close else (["--move-close"] if options.move_close else [])
        command([str(binary), str(fixture)] + flags, 30)
    except BaseException:
        label = (options.manager_ref or "current")[:8] + ("-native" if options.native_close else ("-close" if options.move_close else "-settings"))
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
