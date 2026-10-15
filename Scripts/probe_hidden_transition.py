#!/usr/bin/env python3
"""Observe two disposable status apps through public hide/reveal calls.

The normal Hidden fixture needs a unique /Applications registration so macOS
can reveal it under an allow list. The fixture is removed after the probe.
"""

import argparse
from contextlib import ExitStack
import os
from pathlib import Path
import plistlib
import signal
import shutil
import subprocess
import sys
import tempfile
import uuid


def run(command, seconds, *, capture=False):
    process = subprocess.Popen(command, start_new_session=True,
                               stdout=subprocess.PIPE if capture else None,
                               stderr=subprocess.STDOUT if capture else None,
                               text=capture)
    try:
        output, _ = process.communicate(timeout=seconds)
    except BaseException:
        try:
            os.killpg(process.pid, signal.SIGTERM)
            process.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate(timeout=3)
        except ProcessLookupError:
            pass
        raise
    if process.returncode:
        raise RuntimeError(f"{Path(command[0]).name} exited {process.returncode}: {output or ''}")
    return output


FIXTURE = r'''
import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let suite = Bundle.main.bundleIdentifier!
    let cache = UserDefaults.standard
    cache.set(["hidden": [suite, CommandLine.arguments[2]], "alwaysHidden": [suite]],
              forKey: "flux.macOS27IconLayout")
    cache.set(100, forKey: "NSStatusItem Preferred Position transition-probe")
    let item = NSStatusBar.system.statusItem(withLength: 24)
    item.autosaveName = "transition-probe"
    let marker = NSImage(size: NSSize(width: 18, height: 18))
    marker.lockFocus()
    NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 18, height: 18).fill()
    marker.unlockFocus()
    item.button?.image = marker
    let hider = MacOS27Hider(defaults: cache, trustProvider: { false })
    hider.onStatus = { print("HIDE_STATUS \($0 ?? "accepted")") }
    let savedCursor = CGEvent(source: nil)!.location
    var region = CGRect.zero
    var captures = 0
    var maximum = 0
    var normalPixels = 0
    var normalControlPixels = 0

    @MainActor func finish(_ passed: Bool, _ message: String) -> Never {
        hider.apply(revealHidden: true, revealAlwaysHidden: true,
                    chevronX: { nil }, alwaysX: { nil })
        cache.removePersistentDomain(forName: suite)
        NSStatusBar.system.removeStatusItem(item)
        CGWarpMouseCursorPosition(savedCursor)
        print(message)
        fflush(stdout)
        exit(passed ? 0 : 1)
    }

    @MainActor func visiblePixels() -> Int {
        let path = URL(fileURLWithPath: CommandLine.arguments[1])
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-R\(Int(region.minX)),\(Int(region.minY)),\(Int(region.width)),\(Int(region.height))", path.path]
        do { try capture.run() }
        catch { finish(false, "FAIL: capture could not start") }
        capture.waitUntilExit()
        guard capture.terminationStatus == 0,
              let data = try? Data(contentsOf: path),
              let bitmap = NSBitmapImageRep(data: data) else {
            finish(false, "FAIL: menu-bar capture failed")
        }
        guard bitmap.bitsPerSample == 8, !bitmap.isPlanar,
              [3, 4].contains(bitmap.samplesPerPixel), let bytes = bitmap.bitmapData else {
            finish(false, "FAIL: capture did not use an 8-bit RGB bitmap")
        }
        let stride = bitmap.samplesPerPixel
        let alphaFirst = bitmap.bitmapFormat.contains(.alphaFirst)
        let rgbOffset = alphaFirst && stride == 4 ? 1 : 0
        var count = 0
        normalPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let pixel = y * bitmap.bytesPerRow + x * stride
                let alpha = stride == 4 ? bytes[pixel + (alphaFirst ? 0 : 3)] : 255
                guard alpha > 229 else { continue }
                let red = bytes[pixel + rgbOffset]
                let green = bytes[pixel + rgbOffset + 1]
                let blue = bytes[pixel + rgbOffset + 2]
                if blue > 178, red > 178, green < 102 { count += 1 }
                if blue > 178, green > 178, red < 153 { normalPixels += 1 }
            }
        }
        captures += 1
        return count
    }

    @MainActor func transition(_ step: Int) {
        guard step < 3 else {
            finish(true, "PASS: Always Hidden stayed hidden across reveal, collapse, and retry; captures=\(captures), max pixels=\(maximum)")
        }
        if step == 2 { hider.retry() }
        else {
            hider.apply(revealHidden: step == 0, revealAlwaysHidden: false,
                        chevronX: { region.maxX }, alwaysX: { region.maxX })
        }
        var samples = 0
        let timer = Timer(timeInterval: 0.04, repeats: true) { timer in
            MainActor.assumeIsolated {
                let pixels = visiblePixels()
                maximum = max(maximum, pixels)
                print("TRANSITION \(step) SAMPLE \(samples) PIXELS \(pixels) NORMAL \(normalPixels)")
                if pixels > 0 {
                    timer.invalidate()
                    finish(false, "FAIL: an Always Hidden icon appeared during transition \(step)")
                }
                samples += 1
                if samples == 12 {
                    timer.invalidate()
                    let normalMatches = step == 0
                        ? normalPixels >= max(1, normalControlPixels / 2) : normalPixels == 0
                    guard normalMatches else {
                        finish(false, "FAIL: normal Hidden icon did not follow transition \(step)")
                    }
                    transition(step + 1)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        guard let frame = item.button?.window?.frame,
              let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }),
              frame.minX >= 0, frame.maxX <= screen.frame.maxX else {
            finish(false, "FAIL: the temporary marker is outside the visible menu bar")
        }
        region = CGRect(x: screen.frame.minX, y: 0,
                        width: screen.frame.width, height: ceil(frame.height + 10))
        let hover = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                            mouseCursorPosition: CGPoint(x: screen.frame.width * 0.3, y: 1),
                            mouseButton: .left)!
        hover.flags = []
        hover.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let control = visiblePixels()
            normalControlPixels = normalPixels
            print("VISIBLE_CONTROLS ALWAYS \(control) NORMAL \(normalPixels)")
            guard control > 0, normalPixels > 0 else {
                finish(false, "FAIL: both visible-marker controls were not captured")
            }
            hider.apply(revealHidden: false, revealAlwaysHidden: false,
                        chevronX: { region.maxX }, alwaysX: { region.maxX })
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let always = visiblePixels()
                guard always == 0, normalPixels == 0 else {
                    finish(false, "FAIL: both Hidden fixtures did not collapse")
                }
                transition(0)
            }
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
        finish(false, "FAIL: transition probe reached its deadline")
    }
    app.run()
}
'''

