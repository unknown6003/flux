import SwiftUI
import AppKit
import Foundation

/// Small, self-contained view/helper types used only by
/// `NowPlayingWidget`'s expanded panel — split out of that file purely to
/// keep it from growing unwieldy. Nothing here talks to `NowPlayingService`
/// directly; each type takes plain values and callbacks, so it's reusable
/// and (for `ArtworkPalette`'s pure core) directly testable without a live
/// service or a real image.

// MARK: - Marquee text

/// A single line of text that scrolls horizontally when it doesn't fit its
/// available width, and renders as a perfectly ordinary static `Text`
/// otherwise. Measures its own intrinsic width against the width SwiftUI
/// actually gives it (via a background `GeometryReader`, the standard
/// technique for this) rather than trying to predict wrapping from string
/// length/font metrics.
///
/// `height` is required (rather than let the view self-size) because the
/// inner `GeometryReader` used for width measurement is, by itself,
/// greedy in *both* dimensions — without an explicit height it would expand
/// to fill any flexible vertical space offered by a parent `VStack`, which
/// is never what's wanted for a single text line.
struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            MarqueeContent(text: text, font: font, color: color, containerWidth: proxy.size.width)
        }
        .frame(height: height)
    }

    /// The scroll distance a marquee needs once its text overflows the
    /// available width — `0` whenever it fits. Split out of `MarqueeContent.
    /// overflow` as a plain, non-private static function purely so
    /// `--selftest` can verify the fits-vs-overflows threshold directly,
    /// without a live view/GeometryReader.
    static func overflowWidth(textWidth: CGFloat, containerWidth: CGFloat) -> CGFloat {
        max(0, textWidth - containerWidth)
    }
}

/// The actual scrolling/measuring machinery, split out from `MarqueeText` so
/// it can be handed a concrete `containerWidth` (a plain `CGFloat`, not a
/// `GeometryProxy`) instead of threading the proxy through every helper.
private struct MarqueeContent: View {
    let text: String
    let font: Font
    let color: Color
    let containerWidth: CGFloat

    /// Pause at each end of the loop before scrolling again.
    private static let pauseDuration: Double = 2.0
    /// Scroll speed — the full loop's duration is `overflow / pointsPerSecond`.
    private static let pointsPerSecond: Double = 30.0

    @State private var textWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var loopTask: Task<Void, Never>?

    private var overflow: CGFloat { MarqueeText.overflowWidth(textWidth: textWidth, containerWidth: containerWidth) }

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .background(widthReader)
            .offset(x: -offset)
            .frame(width: containerWidth, alignment: .leading)
            .clipped()
            .mask(fadeMask)
            .onAppear { restartLoop() }
            .onChange(of: text) { _, _ in restartLoop() }
            .onChange(of: containerWidth) { _, _ in restartLoop() }
            .onChange(of: textWidth) { _, _ in restartLoop() }
            .onDisappear { loopTask?.cancel() }
    }

    private var widthReader: some View {
        GeometryReader { textGeo in
            Color.clear
                .onAppear { textWidth = textGeo.size.width }
                .onChange(of: textGeo.size.width) { _, newWidth in textWidth = newWidth }
        }
    }

    /// Fades both edges only while actually scrolling — a static line that
    /// fits has no reason to look soft at the edges.
    private var fadeMask: some View {
        LinearGradient(
            stops: overflow > 0
                ? [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.04),
                    .init(color: .black, location: 0.92),
                    .init(color: .clear, location: 1),
                ]
                : [.init(color: .black, location: 0), .init(color: .black, location: 1)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    /// Cancels any in-flight loop and, only if the text actually overflows
    /// its available width, starts a fresh pause → scroll-forward → pause →
    /// scroll-back cycle. Re-entrant-safe: called from `onAppear` and every
    /// `onChange` above, and always tears down the previous task first, so a
    /// rapid string of track changes never leaves more than one loop alive.
    private func restartLoop() {
        loopTask?.cancel()
        offset = 0
        let distance = overflow
        guard distance > 0 else { return }
        let scrollDuration = Double(distance) / Self.pointsPerSecond
        loopTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pauseDuration))
                guard !Task.isCancelled else { return }
                withAnimation(.linear(duration: scrollDuration)) { offset = distance }
                try? await Task.sleep(for: .seconds(scrollDuration + Self.pauseDuration))
                guard !Task.isCancelled else { return }
                withAnimation(.linear(duration: scrollDuration)) { offset = 0 }
                try? await Task.sleep(for: .seconds(scrollDuration))
                guard !Task.isCancelled else { return }
            }
        }
    }
}

