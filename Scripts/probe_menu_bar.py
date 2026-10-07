#!/usr/bin/env python3
"""Run Flux's macOS 27 visibility bridge against a temporary status item."""

import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import time


def run(command, seconds):
    process = subprocess.Popen(command, start_new_session=True)
    try:
        return process.wait(timeout=seconds)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)
        raise SystemExit(f"FAIL: deadline reached for {command[0]}")


if sys.platform != "darwin":
    raise SystemExit("FAIL: this probe needs a macOS 27 desktop")

root = Path(__file__).resolve().parents[1]
if "--app-click" in sys.argv and os.environ.get("GITHUB_ACTIONS") != "true":
    raise SystemExit("FAIL: the install-and-click probe is only for a disposable CI desktop")
probe = r'''

@_silgen_name("FluxProbeCreateDisplay")
func createProbeDisplay() -> UInt32

private extension MacOS27Hider {
    var probeClockFrame: CGRect? { clockFrame() }
}

@MainActor
func probe() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    if CommandLine.arguments.contains("--app-click") {
        let deadline = Date().addingTimeInterval(8)
        var ready = false
        while Date() < deadline {
            if let flux = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.flux.menubar").first {
                try? String(flux.processIdentifier).write(
                    toFile: CommandLine.arguments[1] + "/Flux.pid", atomically: true, encoding: .utf8)
                let owner = AXUIElementCreateApplication(flux.processIdentifier)
                AXUIElementSetMessagingTimeout(owner, 0.2)
                var bar: CFTypeRef?
                var children: CFTypeRef?
                if AXUIElementCopyAttributeValue(owner, kAXExtrasMenuBarAttribute as CFString,
                                               &bar) == .success, let bar,
                    AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString,
                                                   &children) == .success,
                    let items = children as? [AXUIElement], items.count >= 2 {
                    ready = true
                    break
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard ready else {
            print("FAIL: Flux did not become ready within 8 seconds")
            exit(1)
        }
    }
    if CommandLine.arguments.contains("--dual-display") {
        let id = createProbeDisplay()
        guard id != 0 else {
            print("FAIL: the hosted desktop could not create a second display")
            exit(1)
        }
        print("Virtual display: \(id) bounds=\(CGDisplayBounds(id))")
    }
    let item = NSStatusBar.system.statusItem(withLength: 28)
    item.autosaveName = "flux.visibility-probe"
    let image = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { bounds in
        NSColor(calibratedRed: 1, green: 0, blue: 0.7, alpha: 1).setFill()
        bounds.fill()
        return true
    }
    item.button?.image = image
    let assessment = MenuBarAssessment()
    print("OS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("Screens: \(NSScreen.screens.count)")
    print("Screen bounds: \(NSScreen.screens.map(\.frame))")
    print("Accessibility trusted: \(AXIsProcessTrusted())")
    print("Assessment interface: \(assessment.isAvailable)")
    guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27,
          !NSScreen.screens.isEmpty, assessment.isAvailable else {
        print("FAIL: macOS 27, a display and the assessment interface are required")
        exit(1)
    }
    func count() -> Int? {
        let owner = AXUIElementCreateApplication(getpid())
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(owner, kAXExtrasMenuBarAttribute as CFString,
                                           &bar) == .success, let bar else { return nil }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement,
                                            kAXChildrenAttribute as CFString,
                                            &children) == .success else { return nil }
        guard let items = children as? [AXUIElement] else { return nil }
        for child in items {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString,
                                             &value) == .success, let value,
                CFGetTypeID(value) == AXValueGetTypeID() {
                var point = CGPoint.zero
                if AXValueGetValue(value as! AXValue, .cgPoint, &point) {
                    print("Probe AX position: \(point)")
                }
            }
        }
        return items.count
    }
    func snapshot(_ state: String) -> Int {
        let n = count()
        if let flux = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.flux.menubar").first {
            print("Flux process: \(flux.processIdentifier) path=\(String(describing: flux.bundleURL)) registered=\(String(describing: NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.flux.menubar")))")
        }
        print("\(state): own AX items=\(n.map(String.init) ?? "unavailable") window=\(String(describing: item.button?.window?.frame))")
        let output = CommandLine.arguments[1]
        let screenshot = output + "/" + state + ".png"
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", screenshot]
        do {
            try capture.run()
            capture.waitUntilExit()
        } catch {
            print("FAIL: screen capture could not start: \(error)")
            exit(1)
        }
        guard capture.terminationStatus == 0,
              let data = try? Data(contentsOf: URL(fileURLWithPath: screenshot)),
              let bitmap = NSBitmapImageRep(data: data) else {
            print("FAIL: this desktop does not allow screen capture")
            exit(1)
        }
        var pixels = 0
        for y in 0..<min(100, bitmap.pixelsHigh) {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.8 && color.greenComponent < 0.35
                    && color.blueComponent > 0.45 && color.blueComponent < 0.9 {
                    pixels += 1
                }
            }
        }
        print("\(state): marker pixels=\(pixels)")
        let positions = CFPreferencesCopyValue("TrailingItemPreferredPositions" as CFString,
                                              "com.apple.MenuBarAgent" as CFString,
                                              kCFPreferencesCurrentUser,
                                              kCFPreferencesAnyHost) as? [String: Any] ?? [:]
        for (key, value) in positions.sorted(by: { $0.key < $1.key })
            where key.contains("com.flux.visibility-probe") {
            print("Probe order: \(key)=\(value)")
        }
        return pixels
    }
    assessment.onStatus = { error in
        if let error {
            assessment.release()
            print("FAIL: \(error)")
            exit(1)
        }
    }
    @MainActor
    func begin(attempt: Int) {
        let before = snapshot("Before")
        guard before > 0 || CommandLine.arguments.contains("--app-click") else {
            guard attempt < 10 else {
                print("FAIL: the probe icon never became visible")
                exit(1)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                begin(attempt: attempt + 1)
            }
            return
        }
        if CommandLine.arguments.contains("--app-click") {
            guard let flux = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.flux.menubar").first else {
                print("FAIL: the built Flux app is not running")
                exit(1)
            }
            let owner = AXUIElementCreateApplication(flux.processIdentifier)
            var bar: CFTypeRef?
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(owner, kAXExtrasMenuBarAttribute as CFString,
                                               &bar) == .success, let bar,
                AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString,
                                               &children) == .success,
                let items = children as? [AXUIElement] else {
                print("FAIL: the built app's controls are unavailable")
                exit(1)
            }
            var chevron: CGRect?
            for child in items {
                var position: CFTypeRef?
                var size: CFTypeRef?
                guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString,
                                                   &position) == .success, let position,
                    AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString,
                                                   &size) == .success, let size else { continue }
                var origin = CGPoint.zero
                var dimensions = CGSize.zero
                guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
                    AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { continue }
                let frame = CGRect(origin: origin, size: dimensions)
                print("Flux control: \(frame)")
                if dimensions.width >= 20 { chevron = frame }
            }
            guard let chevron, let fixture = item.button?.window?.frame,
                fixture.maxX <= chevron.minX else {
                print("FAIL: the fixture is not to the left of Flux's arrow")
                exit(1)
            }
            func click() {
                let point = CGPoint(x: chevron.midX, y: chevron.midY)
                for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                    CGEvent(mouseEventSource: nil, mouseType: type,
                            mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                }
            }
            click()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let firstExpanded = snapshot("AppExpanded")
                click()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    let collapsed = snapshot("AppCollapsed")
                    click()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        let expanded = snapshot("AppExpandedAgain")
                        guard firstExpanded > 0, collapsed == 0, expanded > 0 else {
                            print("FAIL: clicks on the real Flux arrow did not hide and show the icon")
                            exit(1)
                        }
                        print("PASS: clicks on the real Flux arrow hid and showed the icon")
                        exit(0)
                    }
                }
            }
            return
        }
        let allowed = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            .subtracting(["com.flux.visibility-probe"]).sorted()
        assessment.restrict(to: allowed)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let hidden = snapshot("Restricted")
            let activated = assessment.allowed != nil
            assessment.release()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let restored = snapshot("Restored")
                guard activated else {
                    print("FAIL: the hide request did not complete")
                    exit(1)
                }
                guard before > 0, hidden == 0, restored > 0 else {
                    print("FAIL: the probe icon did not disappear and return on screen")
                    exit(1)
                }
                print("PASS: the real probe icon disappeared and returned")
                let hider = MacOS27Hider()
                print("Clock bounds: \(String(describing: hider.probeClockFrame))")
                print("Pointer: \(NSEvent.mouseLocation)")
                @MainActor
                func apply(_ revealed: Bool) {
                    hider.apply(revealHidden: revealed, revealAlwaysHidden: revealed,
                                chevronX: { item.button?.window?.frame.maxX },
                                alwaysX: { nil })
                }
                apply(false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    let collapsed = snapshot("HiderCollapsed")
                    apply(true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        let expanded = snapshot("HiderExpanded")
                        NSStatusBar.system.removeStatusItem(item)
                        guard collapsed == 0, expanded > 0 else {
                            print("FAIL: Flux's full position scan and toggle did not hide and show the icon")
                            print("Hider error: \(hider.latestError ?? "none")")
                            exit(1)
                        }
                        print("PASS: Flux's full position scan and toggle hid and showed the icon")
                        exit(0)
                    }
                }
            }
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { begin(attempt: 0) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
        assessment.release()
        print("FAIL: the hide/show probe reached its deadline")
        exit(1)
    }
    app.run()
}
MainActor.assumeIsolated { probe() }
'''

