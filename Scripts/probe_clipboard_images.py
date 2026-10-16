#!/usr/bin/env python3
"""Cold-latency, memory and correctness probe for ClipboardMonitor.thumbnailData.

Three variants, each compiled with the same `swiftc -O -swift-version 5`:

  baseline  Sources/Flux/Services/ClipboardMonitor.swift at ref 6fde908
  current   the same path in the current checkout
  proposal  the same real product file plus a fixture-only ImageIO method:
            CGImageSourceCreateWithData(kCGImageSourceShouldCache: false)
            -> CGImageSourceCreateThumbnailAtIndex(max 64, fromImageAlways, withTransform)
            -> CGImageDestination PNG

The product file is compiled verbatim, unmodified, and the fixture `main.swift`
calls the real `ClipboardMonitor.thumbnailData`. No method is sliced out with a
regex or a brace scan, so a Swift body with nested braces cannot be misparsed.
Known limit: this needs the product file to compile standalone. If the app later
grows a cross-file reference in this file, the compile fails loudly instead of
silently measuring a truncated method.

One fresh process per (variant, case) run, so every cold latency, CPU delta,
ru_maxrss peak and phys_footprint belongs to a single decode. Three rounds, with
the variant order reversed every other round to cancel machine drift. Gates are
hard failures and exit 1. Speed is reported, never thresholded.

No product file is edited. No pasteboard, TCC prompt, preference or service is
touched: every call is a pure static function on bytes already in a file.
"""

import argparse
import hashlib
import json
import os
import signal
import statistics
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

ARTIFACT = "probe_clipboard_images_compact.py"
REPO = Path(__file__).resolve().parents[1]
SOURCE_REL = "Sources/Flux/Services/ClipboardMonitor.swift"
BASELINE_REF = "6fde90817068d06ecfae8eb6ec85c19e68af997b"
FLAGS = ["-O", "-swift-version", "5"]
TIMEOUTS = {"git": 60, "compile": 300, "generate": 180, "measure": 60, "validate": 60}
BOUND = 64  # ClipboardMonitor.thumbnailPixels

# EXIF orientation 6 = rotate 90 degrees clockwise for display.
STANDARD = {"top_left": "red", "top_right": "green", "bottom_left": "blue",
            "bottom_right": "white"}
ROTATED = {"top_left": "blue", "top_right": "red", "bottom_left": "white",
           "bottom_right": "green"}
PATCHES = {"red": (255, 0, 0), "green": (0, 255, 0), "blue": (0, 0, 255),
           "white": (255, 255, 255)}

# `dims`/`corners` are the proposal's exact expectations. `dims_any`/`corners_any`
# gate the product variants against every layout the real method may legitimately
# choose, which keeps those gates hard without guessing what NSImage does with an
# EXIF tag. `alpha` gates the centre window and corner opacity.
CASES = [
    dict(name="big-jpeg", file="big-jpeg.jpg", dims=(64, 48), corners=STANDARD,
         alpha="opaque-corners", note="4000x3000 opaque JPEG, four corner patches"),
    dict(name="big-png", file="big-png.png", dims=(64, 48), corners=STANDARD,
         alpha="transparent-centre", note="4000x3000 RGBA PNG, clear centre window"),
    dict(name="big-tiff", file="big-tiff.tiff", dims=(64, 48), corners=STANDARD,
         alpha="report-only", note="4000x3000 RGBA TIFF, writer alpha varies"),
    dict(name="tiny-16x8", file="tiny-16x8.png", dims=(16, 8), corners=STANDARD,
         dims_any=[(16, 8)], alpha="opaque-corners",
         note="no-upscale control, a 64 bound must not inflate it"),
    dict(name="invalid", file="invalid.bin", dims=None, corners=None,
         note="PNG magic then garbage, both must return nil"),
    dict(name="exif-rot90", file="exif-rot90.jpg", dims=(48, 64), corners=ROTATED,
         dims_any=[(64, 48), (48, 64)], corners_any=[STANDARD, ROTATED],
         alpha="opaque-corners",
         note="orientation 6, the proposal must apply it and swap the corners"),
]

