#!/usr/bin/env python3
"""Prove the Menu Bar layout editor reorders and regroups real items on a CI Mac.

Three disposable fixtures draw solid magenta, cyan and yellow status items.
FluxMenuBarArrangeProbe runs the real PositionMenuBarService and the Menu Bar
page, and picks the editor's right-click commands: "Move Left" until magenta
and cyan swap places, then "Move to Hidden" for yellow. After each step this
script captures the screen and reads the order from fixture pixels. CI only:
it writes a temporary Accessibility grant.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import queue
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from probe_tcc import accessibility_grant, screen_capture_grant  # noqa: E402

ROWS = 80
PROBE_ID = "com.flux.arrange-probe"
COLORS = {"magenta": (1, 0, 1), "cyan": (0, 1, 1), "yellow": (1, 1, 0)}
MEASURE = r'''
import AppKit
guard let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])),
      let bitmap = NSBitmapImageRep(data: data) else { print("FAIL: unreadable capture"); exit(1) }
let rows = min(bitmap.pixelsHigh, Int(CommandLine.arguments[2])!)
var counts = ["magenta": 0, "cyan": 0, "yellow": 0]
var sums = ["magenta": 0, "cyan": 0, "yellow": 0]
for y in 0..<rows {
    for x in 0..<bitmap.pixelsWide {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.9 else { continue }
        let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
        var name: String?
        if r > 0.7, b > 0.7, g < 0.4 { name = "magenta" }
        else if g > 0.7, b > 0.7, r < 0.6 { name = "cyan" }
        else if r > 0.75, g > 0.75, b < 0.35 { name = "yellow" }
        if let name { counts[name]! += 1; sums[name]! += x }
    }
}
var parts: [String] = []
for name in ["magenta", "cyan", "yellow"] {
    let count = counts[name]!
    let x = count > 0 ? Double(sums[name]!) / Double(count) : -1
    parts.append("\"\(name)\": {\"count\": \(count), \"x\": \(x)}")
}
print("{" + parts.joined(separator: ", ") + ", \"width\": \(bitmap.pixelsWide)}")
'''

FIXTURE = r'''
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let item = NSStatusBar.system.statusItem(withLength: 24)
let marker = NSImage(size: NSSize(width: 18, height: 18))
marker.lockFocus()
let values = CommandLine.arguments.dropFirst().map { CGFloat(Double($0)!) }
NSColor(srgbRed: values[0], green: values[1], blue: values[2], alpha: 1).setFill()
NSRect(x: 0, y: 0, width: 18, height: 18).fill()
marker.unlockFocus()
item.button?.image = marker
DispatchQueue.main.asyncAfter(deadline: .now() + 420) { exit(1) }
app.run()
'''
REGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


def run(command, seconds=60, check=True, cwd=None):
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                               start_new_session=True, cwd=cwd)
    try:
        output, _ = process.communicate(timeout=seconds)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        raise RuntimeError(f"{command[0]} exceeded {seconds}s")
    if check and process.returncode:
        raise RuntimeError(f"{command[0]} exited {process.returncode}: {output[-3000:]}")
    return output


def swift_app(directory, name, identifier, source, temporary):
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


def probe_app(directory, root):
    """Wrap the package's probe binary in a bundle, so it has a com.flux. identity."""
    run(["swift", "build", "--product", "FluxMenuBarArrangeProbe"], 600, cwd=root)
    built = Path(run(["swift", "build", "--show-bin-path"], 60, cwd=root).strip().splitlines()[-1]) / "FluxMenuBarArrangeProbe"
    app = directory / "FluxArrangeProbe.app"
    binary = app / "Contents/MacOS/FluxArrangeProbe"
    binary.parent.mkdir(parents=True)
    shutil.copy2(built, binary)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": PROBE_ID, "CFBundleExecutable": "FluxArrangeProbe",
        "CFBundlePackageType": "APPL", "LSUIElement": True}))
    run(["codesign", "--force", "--sign", "-", str(app)], 30)
    return binary