// MARK: - Flipping artwork

/// The 56×56pt album-art tile, with a 3D Y-axis flip whenever `flipKey`
/// changes (but not on first appearance). Keyed by an opaque `AnyHashable`
/// rather than the image itself — the caller is expected to derive a key
/// from track identity (title/artist/album/source, plus whether artwork is
/// present) so a genuinely new track always flips, while unrelated
/// re-renders (a playback-clock tick, a play/pause toggle) never do.
///
/// The flip is two chained 0.175s `easeInOut` halves (0.35s total): rotate
/// 0°→90° (content still showing, edge-on and invisible), swap to the new
/// image at -90° with no animation, then rotate -90°→0°. Driven by a single
/// cancellable `Task` rather than a canned SwiftUI transition so a second
/// track change arriving mid-flip cleanly cancels and restarts rather than
/// fighting the first animation.
struct FlippingArtwork: View {
    let image: NSImage?
    let flipKey: AnyHashable

    private static let side: CGFloat = 56
    private static let cornerRadius: CGFloat = 13
    private static let halfDuration: Double = 0.175

    @State private var displayedImage: NSImage?
    @State private var displayedKey: AnyHashable?
    @State private var rotation: Double = 0
    @State private var flipTask: Task<Void, Never>?

    init(image: NSImage?, flipKey: AnyHashable) {
        self.image = image
        self.flipKey = flipKey
        _displayedImage = State(initialValue: image)
        _displayedKey = State(initialValue: flipKey)
    }

    var body: some View {
        artworkTile
            .rotation3DEffect(.degrees(rotation), axis: (x: 0, y: 1, z: 0))
            .onChange(of: flipKey) { _, newKey in
                guard Optional(newKey) != displayedKey else { return }
                runFlip(to: image, key: newKey)
            }
            .onDisappear { flipTask?.cancel() }
    }

    @ViewBuilder
    private var artworkTile: some View {
        Group {
            if let displayedImage {
                Image(nsImage: displayedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.white.opacity(0.3))
                    )
            }
        }
        .frame(width: Self.side, height: Self.side)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        // A slight dim over the artwork itself — not the whole tile — so it
        // reads as "photograph under glass" rather than a dark border.
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.06))
        )
        .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
    }

    private func runFlip(to newImage: NSImage?, key: AnyHashable) {
        flipTask?.cancel()
        flipTask = Task { @MainActor in
            withAnimation(.easeInOut(duration: Self.halfDuration)) {
                rotation = 90
            }
            try? await Task.sleep(for: .seconds(Self.halfDuration))
            guard !Task.isCancelled else { return }
            // Swap content at the edge-on 90° point, then jump to -90° with
            // no ambient animation (no `.animation(_:value:)` is attached to
            // this view, so a bare assignment outside `withAnimation` never
            // animates) before rotating back up to 0 — this is what makes
            // the swap itself invisible instead of a visible content pop.
            displayedImage = newImage
            displayedKey = key
            rotation = -90
            withAnimation(.easeInOut(duration: Self.halfDuration)) {
                rotation = 0
            }
        }
    }
}

// MARK: - Waveform visualizer

