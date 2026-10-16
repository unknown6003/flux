#!/usr/bin/env python3
"""Compare real clipboard thumbnail methods and a fixture-only ImageIO decoder.

Fresh process per decode, three alternating rounds, identical optimized builds.
Memory is whole-process macOS peak RSS and live footprint after the call.
Input generation and pixel validation run in separate, unmeasured processes.
"""
import argparse
import hashlib
import json
from pathlib import Path
import signal
import statistics
import sys
from probe_performance import ROOT, run

BASELINE = "6fde90817068d06ecfae8eb6ec85c19e68af997b"
SOURCE = "Sources/Flux/Services/ClipboardMonitor.swift"
STANDARD = {'top_left': 'red', 'top_right': 'green', 'bottom_left': 'blue', 'bottom_right': 'white'}

ROTATED = {'top_left': 'blue', 'top_right': 'red', 'bottom_left': 'white', 'bottom_right': 'green'}

PATCHES = {'red': (255, 0, 0), 'green': (0, 255, 0), 'blue': (0, 0, 255), 'white': (255, 255, 255)}

CASES = [{'name': 'big-jpeg',
  'file': 'big-jpeg.jpg',
  'dims': (64, 48),
  'corners': {'top_left': 'red',
              'top_right': 'green',
              'bottom_left': 'blue',
              'bottom_right': 'white'},
  'alpha': 'opaque-corners',
  'note': '4000x3000 opaque JPEG, four corner patches'},
 {'name': 'big-png',
  'file': 'big-png.png',
  'dims': (64, 48),
  'corners': {'top_left': 'red',
              'top_right': 'green',
              'bottom_left': 'blue',
              'bottom_right': 'white'},
  'alpha': 'transparent-centre',
  'note': '4000x3000 RGBA PNG, clear centre window'},
 {'name': 'big-tiff',
  'file': 'big-tiff.tiff',
  'dims': (64, 48),
  'corners': {'top_left': 'red',
              'top_right': 'green',
              'bottom_left': 'blue',
              'bottom_right': 'white'},
  'alpha': 'report-only',
  'note': '4000x3000 RGBA TIFF, writer alpha varies'},
 {'name': 'tiny-16x8',
  'file': 'tiny-16x8.png',
  'dims': (16, 8),
  'corners': {'top_left': 'red',
              'top_right': 'green',
              'bottom_left': 'blue',
              'bottom_right': 'white'},
  'dims_any': [(16, 8)],
  'alpha': 'opaque-corners',
  'note': 'no-upscale control, a 64 bound must not inflate it'},
 {'name': 'invalid',
  'file': 'invalid.bin',
  'dims': None,
  'corners': None,
  'note': 'PNG magic then garbage, both must return nil'},
 {'name': 'exif-rot90',
  'file': 'exif-rot90.jpg',
  'dims': (48, 64),
  'corners': {'top_left': 'blue',
              'top_right': 'red',
              'bottom_left': 'white',
              'bottom_right': 'green'},
  'dims_any': [(64, 48), (48, 64)],
  'corners_any': [{'top_left': 'red',
                   'top_right': 'green',
                   'bottom_left': 'blue',
                   'bottom_right': 'white'},
                  {'top_left': 'blue',
                   'top_right': 'red',
                   'bottom_left': 'white',
                   'bottom_right': 'green'}],
  'alpha': 'opaque-corners',
  'note': 'orientation 6, the proposal must apply it and swap the corners'}]

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
                    width: CGFloat(winW), height: CGFloat(winH)), (0, 0, 0), 0)
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
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        let bound = max(1, min(Int(maxPixel), max(sourceWidth, sourceHeight)))
        let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: bound,
            kCGImageSourceShouldCacheImmediately: false
        ] as CFDictionary)
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
    // Rows in this decoded bitmap begin at the image top.
    let y = min(height - 1, max(0, Int(Double(height) * fy)))
    let offset = stride * y + x * 4
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


def parsed(output):
    for line in reversed(output.splitlines()):
        if line.startswith("{"):
            return json.loads(line)
    raise RuntimeError("native fixture returned no JSON: " + output[-500:])


def color(rgb):
    distance, name = min((sum((a-b)**2 for a,b in zip(rgb,want)), name) for name,want in PATCHES.items())
    return name if distance <= 90**2 else "unknown"


