#!/usr/bin/env python3
"""Check that granting access during use replaces the system volume key path."""

import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import time
from probe_tcc import accessibility_grant, _stop


if sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true":
    raise SystemExit("FAIL: this sound probe requires a disposable macOS CI desktop")


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
source = r'''
import AppKit
import Combine

@MainActor
func probe() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let directory = URL(fileURLWithPath: CommandLine.arguments[1])
    let keys = MediaKeyInterceptor()
    keys.volumeControllable = { true }
    var received = 0
    let subscription = keys.events.sink { event in
        if case .key(.volumeDown, isRepeat: false, fine: false) = event { received += 1 }
    }
    guard !keys.start() else {
        print("FAIL: the sound probe must start without Accessibility access")
        exit(1)
    }
    try! Data().write(to: directory.appendingPathComponent("ready"))
    let timer = Timer(timeInterval: 0.1, repeats: true) { timer in
        MainActor.assumeIsolated {
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("granted").path) else { return }
            timer.invalidate()
            // A downstream observer represents the system's volume HUD key path.
            var downstream = 0
            let context = UnsafeMutablePointer<Int>.allocate(capacity: 1)
            context.initialize(to: 0)
            guard let observer = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                eventsOfInterest: 1 << 14, callback: { _, type, event, info in
                    if type.rawValue == 14, let info, let ns = NSEvent(cgEvent: event),
                       ns.subtype.rawValue == 8, (ns.data1 >> 16) == 1 {
                        let count = info.assumingMemoryBound(to: Int.self)
                        count.pointee += 1
                    }
                    return Unmanaged.passUnretained(event)
                }, userInfo: context),
                let observerSource = CFMachPortCreateRunLoopSource(nil, observer, 0) else {
                print("FAIL: the runner cannot observe system sound keys")
                exit(1)
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), observerSource, .commonModes)
            CGEvent.tapEnable(tap: observer, enable: true)
            // This is the app notification posted after returning from Settings.
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: app)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                for flag in [0xA, 0xB] {
                    guard let event = NSEvent.otherEvent(
                        with: .systemDefined, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: 0, context: nil, subtype: 8,
                        data1: (1 << 16) | (flag << 8), data2: 0)?.cgEvent else {
                        print("FAIL: could not create a sound key")
                        exit(1)
                    }
                    event.post(tap: .cghidEventTap)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    downstream = context.pointee
                    keys.stop()
                    CGEvent.tapEnable(tap: observer, enable: false)
                    CFRunLoopRemoveSource(CFRunLoopGetMain(), observerSource, .commonModes)
                    withExtendedLifetime(subscription) {}
                    print("Sound events received: \(received); system key edges received: \(downstream)")
                    guard received == 1, downstream == 0 else {
                        print("FAIL: restoring access during use leaves Apple's volume key path active")
                        exit(1)
                    }
                    print("PASS: restoring access handles one sound key and suppresses both system key edges")
                    exit(0)
                }
            }
        }
    }
    RunLoop.main.add(timer, forMode: .common)
    DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
        keys.stop()
        print("FAIL: the sound probe reached its deadline")
        exit(1)
    }
    app.run()
}
MainActor.assumeIsolated { probe() }
'''

with tempfile.TemporaryDirectory(prefix="flux-sound-probe-") as directory:
    temporary = Path(directory)
    bundle = temporary / "FluxSoundProbe.app"
    executable = bundle / "Contents/MacOS/FluxSoundProbe"
    executable.parent.mkdir(parents=True)
    with (bundle / "Contents/Info.plist").open("wb") as output:
        plistlib.dump({"CFBundleIdentifier": "com.flux.sound-probe",
                      "CFBundleExecutable": executable.name,
                      "CFBundlePackageType": "APPL", "LSUIElement": True}, output)
    main = temporary / "main.swift"
    main.write_text(source)
    command(["swiftc", "-swift-version", "5", str(main),
             str(root / "Sources/Flux/Services/MediaKeyInterceptor.swift"),
             "-o", str(executable)], 120)
    command(["codesign", "--force", "--sign", "-", str(bundle)], 20)
    register = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    command([register, "-f", str(bundle)], 20)
    process = subprocess.Popen([str(executable), str(temporary)], start_new_session=True)
    try:
        deadline = time.monotonic() + 15
        while not (temporary / "ready").exists():
            if process.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError("FAIL: the sound probe did not become ready")
            time.sleep(0.1)
        with accessibility_grant("com.flux.sound-probe"):
            (temporary / "granted").touch()
            try:
                status = process.wait(timeout=10)
                if status:
                    raise SystemExit(status)
            finally:
                _stop(process)
    finally:
        _stop(process)
        command([register, "-u", str(bundle)], 20)