/// A 6-bar capsule waveform, top-aligned in its row. Bars only animate while
/// `isPlaying` — reusing the same "independent sine phase per bar" trick as
/// the compact equalizer bars, just with more bars and gentler per-bar
/// frequency spread — and freeze at low, dimmed heights otherwise, matching
/// the compact strip's own animated/static split.
struct WaveformVisualizer: View {
    let isPlaying: Bool
    let gradientColors: (top: Color, bottom: Color)

    static let barCount = 6
    static let barWidth: CGFloat = 2.5
    static let barSpacing: CGFloat = 2.5
    static let maxHeight: CGFloat = 16

    static var totalWidth: CGFloat {
        CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
    }

    private static let staticHeights: [CGFloat] = [5, 8, 6, 9, 6, 4]

    var body: some View {
        Group {
            if isPlaying {
                TimelineView(.animation) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    bars(heights: (0..<Self.barCount).map { animatedHeight(t: t, index: $0) })
                }
            } else {
                bars(heights: Self.staticHeights).opacity(0.5)
            }
        }
        .frame(width: Self.totalWidth, height: Self.maxHeight, alignment: .bottom)
    }

    private func animatedHeight(t: TimeInterval, index: Int) -> CGFloat {
        let frequency = 2.0 + Double(index) * 0.55
        let phase = Double(index) * 1.3
        let wave = (sin(t * frequency + phase) + 1) / 2
        return 4 + CGFloat(wave) * (Self.maxHeight - 4)
    }

    private func bars(heights: [CGFloat]) -> some View {
        HStack(alignment: .bottom, spacing: Self.barSpacing) {
            ForEach(Array(heights.enumerated()), id: \.offset) { _, height in
                Capsule()
                    .fill(LinearGradient(colors: [gradientColors.top, gradientColors.bottom],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: Self.barWidth, height: height)
            }
        }
    }
}

// MARK: - Scrubber track

/// A hand-drawn, draggable progress capsule: a 4pt track, an accent-colored
/// fill up to the playhead, and a circular knob (6pt at rest, 10pt while
/// dragging) at the playhead. Reports progress purely as `0...1` — converting
/// that to/from a real `TimeInterval` against a track's `duration` is the
/// caller's job, keeping this view media-agnostic.
struct ScrubberTrack: View {
    let progress: Double
    let isDragging: Bool
    let onDragChanged: (Double) -> Void
    let onDragEnded: (Double) -> Void

    private static let trackHeight: CGFloat = 4
    private static let knobDiameter: CGFloat = 6
    private static let knobDiameterDragging: CGFloat = 10

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let clamped = min(max(progress, 0), 1)
            let knobSize = isDragging ? Self.knobDiameterDragging : Self.knobDiameter
            let x = width * CGFloat(clamped)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(height: Self.trackHeight)
                Capsule()
                    .fill(Color(nsColor: .controlAccentColor))
                    .frame(width: x, height: Self.trackHeight)
                Circle()
                    .fill(Color(nsColor: .controlAccentColor))
                    .frame(width: knobSize, height: knobSize)
                    .offset(x: x - knobSize / 2)
            }
            .animation(.easeOut(duration: 0.12), value: isDragging)
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onDragChanged(Double(min(max(value.location.x / width, 0), 1)))
                    }
                    .onEnded { value in
                        onDragEnded(Double(min(max(value.location.x / width, 0), 1)))
                    }
            )
        }
        .frame(height: Self.knobDiameterDragging)
    }
}

// MARK: - Artwork palette

