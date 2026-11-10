#!/usr/bin/env python3
"""Map macOS 27's numbered menu bar system items on a CI Mac.

MBAssessmentModeConfiguration takes `allowedSystemItems` numbers. MenuBarAgent's
MenuBarSystemItemIdentifier enum names 11 items (battery, bluetooth, clock,
displays, keyboard, volume, wifi, and Control Center parts), but which number
is which is not documented. For each number this probe holds an assertion
that leaves only that number out, photographs the menu bar, and reports
which system items vanished. It also checks whether leaving out the
TextInputMenuAgent bundle hides the keyboard menu.

CI only: it enables one extra keyboard layout so the input menu shows, and
disables it again at the end.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from probe_native_hiding import bundle, run  # noqa: E402
from probe_tcc import accessibility_grant  # noqa: E402

HELPER = r'''
import AppKit
import ApplicationServices
import Carbon

@objc protocol Assertion {
    @objc(activateWithConfiguration:completionHandler:)
    func activate(with configuration: AnyObject, completionHandler: @escaping @Sendable (NSError?) -> Void)
    func invalidate()
}
func fail(_ message: String) -> Never { print("FAIL: \(message)"); fflush(stdout); exit(1) }
func emit(_ value: Any) {
    print(String(data: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!)
    fflush(stdout)
}
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func frame(_ element: AXUIElement) -> CGRect? {
    guard let p = attribute(element, kAXPositionAttribute), let s = attribute(element, kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &point); AXValueGetValue(s as! AXValue, .cgSize, &size)
    return CGRect(origin: point, size: size)
}
func source(_ id: String) -> TISInputSource? {
    let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
    let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] ?? []
    return list.first
}
let arguments = CommandLine.arguments
switch arguments[1] {
case "input":
    guard let layout = source(arguments[3]) else { fail("no input source \(arguments[3])") }
    let status = arguments[2] == "on" ? TISEnableInputSource(layout) : TISDisableInputSource(layout)
    emit(["status": Int(status)])
case "dump":
    guard AXIsProcessTrusted() else { fail("the probe lacks Accessibility") }
    var items: [[String: Any]] = []
    func walk(_ element: AXUIElement, _ owner: String, _ depth: Int) {
        let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        for child in children {
            let role = attribute(child, kAXRoleAttribute) as? String ?? ""
            let subrole = attribute(child, kAXSubroleAttribute) as? String ?? ""
            if let f = frame(child), f.width > 0, role == (kAXMenuBarItemRole as String) || subrole == "AXMenuExtra" {
                items.append(["owner": owner, "identifier": attribute(child, kAXIdentifierAttribute) as? String ?? "",
                              "description": attribute(child, kAXDescriptionAttribute) as? String ?? "",
                              "title": attribute(child, kAXTitleAttribute) as? String ?? "",
                              "role": role, "subrole": subrole,
                              "x": f.minX, "y": f.minY, "width": f.width, "height": f.height])
            }
            if depth < 3 { walk(child, owner, depth + 1) }
        }
    }
    for app in NSWorkspace.shared.runningApplications {
        guard let id = app.bundleIdentifier else { continue }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.3)
        if let bar = attribute(element, kAXExtrasMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() {
            walk(bar as! AXUIElement, id, 0)
        }
    }
    emit(items)
case "assert":
    // assert <system numbers csv or -> <excluded bundles csv or -> <seconds>
    guard dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_NOW) != nil,
          let assertionClass = NSClassFromString("MBAssessmentModeAssertion") as? NSObject.Type,
          let configurationClass = NSClassFromString("MBAssessmentModeConfiguration") as? NSObject.Type else { fail("no MenuBarClientCore") }
    let numbers = arguments[2] == "-" ? [] : arguments[2].split(separator: ",").map { NSNumber(value: Int($0)!) }
    let excluded = Set(arguments[3] == "-" ? [] : arguments[3].split(separator: ",").map(String.init))
    var allowed = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    allowed.formUnion(["com.apple.controlcenter", "com.apple.MenuBarAgent", "com.apple.systemuiserver",
                       "com.apple.TextInputMenuAgent", "com.apple.Spotlight", "com.apple.Siri"])
    allowed.subtract(excluded)
    let allocated = (configurationClass as AnyObject).perform(NSSelectorFromString("alloc"))!.takeUnretainedValue()
    let configuration = allocated.perform(NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:"),
                                          with: numbers as NSArray, with: Array(allowed).sorted() as NSArray)!.takeRetainedValue()
    let assertion = unsafeBitCast(assertionClass.init(), to: Assertion.self)
    nonisolated(unsafe) var done = false
    nonisolated(unsafe) var failure: String?
    assertion.activate(with: configuration) { error in failure = error?.localizedDescription; done = true }
    let deadline = Date().addingTimeInterval(10)
    while !done && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    guard done, failure == nil else { fail("activation: \(failure ?? "timeout")") }
    print("READY"); fflush(stdout)
    RunLoop.current.run(until: Date().addingTimeInterval(Double(arguments[4])!))
    assertion.invalidate()
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    print("RELEASED"); fflush(stdout)
case "notify":
    DistributedNotificationCenter.default().postNotificationName(.init(arguments[2]), object: nil, userInfo: nil,
                                                                 deliverImmediately: true)
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFNotificationName(arguments[2] as CFString), nil, nil, true)
    emit(["posted": arguments[2]])
case "present":
    // present <baseline.png> <test.png> <items.json> <scale>: which baseline item crops still appear.
    guard let a = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: arguments[2]))),
          let b = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: arguments[3]))) else { fail("captures") }
    let items = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: arguments[4]))) as! [[String: Any]]
    let scale = Double(arguments[5])!
    func luma(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> Double {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return 0 }
        return Double(c.redComponent * 0.3 + c.greenComponent * 0.59 + c.blueComponent * 0.11)
    }
    let band = min(Int(40 * scale), b.pixelsHigh)
    var rows = [[Double]](repeating: [], count: band)
    for y in 0..<band { rows[y] = (0..<b.pixelsWide).map { luma(b, $0, y) } }
    var result: [[String: Any]] = []
    for item in items {
        let x0 = Int((item["x"] as! Double) * scale) + 2, w = max(4, Int((item["width"] as! Double) * scale) - 4)
        let y0 = Int((item["y"] as! Double) * scale) + 2, h = min(band - y0, max(4, Int((item["height"] as! Double) * scale) - 4))
        guard x0 >= 0, x0 + w <= a.pixelsWide, y0 >= 0, h > 0 else { result.append(["present": NSNull()]); continue }
        var crop = [[Double]](repeating: [], count: h)
        for dy in 0..<h { crop[dy] = (0..<w).map { luma(a, x0 + $0, y0 + dy) } }
        let mean = crop.joined().reduce(0, +) / Double(w * h)
        let contrast = crop.joined().map { abs($0 - mean) }.reduce(0, +) / Double(w * h)
        var best = Double.infinity
        for sx in 0...(b.pixelsWide - w) {
            var total = 0.0
            for dy in stride(from: 0, to: h, by: 2) {
                for dx in stride(from: 0, to: w, by: 2) { total += abs(crop[dy][dx] - rows[y0 + dy][sx + dx]) }
                if total > best { break }
            }
            best = min(best, total)
        }
        let samples = Double(((h + 1) / 2) * ((w + 1) / 2))
        result.append(["present": best / samples < 0.04, "difference": best / samples, "contrast": contrast])
    }
    emit(result)
default:
    fail("unknown command")
}
'''

LAYOUT = "com.apple.keylayout.French"


AGENT = "/System/Library/CoreServices/TextInputMenuAgent.app/Contents/MacOS/TextInputMenuAgent"


def input_menu(helper, capture, vanished, labels, report, output):
    """Find a way to hide the keyboard input menu, which the assertion keeps."""
    hints = sorted({line.strip() for line in run(["/usr/bin/strings", "-a", AGENT], 60).splitlines()
                    if any(word in line for word in ("Visib", "visible", "TextInputMenu", "Notification", "ShowInput"))})
    (output / "agent-strings.txt").write_text("\n".join(hints) + "\n")
    print("HINTS", json.dumps(hints[:200]), flush=True)
    print(run(["defaults", "read", "com.apple.TextInputMenu"], 10, check=False), flush=True)

    def check(name):
        time.sleep(3)
        gone, _ = vanished(capture(name))
        report["input"][name] = gone
        print(f"{name}: vanished {gone}", flush=True)
        return any("TextInputMenuAgent" in label for label in gone)

    report["input"] = {}
    # Apple's own status-item apps: does the bundle allow list hide them?
    extras = run(["/usr/bin/find", "/System/Applications/Passwords.app", "-name", "*.app", "-maxdepth", "6"], 30,
                 check=False).split()
    print("PASSWORDS APPS", extras, flush=True)
    for extra in extras:
        if "Menu" not in extra:
            continue
        info = run(["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleIdentifier", extra + "/Contents/Info.plist"], 10,
                   check=False).strip()
        run(["/usr/bin/open", "-g", extra], 20, check=False)
        time.sleep(4)
        items_now = json.loads(run([str(helper), "dump"], 60).strip().splitlines()[-1])
        print("PASSWORDS ITEMS", [i for i in items_now if "assword" in i["owner"]], flush=True)
        everything = ",".join(str(n) for n in range(64))
        report["input"]["passwords-bundle"] = info
        base = capture("passwords-shown")
        process = subprocess.Popen([str(helper), "assert", everything, info, "6"], stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True, start_new_session=True)
        try:
            process.stdout.readline()
            time.sleep(2.5)
            hidden_path = capture("passwords-excluded")
        finally:
            process.wait(timeout=20)
        print("PASSWORDS shown vs excluded:", run([str(helper), "present", str(base), str(hidden_path),
              str(output / "items.json"), "1"], 300).strip()[-400:], flush=True)
        run(["/usr/bin/pkill", "-f", extra], 10, check=False)
    try:
        run(["defaults", "write", "com.apple.TextInputMenu", "visible", "-bool", "false"], 10)
        if not check("pref-only"):
            names = [h for h in hints if h.startswith("com.apple.") and "." in h and " " not in h][:40]
            for name in names:
                run([str(helper), "notify", name], 10, check=False)
            if not check("pref-and-notifications"):
                run(["/usr/bin/killall", "TextInputMenuAgent"], 10, check=False)
                check("pref-and-agent-restart")
    finally:
        run(["defaults", "write", "com.apple.TextInputMenu", "visible", "-bool", "true"], 10)
        run(["/usr/bin/killall", "TextInputMenuAgent"], 10, check=False)
        time.sleep(4)
        report["input"]["restored"] = vanished(capture("restored"))[0]
        print(f"restored: vanished {report['input']['restored']}", flush=True)


def main():
    if sys.platform != "darwin":
        raise RuntimeError("needs a macOS desktop")
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path("build/system-items"))
    parser.add_argument("--mode", choices=["numbers", "input"], default="numbers")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    report = {"numbers": {}, "bundle": {}}
    with tempfile.TemporaryDirectory(prefix="flux-system-items-") as directory:
        temporary = Path(directory).resolve()
        _, helper = bundle(temporary, "FluxSystemItemsProbe", "com.flux.system-items-probe", HELPER, temporary)
        print(run([str(helper), "input", "on", LAYOUT], 20), flush=True)
        try:
            time.sleep(4)
            screen_width = int(float(run(["/usr/bin/osascript", "-l", "JavaScript", "-e",
                                          "ObjC.import('AppKit'); $.NSScreen.mainScreen.frame.size.width"], 20).strip()))

            def capture(name):
                path = output / f"{name}.png"
                run(["/usr/sbin/screencapture", "-x", "-R", f"0,0,{screen_width},40", str(path)], 20)
                return path

            def held(numbers, excluded, name):
                process = subprocess.Popen([str(helper), "assert", numbers, excluded, "6"], stdout=subprocess.PIPE,
                                           stderr=subprocess.STDOUT, text=True, start_new_session=True)
                try:
                    line = process.stdout.readline().strip()
                    if line != "READY":
                        raise RuntimeError(f"assertion {name}: {line} {process.stdout.read()}")
                    time.sleep(2.5)
                    return capture(name)
                finally:
                    process.wait(timeout=20)

            with accessibility_grant("com.flux.system-items-probe"):
                everything = ",".join(str(n) for n in range(64))
                baseline = held(everything, "-", "baseline")
                items = json.loads(run([str(helper), "dump"], 60).strip().splitlines()[-1])
                items = [i for i in items if i["y"] < 40]
                (output / "items.json").write_text(json.dumps(items, indent=2) + "\n")
                for item in items:
                    print("ITEM", item["owner"], item["identifier"], item["description"], item["x"], item["width"], flush=True)
                # Pixel scale of the capture against AX points.
                from_png = run(["/usr/bin/sips", "-g", "pixelWidth", str(baseline)], 10)
                width_px = int(from_png.strip().split()[-1])
                scale = width_px / screen_width
                labels = [f"{i['owner']}|{i['identifier'] or i['description']}" for i in items]

                def vanished(path):
                    rows = json.loads(run([str(helper), "present", str(baseline), str(path), str(output / "items.json"),
                                           str(scale)], 300).strip().splitlines()[-1])
                    return [label for label, row in zip(labels, rows) if row.get("present") is False], rows

                if args.mode == "input":
                    input_menu(helper, capture, vanished, labels, report, output)
                    raise StopIteration
                for number in range(12):
                    rest = ",".join(str(n) for n in range(64) if n != number)
                    gone, rows = vanished(held(rest, "-", f"without-{number:02d}"))
                    report["numbers"][str(number)] = gone
                    print(f"without system item {number}: vanished {gone}", flush=True)
                gone, _ = vanished(held("-", "-", "without-all-numbers"))
                report["numbers"]["none-allowed"] = gone
                print(f"no system items allowed: vanished {gone}", flush=True)
                for bundle_id in ["com.apple.TextInputMenuAgent", "com.apple.controlcenter", "com.apple.Spotlight"]:
                    gone, _ = vanished(held(everything, bundle_id, f"without-{bundle_id}"))
                    report["bundle"][bundle_id] = gone
                    print(f"without bundle {bundle_id}: vanished {gone}", flush=True)
                report["items"] = labels
        except StopIteration:
            pass
        finally:
            print(run([str(helper), "input", "off", LAYOUT], 20, check=False), flush=True)
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report), flush=True)


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as error:
        print(f"FAIL: {error}", file=sys.stderr, flush=True)
        raise SystemExit(1)