NORMAL_FIXTURE = r'''
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let item = NSStatusBar.system.statusItem(withLength: 24)
let marker = NSImage(size: NSSize(width: 18, height: 18))
marker.lockFocus()
NSColor(srgbRed: 0, green: 1, blue: 1, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: 18, height: 18).fill()
marker.unlockFocus()
item.button?.image = marker
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    print("NORMAL_FIXTURE_FRAME \(String(describing: item.button?.window?.frame))")
    fflush(stdout)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { exit(1) }
app.run()
'''


def main():
    if sys.platform != "darwin":
        raise RuntimeError("the transition probe needs a macOS desktop")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-ref")
    parser.add_argument("--artifacts-dir", type=Path)
    parser.add_argument("--install-normal-fixture", action="store_true", required=True,
                        help="Create and remove a unique disposable fixture in /Applications")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    artifacts = args.artifacts_dir or root / "build/transition-probe"
    artifacts.mkdir(parents=True, exist_ok=True)
    source = root / "Sources/Flux/MenuBar/MacOS27Hider.swift"
    hider = (run(["git", "show", f"{args.baseline_ref}:Sources/Flux/MenuBar/MacOS27Hider.swift"],
                 15, capture=True) if args.baseline_ref else source.read_text())
    with tempfile.TemporaryDirectory(prefix="flux-transition-probe-") as directory, ExitStack() as cleanup:
        temporary = Path(directory)
        bundle = temporary / "FluxTransitionProbe.app"
        binary = bundle / "Contents/MacOS/FluxTransitionProbe"
        binary.parent.mkdir(parents=True)
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.flux.transition-probe." + uuid.uuid4().hex,
            "CFBundleExecutable": binary.name, "CFBundlePackageType": "APPL",
            "LSUIElement": True,
        }))
        main_file = temporary / "main.swift"
        main_file.write_text(hider + FIXTURE)
        dependencies = [root / "Sources/Flux/Support/Log.swift",
                        root / "Sources/Flux/Support/AccessibilityAccess.swift",
                        root / "Sources/Flux/MenuBar/MenuBarGeometry.swift",
                        root / "Sources/Flux/MenuBar/MenuBarSection.swift"]
        run(["xcrun", "swiftc", "-swift-version", "5", str(main_file),
             *map(str, dependencies), "-o", str(binary)], 120)
        run(["codesign", "--force", "--sign", "-", str(bundle)], 20)
        normal_bundle = temporary / "FluxNormalHiddenFixture.app"
        normal_binary = normal_bundle / "Contents/MacOS/FluxNormalHiddenFixture"
        normal_binary.parent.mkdir(parents=True)
        normal_id = "com.flux.transition-normal." + uuid.uuid4().hex
        (normal_bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": normal_id,
            "CFBundleExecutable": normal_binary.name, "CFBundlePackageType": "APPL",
            "LSUIElement": True,
        }))
        normal_source = temporary / "normal.swift"
        normal_source.write_text(NORMAL_FIXTURE)
        run(["xcrun", "swiftc", "-swift-version", "5", str(normal_source),
             "-o", str(normal_binary)], 120)
        run(["codesign", "--force", "--sign", "-", str(normal_bundle)], 20)
        if args.install_normal_fixture:
            destination = Path("/Applications") / f"FluxTransitionFixture-{uuid.uuid4().hex}.app"
            destination.mkdir()
            cleanup.callback(shutil.rmtree, destination)
            shutil.copytree(normal_bundle, destination, dirs_exist_ok=True)
            normal_bundle = destination
            normal_binary = normal_bundle / "Contents/MacOS/FluxNormalHiddenFixture"
            run(["codesign", "--verify", "--strict", str(normal_bundle)], 20)
        register = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        run([register, "-f", str(bundle)], 20)
        cleanup.callback(run, [register, "-u", str(bundle)], 20)
        run([register, "-f", str(normal_bundle)], 20)
        cleanup.callback(run, [register, "-u", str(normal_bundle)], 20)
        normal_process = subprocess.Popen([str(normal_binary)], start_new_session=True)
        try:
            run([str(binary), str(artifacts / "sample.png"), normal_id], 22)
        finally:
            try:
                os.killpg(normal_process.pid, signal.SIGTERM)
                normal_process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(normal_process.pid, signal.SIGKILL)
                normal_process.wait(timeout=3)
            except ProcessLookupError:
                pass


def interrupted(signum, _frame):
    raise SystemExit(128 + signum)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    try:
        main()
    except Exception as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