START = time.monotonic()


def log(message):
    print("[%s +%5.1fs] %s" % (ARTIFACT, time.monotonic() - START, message), flush=True)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def median(values):
    return round(statistics.median(values), 1) if values else None


def stop(process):
    if process.poll() is not None:
        return
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(os.getpgid(process.pid), sig)
        except (ProcessLookupError, PermissionError):
            return
        try:
            process.wait(timeout=5)
            return
        except subprocess.TimeoutExpired:
            continue


def run(argv, seconds, label, cwd=None):
    """Bounded subprocess. Signals the whole process group, then reports.

    A missing tool is a normal result here, not a crash: the probe has to run
    its prepare step on a host with no Swift toolchain.
    """
    began = time.monotonic()
    try:
        process = subprocess.Popen(argv, cwd=cwd, start_new_session=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    except (FileNotFoundError, PermissionError) as error:
        log("%s unavailable: %s" % (label, error))
        return dict(rc=127, out="", err=str(error), timed_out=False, missing=True)
    timed_out = False
    try:
        out, err = process.communicate(timeout=seconds)
    except subprocess.TimeoutExpired:
        timed_out, out, err = True, "", ""
        stop(process)
    finally:
        stop(process)
    log("%s rc=%s %.2fs%s" % (label, process.returncode, time.monotonic() - began,
                              " TIMEOUT" if timed_out else ""))
    return dict(rc=process.returncode, out=out, err=err, timed_out=timed_out, missing=False)


def last_json(text):
    for line in reversed(text.splitlines()):
        line = line.strip()
        if line.startswith("{") and line.endswith("}"):
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                continue
    return None


def git(ref_path):
    result = run(["git", "show", ref_path], TIMEOUTS["git"], "git show", cwd=str(REPO))
    if result["rc"]:
        raise SystemExit("git show %s failed: %s" % (ref_path, result["err"][-400:]))
    return result["out"]


GENERATOR = r'''
// Separate process: builds the inputs. Its peak never joins a measured peak.
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("FAIL: " + message + "\n").data(using: .utf8)!)
    exit(1)
}
func space() -> CGColorSpace { CGColorSpaceCreateDeviceRGB() }

let quad = [("top_left", 1.0, 0.0, 0.0), ("top_right", 0.0, 1.0, 0.0),
            ("bottom_left", 0.0, 0.0, 1.0), ("bottom_right", 1.0, 1.0, 1.0)]
let bigW = 4000, bigH = 3000, winW = 1000, winH = 750

/// Top-left origin so the corner names read the way they are named.
func make(width: Int, height: Int, alpha: Bool, window: Bool) -> CGImage {
    let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue
                     : CGImageAlphaInfo.noneSkipLast.rawValue
    guard let context = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space(),
                                  bitmapInfo: info) else { fail("no context") }
    context.interpolationQuality = .none
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    let half = CGRect(x: 0, y: 0, width: width / 2, height: height / 2)
    func fill(_ rect: CGRect, _ rgb: (CGFloat, CGFloat, CGFloat), _ a: CGFloat) {
        context.setFillColor(CGColor(colorSpace: space(),
                                     components: [rgb.0, rgb.1, rgb.2, a])!)
        context.fill(rect)
    }
    context.setBlendMode(.copy)
    fill(CGRect(x: 0, y: 0, width: width, height: height), (0.5, 0.5, 0.5), 1)
    for (name, r, g, b) in quad {
        let left = name == "top_left" || name == "bottom_left"
        let top = name == "top_left" || name == "top_right"
        fill(CGRect(x: left ? half.minX : half.maxX, y: top ? half.minY : half.maxY,
                    width: half.width, height: half.height), (r, g, b), 1)
    }
    if window && alpha {
        fill(CGRect(x: CGFloat(width - winW) / 2, y: CGFloat(height - winH) / 2,
                    width: winW, height: winH), (0, 0, 0), 0)
    }
    context.setBlendMode(.normal)
    guard let image = context.makeImage() else { fail("no image") }
    return image
}

func write(_ image: CGImage, _ name: String, _ type: UTType, orientation: Int? = nil) {
    let url = out.appendingPathComponent(name)
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, type.identifier as CFString, 1, nil) else { fail("no destination") }
    var properties: [CFString: Any] = [:]
    if let orientation = orientation { properties[kCGImagePropertyOrientation] = orientation }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { fail("cannot write \(name)") }
}

let opaque = make(width: bigW, height: bigH, alpha: false, window: false)
let rgba = make(width: bigW, height: bigH, alpha: true, window: true)
write(opaque, "big-jpeg.jpg", .jpeg)
write(rgba, "big-png.png", .png)
write(rgba, "big-tiff.tiff", .tiff)
write(make(width: 16, height: 8, alpha: false, window: false), "tiny-16x8.png", .png)
write(opaque, "exif-rot90.jpg", .jpeg, orientation: 6)
var invalid = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
invalid.append(Data(repeating: 0x5A, count: 4096))
try! invalid.write(to: out.appendingPathComponent("invalid.bin"))
print("ok")
'''

RUNNER = r'''
// One fresh process per measured decode. Prints one JSON object and exits.
// The whole product file is compiled beside this; only the callee differs.
import AppKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

// PROPOSAL until a parent integrates it. Fixture only, never a product edit.
// Shape from https://developer.apple.com/documentation/imageio/cgimagesource and
// the WWDC 2018 Image Graphics best practices: downsample during decode so the
// full-resolution bitmap is never materialised. ShouldCache: false stops
// ImageIO keeping decoded pixels; fromImageAlways guarantees a thumbnail from a
// single-frame source; withTransform applies the EXIF orientation. A source
// already inside the bound is decoded as-is so the bound never upscales.
enum ProposalThumbnail {
    static func thumbnailData(fromRaw raw: Data, maxPixel: CGFloat) -> Data? {
        guard let source = CGImageSourceCreateWithData(raw as CFData, [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false
        ] as CFDictionary) else { return nil }
        guard CGImageSourceGetCount(source) > 0 else { return nil }
        var sourceWidth = 0
        var sourceHeight = 0
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            sourceWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            sourceHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        }
        let bound = max(1, Int(maxPixel))
        let image: CGImage?
        if max(sourceWidth, sourceHeight) > bound {
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: bound,
                kCGImageSourceShouldCacheImmediately: false
            ] as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCacheImmediately: false
            ] as CFDictionary)
        }
        guard let thumbnail = image else { return nil }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return encoded as Data
    }
}

/// macOS reports ru_maxrss in bytes; the unit is named in the JSON so a reader
/// never has to guess.
func residency() -> (cpu: Int64, peak: Int64) {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return (0, -1) }
    return (Int64(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000_000_000
            + Int64(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) * 1000,
            Int64(usage.ru_maxrss))
}

/// Live task_vm_info phys_footprint: a current value, not a high-water mark.
func footprint() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size
                                       / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return status == KERN_SUCCESS ? Int64(info.phys_footprint) : -1
}

let arguments = CommandLine.arguments
let input = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])
let useProposal = arguments[3] == "proposal"
let bound = CGFloat(Double(arguments[4]) ?? 64)
guard let raw = try? Data(contentsOf: input) else {
    FileHandle.standardError.write("FAIL: cannot read input\n".data(using: .utf8)!)
    exit(2)
}
let beforeResidency = residency()
let beforeFootprint = footprint()
let began = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
let thumbnail = useProposal
    ? ProposalThumbnail.thumbnailData(fromRaw: raw, maxPixel: bound)
    : ClipboardMonitor.thumbnailData(fromRaw: raw)
let finished = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
let afterResidency = residency()
let afterFootprint = footprint()
var outBytes = 0
if let thumbnail = thumbnail {
    do {
        try thumbnail.write(to: output)
        outBytes = thumbnail.count
    } catch {
        FileHandle.standardError.write("FAIL: cannot write output\n".data(using: .utf8)!)
        exit(3)
    }
}
let payload: [String: Any] = [
    "case": arguments[5],
    "variant": useProposal ? "proposal" : "product",
    "cold_latency_ms": round(Double(finished - began) / 1_000_000 * 1000) / 1000,
    "cpu_ns": afterResidency.cpu - beforeResidency.cpu,
    "ru_maxrss_bytes_before": beforeResidency.peak,
    "ru_maxrss_bytes_after": afterResidency.peak,
    "footprint_bytes_before": beforeFootprint,
    "footprint_bytes_after": afterFootprint,
    "input_bytes": raw.count,
    "output_bytes": outBytes,
    "returned_nil": thumbnail == nil,
]
print(String(data: try! JSONSerialization.data(withJSONObject: payload, options: []),
             encoding: .utf8)!)
'''

VALIDATOR = r'''
// Decodes one produced thumbnail and reports what it actually contains.
// Separate process so validation cost never enters a measured latency.
import AppKit
import CoreGraphics
import Foundation
import ImageIO

let noImage = "{\"width\":0,\"height\":0}"
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    print(noImage)
    exit(0)
}
let width = image.width, height = image.height
guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    print(noImage)
    exit(0)
}
context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
guard let pixels = context.data else { print(noImage); exit(0) }
let raw = pixels.assumingMemoryBound(to: UInt8.self)
let stride = context.bytesPerRow

func sample(_ fx: Double, _ fy: Double) -> [Int] {
    let x = min(width - 1, max(0, Int(Double(width) * fx)))
    // CoreGraphics origin is bottom-left; report in top-left terms.
    let y = min(height - 1, max(0, Int(Double(height) * fy)))
    let offset = stride * (height - 1 - y) + x * 4
    return [Int(raw[offset]), Int(raw[offset + 1]), Int(raw[offset + 2]), Int(raw[offset + 3])]
}

let positions = ["top_left": (0.08, 0.08), "top_right": (0.92, 0.08),
                 "bottom_left": (0.08, 0.92), "bottom_right": (0.92, 0.92)]
var corners: [String: [Int]] = [:]
var cornerAlpha: [Int] = []
for (name, point) in positions {
    let pixel = sample(point.0, point.1)
    corners[name] = [pixel[0], pixel[1], pixel[2]]
    cornerAlpha.append(pixel[3])
}
let centre = sample(0.5, 0.5)
print(String(data: try! JSONSerialization.data(withJSONObject: [
    "width": width, "height": height,
    "corners": corners,
    "min_corner_alpha": cornerAlpha.min() ?? -1,
    "center_rgb": [centre[0], centre[1], centre[2]],
    "center_alpha": centre[3],
    "aspect_ratio": round(Double(width) / Double(height) * 1000) / 1000,
] as [String: Any], options: []), encoding: .utf8)!)
'''


def classify(rgb):
    """Nearest fixture corner colour, or an unknown marker when nothing is close."""
    red, green, blue = rgb
    best, distance = "unknown", None
    for name, want in PATCHES.items():
        gap = sum((a - b) ** 2 for a, b in zip((red, green, blue), want))
        if distance is None or gap < distance:
            best, distance = name, gap
    return best if distance is not None and distance <= 90 * 90 else "unknown%s" % (rgb,)


def gates(case, report, strict):
    """Hard checks. `strict` is the proposal, which owns the exact expectations."""
    name = case["name"]
    if not report or not report.get("width"):
        return ["%s: the produced PNG could not be decoded for pixel checks" % name]
    dims = [case["dims"]] if strict else (case.get("dims_any") or [case["dims"]])
    layouts = [case["corners"]] if strict else (case.get("corners_any") or [case["corners"]])
    found = []
    if (report["width"], report["height"]) not in dims:
        found.append("%s: size %dx%d not in %s (size gate)"
                     % (name, report["width"], report["height"],
                        " or ".join("%dx%d" % d for d in dims)))
    seen = {corner: classify(rgb) for corner, rgb in report["corners"].items()}
    if not any(all(seen[k] == v for k, v in layout.items()) for layout in layouts):
        found.append("%s: pixels %s match no allowed layout (orientation/pixel gate)"
                     % (name, seen))
    if not any(abs(report["aspect_ratio"] - width / height) < 0.02 for width, height in dims):
        found.append("%s: wrong aspect ratio %.3f" % (name, report["aspect_ratio"]))
    if case["alpha"] == "opaque-corners" and report["min_corner_alpha"] != 255:
        found.append("%s: corner alpha %d is not 255, alpha was lost (alpha gate)"
                     % (name, report["min_corner_alpha"]))
    if case["alpha"] == "transparent-centre" and report["center_alpha"] != 0:
        found.append("%s: centre alpha %d is not 0, transparency was flattened (alpha gate)"
                     % (name, report["center_alpha"]))
    return found


def sources():
    log("reading the product source for the baseline ref and the current checkout")
    out = {}
    out["baseline"] = {"origin": "git " + BASELINE_REF, "text": git("%s:%s" % (BASELINE_REF, SOURCE_REL))}
    new = (REPO / SOURCE_REL).read_text()
    out["current"] = {"origin": "worktree " + digest(new.encode())[:12], "text": new}
    for name, info in out.items():
        info["sha256"] = digest(info["text"].encode())
        # Fingerprint only, never a body for the compiler: split on the signature
        # text so a nested brace in the body cannot confuse anything.
        info["method_fromRaw_sha256"] = digest(
            info["text"].split("static func thumbnailData(fromRaw", 1)[1].split("\n    }")[0].encode())
        info["lines"] = len(info["text"].splitlines())
        log("%-9s %s lines=%d sha=%s" % (name, info["origin"], info["lines"], info["sha256"][:12]))
    return out


def compile_all(out, loaded):
    """Compile the whole product file, unmodified, plus each fixture."""
    built = {}
    for variant, info in loaded.items():
        build = out / "build" / variant
        for name, body in (("measure", RUNNER), ("validate", VALIDATOR), ("generate", GENERATOR)):
            (build / name).mkdir(parents=True, exist_ok=True)
            (build / name / "main.swift").write_text(body)
        product = build / Path(SOURCE_REL).name
        product.write_text(info["text"])
        (out / "bin").mkdir(parents=True, exist_ok=True)
        for name in ("measure", "generate", "validate"):
            binary = out / "bin" / ("%s_%s" % (name, variant))
            argv = ["swiftc"] + FLAGS + [
                str(build / name / "main.swift"), "-o", str(binary)]
            if name == "measure":
                argv.insert(len(FLAGS) + 1, str(product))
            result = run(argv, TIMEOUTS["compile"], "compile %s/%s" % (variant, name))
            if result["rc"]:
                return None, "%s/%s did not compile:\n%s" % (variant, name, result["err"][-2000:])
            built.setdefault(variant, {})[name] = str(binary)
        built[variant].update(flags=FLAGS, product_file_sha256=info["sha256"],
                              fixture_sha256=digest(RUNNER.encode()))
    built["proposal"] = built["current"]
    return built, None


def write_report(path, payload):
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def prepare(out, loaded):
    report = {"artifact": ARTIFACT, "prepared_at": datetime.now(timezone.utc).isoformat(),
              "flags": FLAGS, "bound_read_from_source": BOUND, "baseline_ref": BASELINE_REF,
              "sources": {k: {a: b for a, b in v.items() if a != "text"}
                          for k, v in loaded.items()},
              "cases": [c["name"] for c in CASES], "status": "prepared-not-compiled"}
    write_report(out / "prepare.json", report)
    built, error = compile_all(out, loaded)
    if built:
        report["binaries"], report["status"] = built, "compiled"
        log("all three variants compiled")
    else:
        log("compile unavailable here: %s" % error.splitlines()[0][:110])
        report["compile_error"] = error
    write_report(out / "prepare.json", report)
    return report


def run_full(out, loaded):
    built, error = compile_all(out, loaded)
    if built is None:
        return error
    inputs = out / "inputs"
    inputs.mkdir(parents=True, exist_ok=True)
    generated = run([built["baseline"]["generate"], str(inputs)], TIMEOUTS["generate"], "generate inputs")
    if generated["rc"]:
        return "input generation failed: " + generated["err"]

    samples, failures = [], []
    order = ["baseline", "current", "proposal"]
    for round_number in (1, 2, 3):
        variants = order if round_number % 2 else list(reversed(order))
        log("round %d, variant order %s" % (round_number, " > ".join(variants)))
        for variant in variants:
            binary = built[variant]["measure"]
            for case in CASES:
                tag = "%s-r%d-%s" % (variant, round_number, case["name"])
                png = out / "png" / (tag + ".png")
                png.parent.mkdir(parents=True, exist_ok=True)
                measured = run([binary, str(inputs / case["file"]), str(png),
                                "proposal" if variant == "proposal" else "product",
                                str(BOUND), case["name"]], TIMEOUTS["measure"], "measure " + tag)
                if measured["rc"]:
                    failures.append("%s: process rc=%s %s" % (tag, measured["rc"], measured["err"][-200:]))
                    continue
                sample = last_json(measured["out"]) or {}
                sample.update(variant=variant, case=case["name"], round=round_number)
                if case["dims"] is None:
                    if not sample.get("returned_nil"):
                        failures.append("%s: invalid input returned data, it must return nil" % tag)
                    samples.append(sample)
                    continue
                checked = run([built[variant]["validate"], str(png)],
                              TIMEOUTS["validate"], "validate " + tag)
                report = last_json(checked["out"])
                failures.extend("%s: %s" % (tag, note) for note in
                                gates(case, report, strict=(variant == "proposal")))
                sample["pixels"] = report
                samples.append(sample)

    def series(variant, case, key):
        values = [s[key] for s in samples if s.get("variant") == variant
                  and s.get("case") == case and isinstance(s.get(key), (int, float))
                  and s[key] > 0]
        return median(values)

    table = {}
    for case in CASES:
        row = {}
        for variant in order:
            measured = {k: series(variant, case["name"], k) for k in
                        ("cold_latency_ms", "cpu_ns", "ru_maxrss_bytes_after",
                         "footprint_bytes_after")}
            measured["cpu_ms"] = measured["cpu_ns"] / 1e6 if measured["cpu_ns"] else None
            del measured["cpu_ns"]
            row[variant] = measured
        table[case["name"]] = row
    summary = {
        "artifact": ARTIFACT, "flags": FLAGS, "rounds": 3, "variants": order,
        "order_alternates": True, "fresh_process_per_run": True,
        "units": {"cold_latency_ms": "milliseconds", "cpu_ms": "milliseconds",
                  "ru_maxrss_bytes_after": "bytes", "footprint_bytes_after": "bytes"},
        "series": table, "gate_failures": failures,
        "status": "FAIL" if failures else "PASS",
        "note": "Speed is reported, never thresholded. ru_maxrss and phys_footprint are "
                "whole-process values for one decode, not the decode alone.",
    }
    write_report(out / "result.json", summary)
    return summary


def main():
    parser = argparse.ArgumentParser(
        description="Probe ClipboardMonitor.thumbnailData cold latency, memory, correctness.",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    parser.add_argument("--out", default="/tmp/flux-clipboard-images-compact",
                        help="output directory (default: %(default)s)")
    parser.add_argument("--prepare-only", action="store_true",
                        help="record source identity and inputs, then stop (works on Linux)")
    options = parser.parse_args()
    if sys.platform != "darwin" and not options.prepare_only:
        parser.error("requires macOS; --prepare-only records source inputs on Linux")
    out = Path(options.out)
    out.mkdir(parents=True, exist_ok=True)
    loaded = sources()
    if options.prepare_only:
        print(json.dumps(prepare(out, loaded), indent=2, sort_keys=True))
        return 0
    summary = run_full(out, loaded)
    if isinstance(summary, str):
        print(summary)
        return 1
    print(json.dumps(summary, indent=2, sort_keys=True))
    log("status %s, %d gate failures" % (summary["status"], len(summary["gate_failures"])))
    for note in summary["gate_failures"]:
        log("FAIL " + note)
    return 0 if summary["status"] == "PASS" else 1


if __name__ == "__main__":
    signal.signal(signal.SIGINT, lambda *_: sys.exit(130))
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    sys.exit(main())