with tempfile.TemporaryDirectory(prefix="flux-menu-bar-probe-") as directory:
    temporary = Path(directory)
    source = temporary / "main.swift"
    source.write_text((root / "Sources/Flux/MenuBar/MacOS27Hider.swift").read_text() + probe)
    display_object = temporary / "display.o"
    status = run(["clang", "-fobjc-arc", "-c", str(root / "Scripts/probe_display.m"),
                  "-o", str(display_object)], 60)
    if status:
        raise SystemExit(status)
    bundle = temporary / "FluxMenuBarProbe.app"
    contents = bundle / "Contents"
    binary = contents / "MacOS/FluxMenuBarProbe"
    binary.parent.mkdir(parents=True)
    with (contents / "Info.plist").open("wb") as output:
        plistlib.dump({
            "CFBundleIdentifier": "com.flux.visibility-probe",
            "CFBundleExecutable": binary.name,
            "CFBundleName": "FluxMenuBarProbe",
            "CFBundlePackageType": "APPL",
            "LSUIElement": True,
        }, output)
    status = run(["swiftc", "-swift-version", "5", str(source),
                  str(root / "Sources/Flux/Support/Log.swift"),
                  str(root / "Sources/Flux/MenuBar/MenuBarGeometry.swift"),
                  str(display_object),
                  "-o", str(binary)], 120)
    if status:
        raise SystemExit(status)
    status = run(["codesign", "--force", "--sign", "-", str(bundle)], 20)
    if status:
        raise SystemExit(status)
    status = run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/"
                  "LaunchServices.framework/Support/lsregister", "-f", str(bundle)], 20)
    if status:
        raise SystemExit(status)
    try:
        output = root / "build/menu-bar-probe"
        output.mkdir(parents=True, exist_ok=True)
        arguments = [arg for arg in sys.argv[1:] if arg in ("--dual-display", "--app-click")]
        installed_flux = None
        try:
            if "--app-click" in arguments:
                installed_flux = Path("/Applications/Flux.app")
                if installed_flux.exists():
                    raise SystemExit("FAIL: the probe will not replace an existing Flux install")
                status = run(["sudo", "-n", "ditto", str(root / "build/Flux.app"),
                              str(installed_flux)], 30)
                if status:
                    raise SystemExit(status)
                status = run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/"
                              "LaunchServices.framework/Support/lsregister", "-f",
                              str(installed_flux)], 20)
                if status:
                    raise SystemExit(status)
                (output / "Flux.pid").unlink(missing_ok=True)
                status = run(["/usr/bin/open", "-n", "-g", str(installed_flux)], 20)
                if status:
                    raise SystemExit(status)
            raise SystemExit(run([str(binary), str(output)] + arguments, 35))
        finally:
            pid_file = output / "Flux.pid"
            if installed_flux is not None and pid_file.exists():
                pid = int(pid_file.read_text())
                try:
                    os.kill(pid, signal.SIGTERM)
                    for _ in range(10):
                        time.sleep(0.5)
                        os.kill(pid, 0)
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                run(["/usr/bin/log", "show", "--last", "2m", "--info", "--style", "compact",
                     "--predicate", 'process == "Flux" AND subsystem == "com.flux.menubar"'], 30)
    finally:
        run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/"
             "LaunchServices.framework/Support/lsregister", "-u", str(bundle)], 20)