def check(case, pixels):
    if (pixels["width"], pixels["height"]) != case["dims"]:
        raise RuntimeError(f"{case['name']}: wrong thumbnail dimensions: {pixels}")
    seen = {name: color(rgb) for name,rgb in pixels["corners"].items()}
    if seen != case["corners"]:
        raise RuntimeError(f"{case['name']}: wrong orientation or pixels: {seen}")
    if pixels["min_corner_alpha"] != 255:
        raise RuntimeError(f"{case['name']}: opaque corner lost alpha")
    if case.get("alpha") == "transparent-centre" and pixels["center_alpha"] != 0:
        raise RuntimeError(f"{case['name']}: clear centre lost transparency")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=ROOT/"build/performance/clipboard-images")
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()
    if sys.platform != "darwin" and not args.prepare_only:
        parser.error("requires native macOS; --prepare-only only records source inputs")
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    source = {"baseline": run(["git", "show", BASELINE+":"+SOURCE],15), "current": (ROOT/SOURCE).read_text()}
    report = {"baseline": BASELINE, "candidate": run(["git","rev-parse","HEAD"],10).strip(),
              "source_sha256": {k:hashlib.sha256(v.encode()).hexdigest() for k,v in source.items()},
              "flags": ["-O","-swift-version","5"], "rounds":3, "samples":[], "status":"prepared",
              "boundary":__doc__}
    def save():
        (out/"result.json").write_text(json.dumps(report,indent=2)+"\n")
    binaries = {}
    for name,text in source.items():
        folder = out/name
        folder.mkdir(exist_ok=True)
        (folder/"ClipboardMonitor.swift").write_text(text)
        (folder/"main.swift").write_text(RUNNER)
    save()
    if args.prepare_only:
        return
    try:
        for name in source:
            folder = out/name
            binaries[name] = folder/"measure"
            log = run(["xcrun","swiftc",*report["flags"],str(folder/"ClipboardMonitor.swift"),
                       str(folder/"main.swift"),"-o",str(binaries[name])],60)
            (folder/"build.log").write_text(log)
        for name,text in (("generate",GENERATOR),("validate",VALIDATOR)):
            folder = out/name
            folder.mkdir(exist_ok=True)
            (folder/"main.swift").write_text(text)
            log = run(["xcrun","swiftc",*report["flags"],str(folder/"main.swift"),"-o",str(folder/name)],30)
            (folder/"build.log").write_text(log)
            binaries[name] = folder/name
        inputs = out/"inputs"
        inputs.mkdir(exist_ok=True)
        run([str(binaries["generate"]),str(inputs)],20)
        control = parsed(run([str(binaries["validate"]),str(inputs/"big-png.png")],10))
        if {k:color(v) for k,v in control["corners"].items()} != STANDARD or control["center_alpha"] != 0:
            raise RuntimeError("source pixel control failed; validator cannot establish orientation/transparency")
        report["source_pixel_control"] = control
        for iteration in range(3):
            order = ("baseline","current","proposal") if iteration%2==0 else ("proposal","current","baseline")
            for variant in order:
                for case in CASES:
                    tag = f"{variant}-r{iteration+1}-{case['name']}"
                    png = out/(tag+".png")
                    binary = binaries["current" if variant=="proposal" else variant]
                    measured = parsed(run([str(binary),str(inputs/case["file"]),str(png),
                                           "proposal" if variant=="proposal" else "product","64",case["name"]],10))
                    measured.update(variant=variant,case=case["name"],round=iteration+1)
                    report["samples"].append(measured)
                    if case["dims"] is None:
                        if not measured["returned_nil"]:
                            raise RuntimeError("invalid bytes returned an image")
                    else:
                        measured["pixels"] = parsed(run([str(binaries["validate"]),str(png)],10))
                        check(case,measured["pixels"])
                    save()
            print(f"PASS thumbnail round {iteration+1}",flush=True)
        keys = ("cold_latency_ms","cpu_ns","ru_maxrss_bytes_after","footprint_bytes_after")
        report["series"] = {}
        for case in CASES:
            report["series"][case["name"]] = {}
            for variant in ("baseline","current","proposal"):
                rows = [s for s in report["samples"] if s["case"]==case["name"] and s["variant"]==variant]
                report["series"][case["name"]][variant] = {
                    key:{"median":statistics.median(s[key] for s in rows),
                         "min":min(s[key] for s in rows),"max":max(s[key] for s in rows)} for key in keys}
        report["status"] = "pass"
    except BaseException as error:
        report.update(status="fail",error=str(error))
        raise
    finally:
        save()


if __name__ == "__main__":
    signal.signal(signal.SIGTERM,lambda signum,frame:sys.exit(128+signum))
    try:
        main()
    except (RuntimeError,OSError) as error:
        sys.exit(f"FAIL: {error}")