def main():
    if sys.platform != "darwin":
        raise RuntimeError("needs a macOS desktop")
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path("build/native-arrange"))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    results, fixtures, cleanup = [], [], []
    probe, video = None, None
    with tempfile.TemporaryDirectory(prefix="flux-native-arrange-") as directory:
        temporary = Path(directory)
        try:
            _, measure = swift_app(temporary, "FluxArrangeMeasure", "com.flux.arrange-measure", MEASURE, temporary)
            binary = probe_app(temporary, root)
            ids = {}
            for name, (red, green, blue) in COLORS.items():
                identifier = f"com.flux.arrange-{name}.{uuid.uuid4().hex[:12]}"
                app, _ = swift_app(temporary, "FluxArrange" + name.title(), identifier, FIXTURE, temporary)
                target = Path("/Applications") / f"FluxArrangeFixture-{name}-{uuid.uuid4().hex[:8]}.app"
                shutil.copytree(app, target, symlinks=True)
                cleanup.append(lambda t=target: shutil.rmtree(t, ignore_errors=True))
                run([REGISTER, "-f", str(target)], 20)
                cleanup.append(lambda t=target: run([REGISTER, "-u", str(t)], 20, check=False))
                fixtures.append(subprocess.Popen([str(target / "Contents/MacOS" / app.stem), str(red), str(green), str(blue)],
                                                 start_new_session=True))
                ids[name] = identifier
                time.sleep(1)

            def measure_screen(label):
                path = output / f"{len(results):02d}-{label}.png"
                run(["/usr/sbin/screencapture", "-x", str(path)], 20)
                return path, json.loads(run([str(measure), str(path), str(ROWS)], 30).strip().splitlines()[-1])

            # Fixture apps can take several seconds to draw on a fresh runner.
            deadline = time.monotonic() + 30
            while True:
                path, counts = measure_screen("baseline-wait")
                path.unlink(missing_ok=True)
                if all(counts[name]["count"] > 20 for name in COLORS):
                    break
                if time.monotonic() > deadline:
                    raise RuntimeError(f"fixtures did not appear: {counts}")
                time.sleep(1)

            try:
                video = subprocess.Popen(["/usr/sbin/screencapture", "-x", "-v", "-V", "75", str(output / "arrange.mov")],
                                         start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except OSError:
                video = None

            order = {}

            def check(step, line):
                time.sleep(1.5)
                path, counts = measure_screen(step)
                seen = {name: counts[name]["count"] > 20 for name in COLORS}
                expect = {"magenta": True, "cyan": True, "yellow": step != "grouped-collapsed"}
                magenta_left = counts["magenta"]["x"] < counts["cyan"]["x"]
                if step == "before":
                    order["magenta_left"] = magenta_left
                swapped = magenta_left != order.get("magenta_left")
                passed = seen == expect and (step == "before" or swapped)
                results.append(dict(step=step, expect=expect, seen=seen, counts=counts, magenta_left=magenta_left,
                                    swapped=swapped, passed=passed, image=path.name, probe=line))
                print(f"{step}: seen={seen} magenta_left={magenta_left} swapped={swapped} {'PASS' if passed else 'FAIL'}",
                      flush=True)
                (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")

            with accessibility_grant(PROBE_ID), screen_capture_grant(PROBE_ID):
                probe = subprocess.Popen([str(binary), ids["magenta"], ids["cyan"], ids["yellow"]],
                                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                         text=True, bufsize=1, start_new_session=True)
                lines = queue.Queue()
                threading.Thread(target=lambda: [lines.put(line) for line in probe.stdout] + [lines.put(None)],
                                 daemon=True).start()
                log = (output / "probe.log").open("w")
                finished = None
                deadline = time.monotonic() + 300
                while finished is None:
                    try:
                        line = lines.get(timeout=max(1, deadline - time.monotonic()))
                    except queue.Empty:
                        raise RuntimeError("the arrange probe stopped answering")
                    if line is None:
                        break
                    log.write(line)
                    log.flush()
                    print(line.rstrip(), flush=True)
                    if line.startswith("STEP "):
                        step = line.split()[1]
                        check(step, line.strip())
                        probe.stdin.write("\n")
                        probe.stdin.flush()
                    elif line.startswith(("PASS", "FAIL")):
                        finished = line.strip()
                status = probe.wait(timeout=30)
                log.close()
                if status != 0 or finished != "PASS":
                    raise RuntimeError(f"the arrange probe ended with {status}: {finished}")
        finally:
            if probe and probe.poll() is None:
                os.killpg(probe.pid, signal.SIGKILL)
            for process in fixtures:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            if video:
                # A timed recording saves its file only when it runs to the end.
                try:
                    video.wait(timeout=100)
                except subprocess.TimeoutExpired:
                    os.killpg(video.pid, signal.SIGINT)
            for action in reversed(cleanup):
                action()
            run(["defaults", "delete", PROBE_ID], 10, check=False)
    steps = ["before", "reordered", "grouped-editor-open", "grouped-collapsed", "grouped-revealed"]
    failed = [r["step"] for r in results if not r["passed"]]
    missing = [step for step in steps if step not in {r["step"] for r in results}]
    summary = dict(result="pass" if not failed and not missing else "fail", failed=failed, missing=missing,
                   steps=len(results))
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary), flush=True)
    if failed or missing:
        raise SystemExit(1)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda signum, _frame: (_ for _ in ()).throw(SystemExit(128 + signum)))
    try:
        main()
    except RuntimeError as error:
        print(f"FAIL: {error}", file=sys.stderr, flush=True)
        raise SystemExit(1)
