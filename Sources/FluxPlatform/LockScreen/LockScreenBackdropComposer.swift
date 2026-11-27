import AppKit
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Vision

/// Composed full-screen lock-screen imagery: the wallpaper backdrop (with
/// optional blurred edges) and an optional Vision foreground cutout for the depth effect.
public struct LockScreenBackdropBundle: @unchecked Sendable {
    public let sourceKey: String
    public let backdrop: CGImage
    public let foregroundCutout: CGImage?

    public init(sourceKey: String, backdrop: CGImage, foregroundCutout: CGImage?) {
        self.sourceKey = sourceKey
        self.backdrop = backdrop
        self.foregroundCutout = foregroundCutout
    }
}

/// Composes lock-screen wallpapers (optionally with mirrored/feathered edge blur)
/// and Vision foreground-instance depth cutouts off the main actor.
public enum LockScreenBackdropComposer {
    /// Maximum rendered canvas width in pixels. Crisp on Retina while fast on GPU.
    public static let maximumCanvasWidth = 2560
    /// Minimum and maximum clock-band occlusion for the depth effect so the time
    /// always remains legible while allowing subjects to step cleanly in front.
    public static let minimumClockOverlap: Double = 0.025
    public static let maximumClockOverlap: Double = 0.62

    /// Normalized clock band (top-left origin) where depth overlap is evaluated.
    public static let clockBandNormalized = CGRect(x: 0.30, y: 0.12, width: 0.40, height: 0.20)

    private struct SendableCIContext: @unchecked Sendable {
        let value = CIContext(options: [
            .cacheIntermediates: false,
            .useSoftwareRenderer: false,
        ])
    }
    private static let sharedContextBox = SendableCIContext()
    private static var sharedContext: CIContext { sharedContextBox.value }

