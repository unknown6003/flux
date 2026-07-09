#!/usr/bin/env swift
import AppKit

// Renders Flux's app icon — an Industrial Amber rounded tile with a matte-black
// chevron — into a .iconset directory ready for `iconutil`. Pure AppKit drawing,
// no external assets. Matches the in-app Flux mark and the amber brand palette.

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"

func makePNG(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(pixels)
    let inset = s * 0.085
    let tile = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = tile.width * 0.225

    let clip = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
    clip.addClip()

    // A restrained, near-flat amber: a faint top sheen settling onto the true
    // brand amber (#FFB000). Just enough depth to read as an app icon, no garish
    // orange fade.
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 1.00, green: 0.780, blue: 0.320, alpha: 1), // #FFC752 sheen
        NSColor(srgbRed: 1.00, green: 0.690, blue: 0.000, alpha: 1)  // #FFB000 brand
    ])!
    gradient.draw(in: tile, angle: -90)

    // Chevron "‹"
    let c = NSBezierPath()
    let w = tile.width
    func p(_ nx: CGFloat, _ ny: CGFloat) -> NSPoint {
        NSPoint(x: tile.minX + nx * w, y: tile.minY + ny * w)
    }
    c.move(to: p(0.62, 0.74))
    c.line(to: p(0.40, 0.50))
    c.line(to: p(0.62, 0.26))
    c.lineWidth = w * 0.085
    c.lineCapStyle = .round
    c.lineJoinStyle = .round
    NSColor(srgbRed: 0.039, green: 0.039, blue: 0.039, alpha: 1).setStroke() // matte black
    c.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
try? fm.removeItem(atPath: outputDir)
try! fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

// name → pixel size for the macOS iconset convention.
let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for (name, px) in variants {
    let data = makePNG(pixels: px)
    let url = URL(fileURLWithPath: "\(outputDir)/\(name).png")
    try! data.write(to: url)
}

FileHandle.standardError.write("Wrote \(variants.count) icon sizes to \(outputDir)\n".data(using: .utf8)!)
