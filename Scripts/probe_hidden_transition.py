#!/usr/bin/env python3
"""Observe an Always Hidden status item throughout public hide/reveal calls."""

import argparse
import os
from pathlib import Path
import plistlib
import signal
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
    cache.set(["hidden": [suite], "alwaysHidden": [suite]],
              forKey: "flux.macOS27IconLayout")
    cache.set(100, forKey: "NSStatusItem Preferred Position transition-probe")
    let item = NSStatusBar.system.statusItem(withLength: 24)
    item.autosaveName = "transition-probe"
    let marker = NSImage(size: NSSize(width: 18, height: 18))
    marker.lockFocus()
    NSColor.magenta.setFill()
    NSRect(x: 0, y: 0, width: 18, height: 18).fill()
    marker.unlockFocus()
    item.button?.image = marker
    let hider = MacOS27Hider(defaults: cache, trustProvider: { false })
    let savedCursor = CGEvent(source: nil)!.location
    var region = CGRect.zero
    var captures = 0
    var maximum = 0

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
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                   color.redComponent > 0.7, color.blueComponent > 0.7,
                   color.greenComponent < 0.4, color.alphaComponent > 0.9 {
                    count += 1
                }
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
                print("TRANSITION \(step) SAMPLE \(samples) PIXELS \(pixels)")
                if pixels > 0 {
                    timer.invalidate()
                    finish(false, "FAIL: an Always Hidden icon appeared during transition \(step)")
                }
                samples += 1
                if samples == 12 {
                    timer.invalidate()
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
        region = CGRect(x: floor(frame.minX), y: floor(screen.frame.maxY - frame.maxY),
                        width: ceil(frame.width), height: ceil(frame.height))
        let hover = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                            mouseCursorPosition: CGPoint(x: screen.frame.width * 0.3, y: 1),
                            mouseButton: .left)!
        hover.flags = []
        hover.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard visiblePixels() > 0 else {
                finish(false, "FAIL: the visible-marker control was not captured")
            }
            hider.apply(revealHidden: false, revealAlwaysHidden: false,
                        chevronX: { region.maxX }, alwaysX: { region.maxX })
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard visiblePixels() == 0 else {
                    finish(false, "FAIL: the Always Hidden fixture did not collapse")
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


def main():
    if sys.platform != "darwin":
        raise RuntimeError("the transition probe needs a macOS desktop")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-ref")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    source = root / "Sources/Flux/MenuBar/MacOS27Hider.swift"
    hider = (run(["git", "show", f"{args.baseline_ref}:Sources/Flux/MenuBar/MacOS27Hider.swift"],
                 15, capture=True) if args.baseline_ref else source.read_text())
    with tempfile.TemporaryDirectory(prefix="flux-transition-probe-") as directory:
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
                        root / "Sources/Flux/MenuBar/MenuBarGeometry.swift"]
        run(["xcrun", "swiftc", "-swift-version", "5", str(main_file),
             *map(str, dependencies), "-o", str(binary)], 120)
        run(["codesign", "--force", "--sign", "-", str(bundle)], 20)
        register = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        run([register, "-f", str(bundle)], 20)
        try:
            run([str(binary), str(temporary / "sample.png")], 22)
        finally:
            run([register, "-u", str(bundle)], 20)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
