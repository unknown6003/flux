#!/usr/bin/env python3
"""Prove the native app hides and reveals real status items on a CI Mac.

Two disposable fixtures draw solid magenta (Always Hidden) and cyan (Hidden)
icons. The signed native Flux app runs from /Applications with only those two
apps in its saved groups. A probe clicks Flux's own chevron with real mouse
events and counts fixture pixels in full-screen captures. CI only: it writes
com.flux.menubar defaults and a temporary Accessibility grant.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from probe_tcc import accessibility_grant  # noqa: E402

ROWS = 80
HELPER = r'''
import AppKit
import ApplicationServices

func fail(_ message: String) -> Never { print("FAIL: \(message)"); fflush(stdout); exit(1) }
let arguments = CommandLine.arguments
switch arguments[1] {
case "count":
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: arguments[2])),
          let bitmap = NSBitmapImageRep(data: data) else { fail("unreadable capture") }
    let rows = min(bitmap.pixelsHigh, Int(arguments[3])!)
    var magenta = 0, cyan = 0
    for y in 0..<rows {
        for x in 0..<bitmap.pixelsWide {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                  color.alphaComponent > 0.9 else { continue }
            let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
            if r > 0.7, b > 0.7, g < 0.4 { magenta += 1 }
            if g > 0.7, b > 0.7, r < 0.6 { cyan += 1 }
        }
    }
    print("{\"magenta\": \(magenta), \"cyan\": \(cyan), \"width\": \(bitmap.pixelsWide)}")
case "click":
    guard AXIsProcessTrusted() else { fail("the probe lacks Accessibility") }
    let app = AXUIElementCreateApplication(pid_t(arguments[2])!)
    AXUIElementSetMessagingTimeout(app, 1)
    var bar: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXExtrasMenuBarAttribute as CFString, &bar) == .success,
          let bar else { fail("Flux has no status items") }
    var children: CFTypeRef?
    AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children)
    var target: CGRect?
    for child in (children as? [AXUIElement]) ?? [] {
        var description: CFTypeRef?, position: CFTypeRef?, size: CFTypeRef?
        AXUIElementCopyAttributeValue(child, kAXDescriptionAttribute as CFString, &description)
        AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &position)
        AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &size)
        var point = CGPoint.zero, extent = CGSize.zero
        if let position { AXValueGetValue(position as! AXValue, .cgPoint, &point) }
        if let size { AXValueGetValue(size as! AXValue, .cgSize, &extent) }
        let label = description as? String ?? ""
        print("ITEM \(label) \(point) \(extent)")
        if label.contains("menu bar icons"), extent.width > 0 { target = CGRect(origin: point, size: extent) }
    }
    guard let target else { fail("Flux's chevron was not found") }
    let center = CGPoint(x: target.midX, y: target.midY)
    let flags: CGEventFlags = arguments.count > 3 && arguments[3] == "option" ? .maskAlternate : []
    func option(_ down: Bool) {
        let key = CGEvent(keyboardEventSource: nil, virtualKey: 58, keyDown: down)!
        key.flags = down ? .maskAlternate : []
        key.post(tap: .cghidEventTap)
        usleep(80_000)
    }
    if !flags.isEmpty { option(true) }
    defer { if !flags.isEmpty { option(false) } }
    for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: center, mouseButton: .left)!
        event.flags = flags
        event.post(tap: .cghidEventTap)
        usleep(60_000)
    }
    let away = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                       mouseCursorPosition: CGPoint(x: center.x - 400, y: 300), mouseButton: .left)!
    away.post(tap: .cghidEventTap)
    print("CLICKED \(center) option=\(flags.contains(.maskAlternate))")
default:
    fail("unknown command")
}
'''

FIXTURE = r'''
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let item = NSStatusBar.system.statusItem(withLength: 24)
let marker = NSImage(size: NSSize(width: 18, height: 18))
marker.lockFocus()
NSColor(srgbRed: CGFloat(Double(CommandLine.arguments[1])!), green: CGFloat(Double(CommandLine.arguments[2])!), blue: 1, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: 18, height: 18).fill()
marker.unlockFocus()
item.button?.image = marker
DispatchQueue.main.asyncAfter(deadline: .now() + 240) { exit(1) }
app.run()
'''
REGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


def run(command, seconds=60, check=True):
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                               start_new_session=True)
    try:
        output, _ = process.communicate(timeout=seconds)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        raise RuntimeError(f"{command[0]} exceeded {seconds}s")
    if check and process.returncode:
        raise RuntimeError(f"{command[0]} exited {process.returncode}: {output[-3000:]}")
    return output


def bundle(directory, name, identifier, source, temporary):
    app = directory / (name + ".app")
    binary = app / "Contents/MacOS" / name
    binary.parent.mkdir(parents=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": identifier, "CFBundleExecutable": name,
        "CFBundlePackageType": "APPL", "LSUIElement": True}))
    file = temporary / (name + ".swift")
    file.write_text(source)
    run(["xcrun", "swiftc", "-O", str(file), "-o", str(binary)], 180)
    run(["codesign", "--force", "--sign", "-", str(app)], 20)
    return app, binary


def flux_pids(executable):
    listing = run(["/bin/ps", "-axo", "pid=,stat=,command="], 5)
    return [int(p[0]) for p in (line.strip().split(None, 2) for line in listing.splitlines())
            if len(p) == 3 and not p[1].startswith(("Z", "X")) and p[2].startswith(str(executable))]


def main():
    if sys.platform != "darwin":
        raise RuntimeError("needs a macOS desktop")
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--output", type=Path, default=Path("build/native-hiding"))
    parser.add_argument("--cycles", type=int, default=3)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    installed = Path("/Applications/Flux.app")
    if installed.exists():
        raise RuntimeError("/Applications/Flux.app already exists on this runner")
    results, processes, cleanup = [], [], []
    executable = installed / "Contents/MacOS/Flux"
    video = None
    with tempfile.TemporaryDirectory(prefix="flux-native-hiding-") as directory:
        temporary = Path(directory)
        try:
            helper_app, helper = bundle(temporary, "FluxHidingProbe", "com.flux.native-hiding-probe", HELPER, temporary)
            ids = {}
            for name, red, green in [("magenta", 1, 0), ("cyan", 0, 1)]:
                identifier = f"com.flux.hiding-{name}.{uuid.uuid4().hex[:12]}"
                app, _ = bundle(temporary, "FluxFixture" + name.title(), identifier, FIXTURE, temporary)
                target = Path("/Applications") / f"FluxHidingFixture-{name}-{uuid.uuid4().hex[:8]}.app"
                shutil.copytree(app, target, symlinks=True)
                cleanup.append(lambda t=target: shutil.rmtree(t, ignore_errors=True))
                run([REGISTER, "-f", str(target)], 20)
                cleanup.append(lambda t=target: run([REGISTER, "-u", str(t)], 20, check=False))
                processes.append(subprocess.Popen([str(target / "Contents/MacOS" / app.stem), str(red), str(green)],
                                                  start_new_session=True))
                ids[name] = identifier
            run(["/usr/bin/ditto", str(args.app), str(installed)], 60)
            cleanup.append(lambda: shutil.rmtree(installed, ignore_errors=True))
            run(["codesign", "--verify", "--deep", "--strict", str(installed)], 30)
            layout = plistlib.dumps({"hidden": [ids["cyan"], ids["magenta"]], "alwaysHidden": [ids["magenta"]]},
                                    fmt=plistlib.FMT_XML).decode()
            layout = layout[layout.index("<dict>"):layout.rindex("</dict>") + len("</dict>")]
            run(["defaults", "write", "com.flux.menubar", "flux.macOS27IconLayout", layout])
            print(run(["defaults", "read", "com.flux.menubar", "flux.macOS27IconLayout"], 10), flush=True)
            run(["defaults", "write", "com.flux.menubar", "flux.autoRehide", "-bool", "false"])
            cleanup.append(lambda: run(["defaults", "delete", "com.flux.menubar"], 10, check=False))
            time.sleep(2)

            def capture(label, expect):
                path = output / f"{len(results):02d}-{label}.png"
                time.sleep(1.5)
                run(["/usr/sbin/screencapture", "-x", str(path)], 20)
                counts = json.loads(run([str(helper), "count", str(path), str(ROWS)], 30).strip().splitlines()[-1])
                visible = {name: counts[name] > 20 for name in ("magenta", "cyan")}
                passed = visible == expect
                results.append(dict(step=label, expect=expect, counts=counts, passed=passed, image=path.name))
                print(f"{label}: counts={counts} expect={expect} {'PASS' if passed else 'FAIL'}", flush=True)
                (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
                return passed

            capture("before-flux", {"magenta": True, "cyan": True})
            try:
                video = subprocess.Popen(["/usr/sbin/screencapture", "-x", "-v", "-V", str(20 + 12 * args.cycles),
                                          str(output / "hiding.mov")], start_new_session=True,
                                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except OSError:
                video = None
            run(["/usr/bin/open", "-n", str(installed)], 20)
            deadline = time.monotonic() + 15
            while not flux_pids(executable) and time.monotonic() < deadline:
                time.sleep(0.2)
            pids = flux_pids(executable)
            if len(pids) != 1:
                raise RuntimeError(f"expected one native Flux process, found {pids}")
            time.sleep(2)
            capture("collapsed", {"magenta": False, "cyan": False})
            with accessibility_grant("com.flux.native-hiding-probe"):
                for cycle in range(args.cycles):
                    print(run([str(helper), "click", str(pids[0])], 20), flush=True)
                    capture(f"cycle{cycle + 1}-hidden-revealed", {"magenta": False, "cyan": True})
                    print(run([str(helper), "click", str(pids[0]), "option"], 20), flush=True)
                    capture(f"cycle{cycle + 1}-all-revealed", {"magenta": True, "cyan": True})
                    print(run([str(helper), "click", str(pids[0])], 20), flush=True)
                    capture(f"cycle{cycle + 1}-collapsed", {"magenta": False, "cyan": False})
            os.kill(pids[0], signal.SIGTERM)
            deadline = time.monotonic() + 15
            while flux_pids(executable) and time.monotonic() < deadline:
                time.sleep(0.2)
            if flux_pids(executable):
                raise RuntimeError("native Flux did not quit after SIGTERM")
            capture("after-quit", {"magenta": True, "cyan": True})
        finally:
            for pid in flux_pids(executable):
                os.kill(pid, signal.SIGKILL)
            for process in processes:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            if video:
                try:
                    video.wait(timeout=40)
                except subprocess.TimeoutExpired:
                    os.killpg(video.pid, signal.SIGINT)
            for action in reversed(cleanup):
                action()
    failed = [r["step"] for r in results if not r["passed"]]
    summary = dict(result="pass" if results and not failed else "fail", failed=failed, steps=len(results))
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary), flush=True)
    if failed:
        raise SystemExit(1)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda signum, _frame: (_ for _ in ()).throw(SystemExit(128 + signum)))
    try:
        main()
    except RuntimeError as error:
        print(f"FAIL: {error}", file=sys.stderr, flush=True)
        raise SystemExit(1)
