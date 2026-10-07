#!/usr/bin/env python3
"""Run Flux's macOS 27 visibility bridge against a temporary status item."""

import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile


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
probe = r'''

@MainActor
func probe() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
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
        return (children as? [AXUIElement])?.count
    }
    func snapshot(_ state: String) -> Int {
        let n = count()
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
                if color.redComponent > 0.8 && color.greenComponent < 0.2
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
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        let before = snapshot("Before")
        let allowed = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            .subtracting(["com.flux.visibility-probe"]).sorted()
        assessment.restrict(to: allowed)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let hidden = snapshot("Restricted")
            let activated = assessment.allowed != nil
            assessment.release()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let restored = snapshot("Restored")
                NSStatusBar.system.removeStatusItem(item)
                guard activated else {
                    print("FAIL: the hide request did not complete")
                    exit(1)
                }
                guard before > 0, hidden == 0, restored > 0 else {
                    print("FAIL: the probe icon did not disappear and return on screen")
                    exit(1)
                }
                print("PASS: the real probe icon disappeared and returned")
                exit(0)
            }
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
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
        raise SystemExit(run([str(binary), str(output)], 20))
    finally:
        run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/"
             "LaunchServices.framework/Support/lsregister", "-u", str(bundle)], 20)
