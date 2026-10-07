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
    item.button?.title = "FP"
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
    func snapshot(_ state: String) -> Int? {
        let n = count()
        print("\(state): own AX items=\(n.map(String.init) ?? "unavailable") window=\(String(describing: item.button?.window?.frame))")
        let positions = CFPreferencesCopyValue("TrailingItemPreferredPositions" as CFString,
                                              "com.apple.MenuBarAgent" as CFString,
                                              kCFPreferencesCurrentUser,
                                              kCFPreferencesAnyHost) as? [String: Any] ?? [:]
        for (key, value) in positions.sorted(by: { $0.key < $1.key })
            where key.contains("com.flux.visibility-probe") {
            print("Probe order: \(key)=\(value)")
        }
        return n
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
                guard let before, before > 0, hidden == 0, restored == before else {
                    print("FAIL: AX did not prove that the probe icon disappeared and returned")
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
        raise SystemExit(run([str(binary)], 20))
    finally:
        run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/"
             "LaunchServices.framework/Support/lsregister", "-u", str(bundle)], 20)