/// Derives the waveform's vertical gradient from the artwork itself: the
/// average color of its top half over the average color of its bottom half.
/// The arithmetic core (`averageColor(ofRGBA:)`) is a pure function over a
/// plain byte buffer — no image decoding, no caching, no `NSImage` — so it's
/// directly exercisable with synthetic pixel data. Everything that actually
/// touches `NSImage`/`CGImage` is a thin, separately-replaceable shell around
/// that core.
enum ArtworkPalette {
    /// Average of the R/G/B channels across an RGBA8888 buffer (`pixels.count`
    /// must be a multiple of 4 — one `UInt8` per channel per pixel, alpha
    /// included but ignored), each returned in `0...1`. `nil` for an empty or
    /// malformed buffer.
    static func averageColor(ofRGBA pixels: [UInt8]) -> (red: Double, green: Double, blue: Double)? {
        guard !pixels.isEmpty, pixels.count % 4 == 0 else { return nil }
        var rSum = 0, gSum = 0, bSum = 0
        var i = 0
        while i < pixels.count {
            rSum += Int(pixels[i])
            gSum += Int(pixels[i + 1])
            bSum += Int(pixels[i + 2])
            i += 4
        }
        let pixelCount = pixels.count / 4
        let denom = Double(pixelCount) * 255
        return (Double(rSum) / denom, Double(gSum) / denom, Double(bSum) / denom)
    }

    /// A flat monochrome pair used whenever there's no artwork to derive a
    /// gradient from (or extraction fails) — matches the waveform's
    /// no-artwork monochrome look.
    static let monochromeFallback = Color.white.opacity(0.85)

    /// Small (≤6-entry) memo keyed by artwork identity, not content — the
    /// artwork `NSImage` this app hands around is already a fresh, immutable
    /// object per distinct image (see `NowPlayingService.updateArtwork`), so
    /// identity is a cheap, correct-enough cache key. Reset wholesale rather
    /// than LRU-evicted, since this is only ever a handful of recently-seen
    /// tracks, not a real cache workload.
    private static let cacheCapacity = 6
    private static var cache: [ObjectIdentifier: (top: Color, bottom: Color)] = [:]

    /// The waveform's two gradient stops for a given artwork image — the
    /// average color of its top half, and of its bottom half. `nil` artwork
    /// (nothing playing, or artwork not yet loaded) and any extraction
    /// failure both fall back to `monochromeFallback` for both stops.
    static func waveformGradientColors(for image: NSImage?) -> (top: Color, bottom: Color) {
        let fallback = (monochromeFallback, monochromeFallback)
        guard let image else { return fallback }
        let key = ObjectIdentifier(image)
        if let cached = cache[key] { return cached }

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cgImage.width > 0, cgImage.height > 0 else {
            return fallback
        }

        let result = topBottomColors(of: cgImage) ?? fallback
        if cache.count >= cacheCapacity { cache.removeAll(keepingCapacity: true) }
        cache[key] = result
        return result
    }

    /// Splits `cgImage` into top/bottom halves — cropped in the image's own
    /// pixel coordinate space (top-left origin, per `CGImage.cropping(to:)`'s
    /// documented convention, distinct from `CGContext`'s bottom-left-origin
    /// drawing space used below) — and averages each half separately.
    private static func topBottomColors(of cgImage: CGImage) -> (top: Color, bottom: Color)? {
        let width = cgImage.width
        let height = cgImage.height
        guard height > 1 else {
            guard let only = sampleColor(of: cgImage) else { return nil }
            return (only, only)
        }
        let topHeight = height / 2
        let topRect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(topHeight))
        let bottomRect = CGRect(x: 0, y: CGFloat(topHeight), width: CGFloat(width), height: CGFloat(height - topHeight))
        guard let topImage = cgImage.cropping(to: topRect),
              let bottomImage = cgImage.cropping(to: bottomRect) else { return nil }
        let topColor = sampleColor(of: topImage) ?? monochromeFallback
        let bottomColor = sampleColor(of: bottomImage) ?? monochromeFallback
        return (topColor, bottomColor)
    }

    /// Downsamples `cgImage` into a tiny (4×4) RGBA bitmap and averages it —
    /// "tiny" per the design spec, since this only ever backs a 2-stop
    /// gradient nobody scrutinizes pixel-by-pixel.
    private static func sampleColor(of cgImage: CGImage) -> Color? {
        let side = 4
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)))
        guard let average = averageColor(ofRGBA: pixels) else { return nil }
        return Color(red: average.red, green: average.green, blue: average.blue)
    }
}