    /// Decodes raw image bytes up to `maxPixels` on the long edge without caching.
    public static func decodeImage(_ data: Data, maxPixels: Int = 2560) -> CGImage? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return decodeFromSource(source, maxPixels: maxPixels)
    }

    /// Reads a static image file safely off the main actor. Returns `nil` for videos or unreadable files.
    public static func decodeImage(at url: URL, maxPixels: Int = 2560) -> CGImage? {
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return decodeFromSource(source, maxPixels: maxPixels)
    }

    private static func decodeFromSource(_ source: CGImageSource, maxPixels: Int) -> CGImage? {
        guard CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary),
              image.width > 16, image.height > 16 else { return nil }
        return image
    }

    /// Returns the user's static desktop wallpaper URL for the given screen, or nil.
    @MainActor
    public static func desktopWallpaperURL(for screen: NSScreen) -> URL? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen), url.isFileURL else { return nil }
        let ext = url.pathExtension.lowercased()
        let unsupported: Set<String> = ["mov", "mp4", "m4v", "qt"]
        guard !unsupported.contains(ext) else { return nil }
        return url
    }

    /// Resolves a bundled Flux bonus wallpaper inside `Contents/Resources/Wallpapers/`.
    public static func bundledWallpaperURL(named resourceName: String, bundle: Bundle = .main) -> URL? {
        guard let root = bundle.resourceURL?.appendingPathComponent("Wallpapers", isDirectory: true) else { return nil }
        for ext in ["jpg", "jpeg", "png", "heic"] {
            let candidate = root.appendingPathComponent("\(resourceName).\(ext)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Extracts the exact pixel-aligned crop of `backdrop` directly behind `cardFrame`
    /// in screen coordinates so the music player's `.glassEffect(.clear)` can refract
    /// real wallpaper pixels inside its own SwiftUI render tree.
    public static func cropForCard(backdrop: CGImage, screenFrame: CGRect, cardFrame: CGRect) -> CGImage? {
        guard screenFrame.width > 0, screenFrame.height > 0,
              cardFrame.width > 0, cardFrame.height > 0 else { return nil }
        let imgW = CGFloat(backdrop.width)
        let imgH = CGFloat(backdrop.height)
        // AppKit screen coordinates have origin at bottom-left; CGImage.cropping uses top-left origin.
        let normX = (cardFrame.minX - screenFrame.minX) / screenFrame.width
        let normW = cardFrame.width / screenFrame.width
        let normTopY = (screenFrame.maxY - cardFrame.maxY) / screenFrame.height
        let normH = cardFrame.height / screenFrame.height

        let cropRect = CGRect(
            x: max(0, (normX * imgW).rounded(.down)),
            y: max(0, (normTopY * imgH).rounded(.down)),
            width: min(imgW, (normW * imgW).rounded(.up)),
            height: min(imgH, (normH * imgH).rounded(.up))
        ).intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))

        guard cropRect.width >= 2, cropRect.height >= 2 else { return nil }
        return backdrop.cropping(to: cropRect)
    }

    /// Composes the full-screen wallpaper backdrop (with optional mirrored/feathered
    /// edge blur) and an optional Vision foreground cutout aligned to the exact same canvas.
    /// Set `matchSystemFill` to true for macOS's System Wallpaper so the central canvas
    /// matches macOS's native aspect-fill crop pixel-for-pixel when the bottom login bar reveals.
    public static func compose(sourceKey: String,
                               image: CGImage,
                               targetAspectSize: CGSize,
                               blurEdges: Bool = true,
                               matchSystemFill: Bool = false,
                               includeDepthEffect: Bool) -> LockScreenBackdropBundle? {
        let canvasSize = resolvedCanvasSize(for: targetAspectSize)
        guard canvasSize.width >= 64, canvasSize.height >= 64 else { return nil }

        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        let sourceCI = CIImage(cgImage: image)
        let srcW = CGFloat(image.width)
        let srcH = CGFloat(image.height)
        guard srcW > 0, srcH > 0 else { return nil }

        let rawScale: CGFloat
        if blurEdges && !matchSystemFill {
            // Height-fit so custom portrait/square photos get mirrored blurred flanks,
            // while widescreen photos fill height and get soft blurred left/right edges.
            rawScale = (canvasSize.height + 2) / srcH
        } else {
            // Exact aspectFill matching macOS's native lock-screen wallpaper framing.
            rawScale = max((canvasSize.width + 2) / srcW, (canvasSize.height + 2) / srcH)
        }

        let fittedW = max(2, floor(srcW * rawScale) - 2)
        let fittedH = max(2, floor(srcH * rawScale) - 2)
        let centerOriginX = floor((canvasSize.width - fittedW) / 2)
        let centerOriginY = floor((canvasSize.height - fittedH) / 2)
        let centerRect = CGRect(x: centerOriginX, y: centerOriginY, width: fittedW, height: fittedH)

        var scaledSharp = sourceCI
            .clampedToExtent()
            .applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: rawScale,
                kCIInputAspectRatioKey: 1.0,
            ])
        if rawScale > 1.25 {
            scaledSharp = scaledSharp.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: min(0.45, (rawScale - 1.0) * 0.22),
            ])
        }
        let centeredSharp = scaledSharp
            .cropped(to: CGRect(x: 1, y: 1, width: fittedW, height: fittedH))
            .transformed(by: CGAffineTransform(translationX: centerOriginX - 1, y: centerOriginY - 1))

        var composed: CIImage
        let sharpLuminanceMask: CIImage?

        if blurEdges {
            let extended = buildMirroredExtension(centered: centeredSharp, centerRect: centerRect, canvasRect: canvasRect)
            let blurRadius = max(20.0, canvasSize.width * 0.017)
            let blurredFlanks = extended
                .clampedToExtent()
                .applyingGaussianBlur(sigma: blurRadius)
                .cropped(to: canvasRect)

            let sharpAlphaMask = makeHorizontalFeatherMask(canvasSize: canvasSize, centerRect: centerRect, opaqueAlpha: false)
            sharpLuminanceMask = makeHorizontalFeatherMask(canvasSize: canvasSize, centerRect: centerRect, opaqueAlpha: true)

            guard let blendFilter = CIFilter(name: "CIBlendWithAlphaMask") else { return nil }
            blendFilter.setValue(centeredSharp.cropped(to: canvasRect), forKey: kCIInputImageKey)
            blendFilter.setValue(blurredFlanks, forKey: kCIInputBackgroundImageKey)
            blendFilter.setValue(sharpAlphaMask, forKey: kCIInputMaskImageKey)
            guard let blended = blendFilter.outputImage?.cropped(to: canvasRect) else { return nil }
            composed = blended
        } else {
            composed = centeredSharp.cropped(to: canvasRect)
            sharpLuminanceMask = nil
        }

        // Subtle outer vignette so date/clock & bottom prompt stay crisp.
        if let vignette = makeSubtleVignette(canvasSize: canvasSize) {
            composed = vignette.composited(over: composed).cropped(to: canvasRect)
        }

        guard let backdropCG = sharedContext.createCGImage(composed, from: canvasRect) else { return nil }

        var foregroundCG: CGImage?
        if includeDepthEffect {
            foregroundCG = extractDepthCutout(from: image,
                                              centeredSharp: centeredSharp,
                                              sharpLuminanceMask: sharpLuminanceMask,
                                              centerRect: centerRect,
                                              canvasRect: canvasRect)
        }

        return LockScreenBackdropBundle(sourceKey: sourceKey, backdrop: backdropCG, foregroundCutout: foregroundCG)
    }

    // MARK: - Pure geometry & overlap logic

    public static func resolvedCanvasSize(for screenSize: CGSize) -> CGSize {
        let w = max(screenSize.width, 1)
        let h = max(screenSize.height, 1)
        let targetW = min(CGFloat(maximumCanvasWidth), max(1280, w * 2))
        let targetH = (targetW * (h / w)).rounded()
        return CGSize(width: targetW.rounded(), height: max(720, targetH))
    }

    public static func acceptsClockOverlap(_ coverage: Double) -> Bool {
        coverage >= minimumClockOverlap && coverage <= maximumClockOverlap
    }

    // MARK: - Mirrored edge extension & feathering

    private static func buildMirroredExtension(centered: CIImage, centerRect: CGRect, canvasRect: CGRect) -> CIImage {
        var result = centered
        guard centerRect.width < canvasRect.width + 2 else {
            return centered.cropped(to: canvasRect)
        }

        var step = 1
        var leftEdge = centerRect.minX
        var rightEdge = centerRect.maxX
        let tileW = max(centerRect.width, 1)

        while (leftEdge > canvasRect.minX || rightEdge < canvasRect.maxX) && step <= 4 {
            let isMirrored = (step % 2 == 1)

            if leftEdge > canvasRect.minX {
                let targetMinX = leftEdge - tileW
                let tile: CIImage
                if isMirrored {
                    tile = centered
                        .transformed(by: CGAffineTransform(translationX: -centerRect.minX, y: 0))
                        .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                        .transformed(by: CGAffineTransform(translationX: targetMinX + tileW, y: 0))
                } else {
                    tile = centered.transformed(by: CGAffineTransform(translationX: targetMinX - centerRect.minX, y: 0))
                }
                result = result.composited(over: tile)
                leftEdge = targetMinX
            }

            if rightEdge < canvasRect.maxX {
                let targetMinX = rightEdge
                let tile: CIImage
                if isMirrored {
                    tile = centered
                        .transformed(by: CGAffineTransform(translationX: -centerRect.minX, y: 0))
                        .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                        .transformed(by: CGAffineTransform(translationX: targetMinX + tileW, y: 0))
                } else {
                    tile = centered.transformed(by: CGAffineTransform(translationX: targetMinX - centerRect.minX, y: 0))
                }
                result = result.composited(over: tile)
                rightEdge = targetMinX + tileW
            }

            step += 1
        }
        return result.cropped(to: canvasRect)
    }

    private static func makeHorizontalFeatherMask(canvasSize: CGSize, centerRect: CGRect, opaqueAlpha: Bool) -> CIImage {
        let width = Int(canvasSize.width)
        var pixels = [UInt8](repeating: 0, count: width * 4)

        let visibleMinX = max(0, centerRect.minX)
        let visibleMaxX = min(canvasSize.width, centerRect.maxX)
        let visibleWidth = max(1, visibleMaxX - visibleMinX)
        // Soft horizontal edge feather melts the left and right edges into blurred flanks.
        let feather = min(visibleWidth * 0.14, canvasSize.width * 0.12)
        let innerMinX = visibleMinX + feather
        let innerMaxX = visibleMaxX - feather

        for x in 0..<width {
            let fx = CGFloat(x) + 0.5
            let alpha: CGFloat
            if fx <= visibleMinX || fx >= visibleMaxX {
                alpha = 0
            } else if fx < innerMinX {
                let t = (fx - visibleMinX) / max(feather, 1)
                alpha = 0.5 - 0.5 * cos(.pi * t)
            } else if fx > innerMaxX {
                let t = (visibleMaxX - fx) / max(feather, 1)
                alpha = 0.5 - 0.5 * cos(.pi * t)
            } else {
                alpha = 1
            }
            let byte = UInt8(max(0, min(255, (alpha * 255).rounded())))
            let offset = x * 4
            pixels[offset] = byte
            pixels[offset + 1] = byte
            pixels[offset + 2] = byte
            pixels[offset + 3] = opaqueAlpha ? 255 : byte
        }

        let rowImage = CIImage(bitmapData: Data(pixels),
                               bytesPerRow: width * 4,
                               size: CGSize(width: width, height: 1),
                               format: .RGBA8,
                               colorSpace: CGColorSpaceCreateDeviceRGB())
        return rowImage
            .clampedToExtent()
            .cropped(to: CGRect(origin: .zero, size: canvasSize))
    }

    private static func makeSubtleVignette(canvasSize: CGSize) -> CIImage? {
        let width = 64
        let height = 64
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let ny = (Double(y) + 0.5) / Double(height)
            let topEdge = max(0, (ny - 0.86) / 0.14)
            let bottomEdge = max(0, (0.14 - ny) / 0.14)
            let alpha = min(0.14, topEdge * topEdge * 0.06 + bottomEdge * bottomEdge * 0.10)
            let byte = UInt8((alpha * 255).rounded())

            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = 0
                pixels[offset + 1] = 0
                pixels[offset + 2] = 0
                pixels[offset + 3] = byte
            }
        }
        let small = CIImage(bitmapData: Data(pixels),
                            bytesPerRow: width * 4,
                            size: CGSize(width: width, height: height),
                            format: .RGBA8,
                            colorSpace: CGColorSpaceCreateDeviceRGB())
        return small
            .clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: canvasSize.width / CGFloat(width),
                                               y: canvasSize.height / CGFloat(height)))
            .cropped(to: CGRect(origin: .zero, size: canvasSize))
    }

    // MARK: - Vision depth segmentation

    private static func extractDepthCutout(from sourceImage: CGImage,
                                           centeredSharp: CIImage,
                                           sharpLuminanceMask: CIImage?,
                                           centerRect: CGRect,
                                           canvasRect: CGRect) -> CGImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: sourceImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { return nil }
        guard let maskBuffer = try? observation.generateScaledMaskForImage(forInstances: observation.allInstances,
                                                                           from: handler) else { return nil }

        let maskWidth = CGFloat(CVPixelBufferGetWidth(maskBuffer))
        let maskHeight = CGFloat(CVPixelBufferGetHeight(maskBuffer))
        guard maskWidth > 0, maskHeight > 0 else { return nil }

        let scaleX = centerRect.width / maskWidth
        let scaleY = centerRect.height / maskHeight
        let rawCanvasMask = CIImage(cvPixelBuffer: maskBuffer)
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(translationX: centerRect.minX, y: centerRect.minY))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 0.75)
            .cropped(to: canvasRect)

        let combinedMask: CIImage
        if let sharpLuminanceMask {
            combinedMask = rawCanvasMask
                .applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: sharpLuminanceMask])
                .cropped(to: canvasRect)
        } else {
            combinedMask = rawCanvasMask
        }

        let coverage = clockBandCoverage(mask: combinedMask, canvasRect: canvasRect)
        guard acceptsClockOverlap(coverage) else { return nil }

        guard let blend = CIFilter(name: "CIBlendWithMask") else { return nil }
        blend.setValue(centeredSharp.cropped(to: canvasRect), forKey: kCIInputImageKey)
        blend.setValue(CIImage(color: .clear).cropped(to: canvasRect), forKey: kCIInputBackgroundImageKey)
        blend.setValue(combinedMask, forKey: kCIInputMaskImageKey)
        guard let cutoutCI = blend.outputImage?.cropped(to: canvasRect) else { return nil }

        return sharedContext.createCGImage(cutoutCI, from: canvasRect)
    }

    private static func clockBandCoverage(mask: CIImage, canvasRect: CGRect) -> Double {
        let norm = clockBandNormalized
        let x = canvasRect.width * norm.minX
        let w = canvasRect.width * norm.width
        let h = canvasRect.height * norm.height
        let y = canvasRect.height * (1.0 - norm.maxY)
        let sampleRect = CGRect(x: x, y: y, width: w, height: h).intersection(canvasRect)
        guard sampleRect.width > 4, sampleRect.height > 4 else { return 0 }

        guard let avg = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: mask,
            kCIInputExtentKey: CIVector(cgRect: sampleRect),
        ])?.outputImage else { return 0 }

        var rgba = [UInt8](repeating: 0, count: 4)
        sharedContext.render(avg,
                             toBitmap: &rgba,
                             rowBytes: 4,
                             bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                             format: .RGBA8,
                             colorSpace: CGColorSpaceCreateDeviceRGB())
        return Double(rgba[0]) / 255.0
    }
}
