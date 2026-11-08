import AppKit
import AVFoundation
import FluxCore
import ImageIO

/// The handle that `FeatureRuntime` keeps. It owns the real feed. Stop
/// stops the feed first, then tells the coordinator, so the widget never
/// shows a stopped feed as live. A stopped lease is never reused.
@MainActor
final class ServiceLease<Feed: FeatureServiceHandle>: FeatureServiceHandle {
    let feed: Feed
    private(set) var active = true
    private var onStop: (() -> Void)?

    init(feed: Feed, onStop: @escaping () -> Void) {
        self.feed = feed
        self.onStop = onStop
    }

    func stop() {
        guard active else { return }
        active = false
        feed.stop()
        let done = onStop
        onStop = nil
        done?()
    }
}

/// A layer-backed view whose layer is the camera preview layer. The capture
/// session renders into it directly. No frame is copied.
@MainActor
final class CameraPreviewView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func makeBackingLayer() -> CALayer { previewLayer }
}

/// One decoded artwork. `CGImage` is immutable, so only this box crosses actors.
struct ArtworkImage: @unchecked Sendable {
    let image: CGImage
}

enum ArtworkThumbnail {
    /// 256 px a side keeps a decoded RGBA image at 256 KiB or less.
    static let maximumPixels = 256

    /// Decodes a thumbnail with ImageIO. Call it off the main actor. It never
    /// decodes the full image and never caches the source.
    static func make(_ data: Data) -> ArtworkImage? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary),
              image.width <= maximumPixels, image.height <= maximumPixels else { return nil }
        return ArtworkImage(image: image)
    }
}
