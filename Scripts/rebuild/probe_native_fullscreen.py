#!/usr/bin/env python3
"""Prove the menu bar still drops down in a fullscreen app while Flux hides icons.

macOS 27's MenuBarAgent assessment assertion, which Flux uses to hide apps,
also stops the menu bar from appearing in a fullscreen Space. Three phases
run against one fullscreen fixture window and one hidden status-item fixture:

  control  no Flux: the pointer at the top edge must show the menu bar.
  blocked  Flux with FLUX_PROBE_KEEP_HIDING_IN_FULLSCREEN=1 (0.22.2 behaviour).
  fixed    Flux as shipped: the menu bar must appear, and hiding must come
           back after the fullscreen app quits.

CI only: it writes com.flux.menubar defaults and a temporary Accessibility grant.
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

sys.path.insert(0, str(Path(__file__).resolve().parent))
from probe_native_hiding import FIXTURE, REGISTER, bundle, flux_pids, run  # noqa: E402
from probe_tcc import accessibility_grant  # noqa: E402

HELPER = r'''
import AppKit
import ApplicationServices

func fail(_ message: String) -> Never { print("FAIL: \(message)"); fflush(stdout); exit(1) }
typealias Main = @convention(c) () -> Int32
typealias Copy = @convention(c) (Int32) -> Unmanaged<CFArray>?
func fullscreen() -> Bool {
    guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_LAZY),
          let m = dlsym(h, "SLSMainConnectionID"), let c = dlsym(h, "SLSCopyManagedDisplaySpaces") else { fail("no SkyLight") }
    let displays = unsafeBitCast(c, to: Copy.self)(unsafeBitCast(m, to: Main.self)())?.takeRetainedValue() as? [[String: Any]] ?? []
    return displays.contains { (($0["Current Space"] as? [String: Any])?["type"] as? NSNumber)?.intValue == 4 }
}
func menuBarWindows() -> [[String: Any]] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { info in
        guard let layer = info[kCGWindowLayer as String] as? Int, layer == Int(CGWindowLevelForKey(.mainMenuWindow)),
              let bounds = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return ["owner": info[kCGWindowOwnerName as String] as? String ?? "", "name": info[kCGWindowName as String] as? String ?? "",
                "y": bounds["Y"] as? Double ?? -1, "height": bounds["Height"] as? Double ?? 0,
                "alpha": info[kCGWindowAlpha as String] as? Double ?? 0]
    }
}
let arguments = CommandLine.arguments
switch arguments[1] {
case "state":
    // Pixels: the fullscreen fixture is pure green. The menu bar covers the top rows when shown.
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: arguments[2])),
          let bitmap = NSBitmapImageRep(data: data) else { fail("unreadable capture") }
    let scale = Double(bitmap.pixelsWide) / Double(NSScreen.screens.first?.frame.width ?? 1)
    let band = max(1, Int(10 * scale)), rows = min(bitmap.pixelsHigh, Int(80 * scale))
    var green = 0, total = 0, cyan = 0
    for y in 0..<rows {
        for x in stride(from: 0, to: bitmap.pixelsWide, by: y < band ? 2 : 1) {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
            if y < band { total += 1; if g > 0.8, r < 0.3, b < 0.3 { green += 1 } }
            if g > 0.7, b > 0.7, r < 0.6 { cyan += 1 }
        }
    }
    let windows = menuBarWindows()
    let shownWindow = windows.contains { ($0["y"] as? Double ?? -1) >= 0 && ($0["alpha"] as? Double ?? 0) > 0.5 }
    let fraction = total > 0 ? Double(green) / Double(total) : 0
    let result: [String: Any] = ["fullscreen": fullscreen(), "greenTop": fraction, "cyan": cyan,
                                 "menuBarWindowShown": shownWindow, "menuBarWindows": windows]
    print(String(data: try! JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
case "fullscreen":
    print(fullscreen() ? "1" : "0")
case "hover", "away":
    guard AXIsProcessTrusted() else { fail("the probe lacks Accessibility") }
    let frame = CGDisplayBounds(CGMainDisplayID())
    let seconds = Double(arguments[2])!
    let top = arguments[1] == "hover"
    let end = Date().addingTimeInterval(seconds)
    var step = 0
    while Date() < end {
        let point = top ? CGPoint(x: frame.midX + CGFloat(step % 3) * 4, y: frame.minY + CGFloat(step % 2))
                        : CGPoint(x: frame.midX, y: frame.midY + CGFloat(step % 2) * 4)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)!
            .post(tap: .cghidEventTap)
        step += 1
        usleep(50_000)
    }
    print("MOVED \(arguments[1]) \(step)")
default:
    fail("unknown command")
}
'''

WINDOW = r'''
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 900, height: 600),
                      styleMask: [.titled, .resizable, .closable, .miniaturizable], backing: .buffered, defer: false)
window.title = "Fullscreen fixture"
window.backgroundColor = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
window.collectionBehavior = [.fullScreenPrimary]
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
DispatchQueue.main.asyncAfter(deadline: .now() + 1) { window.toggleFullScreen(nil) }
DispatchQueue.main.asyncAfter(deadline: .now() + 240) { exit(1) }
app.run()
'''


def wait_for(predicate, seconds, label):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.5)
    raise RuntimeError(f"timed out waiting for {label}")


def main():
    if sys.platform != "darwin":
        raise RuntimeError("needs a macOS desktop")
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--output", type=Path, default=Path("build/native-fullscreen"))
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    installed = Path("/Applications/Flux.app")
    if installed.exists():
        raise RuntimeError("/Applications/Flux.app already exists on this runner")
    executable = installed / "Contents/MacOS/Flux"
    results, processes, cleanup = [], [], []
    video = None
    with tempfile.TemporaryDirectory(prefix="flux-native-fullscreen-") as directory:
        # `open` reports the real path (/private/var/...), so match on that.
        temporary = Path(directory).resolve()
        try:
            _, helper = bundle(temporary, "FluxFullscreenProbe", "com.flux.native-fullscreen-probe", HELPER, temporary)
            window_app, _ = bundle(temporary, "FluxFullscreenFixture", f"com.flux.fullscreen-window.{uuid.uuid4().hex[:12]}",
                                   WINDOW, temporary)
            plist = window_app / "Contents/Info.plist"
            info = plistlib.loads(plist.read_bytes())
            info.pop("LSUIElement", None)
            plist.write_bytes(plistlib.dumps(info))
            run(["codesign", "--force", "--sign", "-", str(window_app)], 20)
            identifier = f"com.flux.fullscreen-cyan.{uuid.uuid4().hex[:12]}"
            cyan_app, _ = bundle(temporary, "FluxFixtureCyan", identifier, FIXTURE, temporary)
            target = Path("/Applications") / f"FluxFullscreenFixture-cyan-{uuid.uuid4().hex[:8]}.app"
            shutil.copytree(cyan_app, target, symlinks=True)
            cleanup.append(lambda: shutil.rmtree(target, ignore_errors=True))
            run([REGISTER, "-f", str(target)], 20)
            cleanup.append(lambda: run([REGISTER, "-u", str(target)], 20, check=False))
            processes.append(subprocess.Popen([str(target / "Contents/MacOS/FluxFixtureCyan"), "0", "1"],
                                              start_new_session=True))
            run(["/usr/bin/ditto", str(args.app), str(installed)], 60)
            cleanup.append(lambda: shutil.rmtree(installed, ignore_errors=True))
            layout = plistlib.dumps({"hidden": [identifier], "alwaysHidden": []}, fmt=plistlib.FMT_XML).decode()
            layout = layout[layout.index("<dict>"):layout.rindex("</dict>") + len("</dict>")]
            run(["defaults", "write", "com.flux.menubar", "flux.macOS27IconLayout", layout])
            run(["defaults", "write", "com.flux.menubar", "flux.autoRehide", "-bool", "false"])
            cleanup.append(lambda: run(["defaults", "delete", "com.flux.menubar"], 10, check=False))
            try:
                video = subprocess.Popen(["/usr/sbin/screencapture", "-x", "-v", "-V", "170",
                                          str(output / "fullscreen.mov")], start_new_session=True,
                                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except OSError:
                video = None

            def is_fullscreen():
                return run([str(helper), "fullscreen"], 10).strip().endswith("1")

            def observe(path):
                run(["/usr/sbin/screencapture", "-x", str(path)], 20)
                observed = json.loads(run([str(helper), "state", str(path)], 30).strip().splitlines()[-1])
                shown = observed["menuBarWindowShown"] or observed["greenTop"] < 0.6
                return observed, {"fullscreen": observed["fullscreen"], "menuBar": shown, "cyan": observed["cyan"] > 20}

            def state(phase, label, expect):
                path = output / f"{len(results):02d}-{phase}-{label}.png"
                time.sleep(0.3)
                observed, facts = observe(path)
                passed = all(facts[key] == value for key, value in expect.items())
                results.append(dict(phase=phase, step=label, expect=expect, facts=facts, observed=observed,
                                    passed=passed, image=path.name))
                print(f"{phase}/{label}: {facts} expect={expect} {'PASS' if passed else 'FAIL'} {observed}", flush=True)
                (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
                return facts

            def fullscreen_round(phase, menu_bar_expected):
                window_binary = window_app / "Contents/MacOS/FluxFullscreenFixture"
                # Open through LaunchServices so the window may activate and go fullscreen.
                run(["/usr/bin/open", "-n", str(window_app)], 20)
                try:
                    wait_for(is_fullscreen, 20, "a fullscreen Space")
                    print(run([str(helper), "away", "3"], 20), flush=True)
                    state(phase, "fullscreen-pointer-away", {"fullscreen": True, "menuBar": False})
                    print(run([str(helper), "hover", "3"], 20), flush=True)
                    expect = {"fullscreen": True}
                    if menu_bar_expected is not None:
                        expect["menuBar"] = menu_bar_expected
                    facts = state(phase, "fullscreen-pointer-top", expect)
                    print(run([str(helper), "away", "2"], 20), flush=True)
                    return facts["menuBar"]
                finally:
                    for pid in flux_pids(window_binary):
                        os.kill(pid, signal.SIGTERM)
                    wait_for(lambda: not flux_pids(window_binary), 10, "the fullscreen fixture to quit")
                    wait_for(lambda: not is_fullscreen(), 20, "the desktop Space")
                    time.sleep(2)

            def launch_flux(env):
                process = subprocess.Popen([str(executable)], env=dict(os.environ, **env), start_new_session=True,
                                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                wait_for(lambda: len(flux_pids(executable)) == 1, 15, "one native Flux process")
                time.sleep(3)
                return process

            def quit_flux(process):
                process.terminate()
                process.wait(timeout=20)

            with accessibility_grant("com.flux.native-fullscreen-probe"):
                # Fixture apps can take several seconds to draw on a fresh runner.
                wait_for(lambda: observe(output / "wait.png")[1]["cyan"], 20, "the cyan fixture icon")
                (output / "wait.png").unlink(missing_ok=True)
                state("control", "desktop", {"fullscreen": False, "cyan": True})
                fullscreen_round("control", True)

                flux = launch_flux({"FLUX_PROBE_KEEP_HIDING_IN_FULLSCREEN": "1"})
                try:
                    state("blocked", "desktop-hidden", {"fullscreen": False, "cyan": False})
                    reproduced = not fullscreen_round("blocked", None)
                finally:
                    quit_flux(flux)
                print(f"0.22.2 behaviour blocks the fullscreen menu bar: {reproduced}", flush=True)

                flux = launch_flux({})
                try:
                    state("fixed", "desktop-hidden", {"fullscreen": False, "cyan": False})
                    fullscreen_round("fixed", True)
                    state("fixed", "desktop-hidden-again", {"fullscreen": False, "cyan": False})
                finally:
                    quit_flux(flux)
        finally:
            for pid in flux_pids(executable):
                os.kill(pid, signal.SIGKILL)
            run(["/usr/bin/pkill", "-KILL", "-f", "FluxFullscreenFixture.app/Contents/MacOS"], 10, check=False)
            for process in processes:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            if video:
                try:
                    os.killpg(video.pid, signal.SIGINT)
                    video.wait(timeout=20)
                except (ProcessLookupError, subprocess.TimeoutExpired):
                    pass
            for action in reversed(cleanup):
                action()
    failed = [f"{r['phase']}/{r['step']}" for r in results if not r["passed"]]
    reproduced = any(r["phase"] == "blocked" and r["step"] == "fullscreen-pointer-top" and not r["facts"]["menuBar"]
                     for r in results)
    summary = dict(result="pass" if results and not failed else "fail", failed=failed, steps=len(results),
                   reproduced_without_fix=reproduced, video=(output / "fullscreen.mov").exists())
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
