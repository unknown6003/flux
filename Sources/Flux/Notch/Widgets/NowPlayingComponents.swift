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
    /// The `containerWidth` a loop was last actually (re)started for — guards
    /// `onChange(of: containerWidth)` below against restarting the marquee
    /// for sub-pixel measurement jitter rather than a real resize. M8 audit:
    /// `NotchRootView.expandedContent(for:)` now gives this view's ancestor a
    /// frame FIXED at the state's settled final size specifically so
    /// `containerWidth` stays constant across the whole expand/collapse
    /// spring instead of tracking every interpolated frame — this debounce is
    /// extra insurance on top of that (a `GeometryReader`-driven width can
    /// still wobble by a fraction of a point between layout passes with
    /// nothing actually changing), not the primary fix for the per-frame
    /// relayout hitch.
    @State private var lastRestartWidth: CGFloat?

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
            .onChange(of: containerWidth) { _, newWidth in
                // Sub-0.5pt jitter (or a redelivery of the same, already-
                // committed target width) is measurement noise, not a real
                // resize — ignore it rather than restarting the loop.
                if let lastRestartWidth, abs(newWidth - lastRestartWidth) < 0.5 { return }
                restartLoop()
            }
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
        lastRestartWidth = containerWidth
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
/// The flip is 0°→90° over 0.175s (content still showing, rotating away),
/// an instant jump to -90° (still edge-on/invisible, just the mirror-image
/// angle), then -90°→0° over another 0.175s (0.35s total) — driven by
/// `keyframeAnimator(initialValue:trigger:)` (M8 audit fix) rather than the
/// two-`Task`-sleep chain this used to be. `keyframeAnimator` owns the
/// rotation's timeline itself and, per its documented contract, blends
/// smoothly from whatever the CURRENT interpolated angle is when `trigger`
/// (== `flipKey`) changes again mid-flight — unlike a hand-rolled sleep
/// chain, there's no window where a second track change arriving mid-flip
/// could race the first `Task`'s cancellation and leave `rotation` snapped to
/// a stale value; the animator itself guarantees continuity.
///
/// The image swap at the crossing is driven by the interpolated angle
/// itself, not a side effect scheduled to fire "at the same time": the
/// `content` closure picks `settledImage` (whatever was showing before this
/// flip) while `angle > 0` (still rotating away, front-half) and `image`
/// (this flip's target) once `angle <= 0` (rotating back into place,
/// back-half) — a pure function of the animated value, so it can never drift
/// out of sync with the rotation the way a separately-timed callback could.
/// `settledImage`/`committedKey` still exist as plain `@State`, but only for
/// bookkeeping: a short cancellable `Task` commits them to this flip's target
/// once the full 0.35s has elapsed, purely so the *next* flip's front-half
/// has the right "old" image to show — that `Task` never touches `rotation`,
/// so cancelling/replacing it on a rapid re-trigger carries none of the
/// visual risk the old sleep-driven rotation chain did.
struct FlippingArtwork: View {
    let image: NSImage?
    let flipKey: AnyHashable

    private static let side: CGFloat = 56
    private static let cornerRadius: CGFloat = 13
    private static let halfDuration: Double = 0.175

    /// The keyframe-animated value: just the Y-axis rotation angle, in
    /// degrees. A plain `Double` conforms to `Animatable` already (SwiftUI
    /// extends the standard floating-point types for exactly this), so this
    /// wrapper exists purely to give `KeyframeTrack` a named key path.
    private struct FlipAngle: Equatable {
        var angle: Double = 0
    }

    /// The most recently SETTLED (fully flipped-to, at rest) image/key —
    /// i.e. what a flip's front-half should show as the "old" side. Renamed
    /// from the pre-M8 `displayedImage`/`displayedKey`: those used to be the
    /// single source of truth for what's on screen every frame; now the
    /// `content` closure below picks between this and the live `image`
    /// property directly based on the animated angle, so these two only ever
    /// need to be correct at REST (between flips), not mid-flight.
    @State private var settledImage: NSImage?
    @State private var committedKey: AnyHashable?
    /// Bookkeeping-only — see the type's doc comment above.
    @State private var commitTask: Task<Void, Never>?

    init(image: NSImage?, flipKey: AnyHashable) {
        self.image = image
        self.flipKey = flipKey
        _settledImage = State(initialValue: image)
        _committedKey = State(initialValue: flipKey)
    }

    var body: some View {
        Color.clear
            .frame(width: Self.side, height: Self.side)
            .keyframeAnimator(initialValue: FlipAngle(), trigger: flipKey) { _, value in
                // Ignoring the placeholder `view` argument is deliberate:
                // this flip needs to swap actual CONTENT (which image is
                // shown), not just layer a modifier over fixed content, so
                // the tile is rebuilt fresh from the animated `value` every
                // frame instead.
                artworkTile(showing: value.angle > 0 ? settledImage : image)
                    .rotation3DEffect(.degrees(value.angle), axis: (x: 0, y: 1, z: 0))
            } keyframes: { _ in
                KeyframeTrack(\.angle) {
                    CubicKeyframe(90, duration: Self.halfDuration)
                    LinearKeyframe(-90, duration: 0)
                    CubicKeyframe(0, duration: Self.halfDuration)
                }
            }
            .onChange(of: flipKey) { _, newKey in
                guard Optional(newKey) != committedKey else { return }
                let target = image
                commitTask?.cancel()
                commitTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(Self.halfDuration * 2))
                    guard !Task.isCancelled else { return }
                    settledImage = target
                    committedKey = newKey
                }
            }
            // Bot-review fix (M7, preserved): artwork can arrive
            // asynchronously AFTER track metadata (title/artist/source —
            // whatever `flipKey` is derived from) — e.g. `NowPlayingService`
            // publishes the new track first and its artwork fetch resolves a
            // moment later, under the SAME `flipKey`. `content` above already
            // reads the live `image` property directly once `angle <= 0`
            // (i.e. at rest, no flip in flight), so a late-arriving image for
            // an unchanged `flipKey` shows up immediately with no extra work
            // — this handler's only remaining job is keeping `settledImage`
            // (the "old" side for the NEXT flip) in sync for that same case,
            // which `content` doesn't cover since it isn't mid-flip. Tracked
            // by identity (`ObjectIdentifier`, not `Equatable`/`==`) — same
            // reasoning as `ArtworkPalette.memo`'s own `===` comparison:
            // `NSImage` isn't meaningfully value-comparable here, only "is
            // this the same object" is.
            .onChange(of: image.map(ObjectIdentifier.init)) { _, _ in
                guard Optional(flipKey) == committedKey else { return }
                settledImage = image
            }
            .onDisappear { commitTask?.cancel() }
    }

    @ViewBuilder
    private func artworkTile(showing shownImage: NSImage?) -> some View {
        Group {
            if let shownImage {
                Image(nsImage: shownImage)
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
}

// MARK: - Shared bar-equalizer animation

/// The "independent sine phase per bar" trick behind every animated
/// equalizer-style bar strip in the notch UI — `WaveformVisualizer`'s 6 wide
/// bars here and `AnimatedEqualizerBars`' 3 tiny compact-strip bars in
/// `NowPlayingWidget.swift` were two near-identical copies of this same
/// arithmetic, differing only in their tuning constants (bar count aside).
/// Extracted once so both call sites share one implementation — and a future
/// third animated-bars spot has an obvious function to call rather than a
/// third copy to hand-tune independently.
enum EqualizerAnimation {
    /// - Parameters:
    ///   - time: the animation clock, in seconds (typically a `TimelineView`
    ///     timestamp's `timeIntervalSinceReferenceDate`).
    ///   - index: this bar's position, `0`-based — each bar rides its own
    ///     phase/frequency (via `freqStep`/`phaseStep`) so a row of bars
    ///     never locks into visible unison.
    ///   - base: the bar's minimum height (the sine wave's trough).
    ///   - span: how much taller than `base` the bar gets at the sine wave's
    ///     peak — i.e. `base + span` is the tallest a bar ever renders.
    ///   - freqBase: bar 0's oscillation frequency.
    ///   - freqStep: added per bar index to spread frequencies across the row.
    ///   - phaseStep: added (times `index`) to offset each bar's phase.
    static func barHeight(time: TimeInterval, index: Int, base: CGFloat, span: CGFloat,
                           freqBase: Double, freqStep: Double, phaseStep: Double) -> CGFloat {
        let frequency = freqBase + Double(index) * freqStep
        let phase = Double(index) * phaseStep
        let wave = (sin(time * frequency + phase) + 1) / 2
        return base + CGFloat(wave) * span
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

    /// M8 audit fix: production wants `TimelineView(.animation)` — a
    /// display-link-driven schedule that tracks the real screen refresh rate
    /// (up to 120Hz on ProMotion) rather than a fixed tick, so the bars read
    /// as genuinely smooth motion instead of a visibly steppy 30fps flicker.
    /// That schedule needs a real, on-screen, key window to ever fire, though
    /// — `NotchSnapshot`'s off-screen render harness (see
    /// `SnapshotEnvironment.swift`) parks its window outside any real
    /// `NSScreen`, where a display-link schedule can go dead silent (its
    /// content closure never runs even once), leaving this whole branch blank
    /// in a snapshot rather than showing a representative first frame. The
    /// 30Hz `.periodic` schedule below is kept ONLY for that harness — a
    /// plain timer-driven schedule, not tied to a display link, which the
    /// scrubber's own `TimelineView(.periodic(...))` elsewhere already proves
    /// does fire there — gated on `isSnapshotRender` so the live app never
    /// takes the lower-frame-rate path.
    @Environment(\.isSnapshotRender) private var isSnapshotRender

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
                if isSnapshotRender {
                    TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        bars(heights: (0..<Self.barCount).map { animatedHeight(t: t, index: $0) })
                    }
                } else {
                    TimelineView(.animation) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        bars(heights: (0..<Self.barCount).map { animatedHeight(t: t, index: $0) })
                    }
                }
            } else {
                bars(heights: Self.staticHeights).opacity(0.5)
            }
        }
        .frame(width: Self.totalWidth, height: Self.maxHeight, alignment: .bottom)
    }

    private func animatedHeight(t: TimeInterval, index: Int) -> CGFloat {
        EqualizerAnimation.barHeight(time: t, index: index, base: 4, span: Self.maxHeight - 4,
                                      freqBase: 2.0, freqStep: 0.55, phaseStep: 1.3)
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
            // The knob is centered on the playhead (`x`), which itself used
            // to range over the *full* `proxy.size.width` — so at progress
            // 0 or 1 exactly half the knob (radius `knobSize / 2`) sat
            // outside the track's own bounds, visually clipped/cut off
            // against whatever's beside it. Insetting the playhead's travel
            // range by the largest the knob ever gets (dragging size) keeps
            // it fully on-screen at both extremes, dragging or not.
            let inset = Self.knobDiameterDragging / 2
            let trackWidth = max(proxy.size.width - inset * 2, 1)
            let clamped = min(max(progress, 0), 1)
            let knobSize = isDragging ? Self.knobDiameterDragging : Self.knobDiameter
            let x = inset + trackWidth * CGFloat(clamped)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: trackWidth, height: Self.trackHeight)
                    .offset(x: inset)
                // The system accent-color fill here (and on the knob below) is
                // INTENTIONAL, not a stray un-monochromed leftover — verified
                // visually against the actual Alcove reference render
                // (/tmp/alcove-refs/expanded-music.webp), which uses a
                // colored scrubber fill against the otherwise-monochrome
                // transport row. Do not "fix" this to plain white/monochrome.
                Capsule()
                    .fill(Color(nsColor: .controlAccentColor))
                    .frame(width: x - inset, height: Self.trackHeight)
                    .offset(x: inset)
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
                        onDragChanged(Double(min(max((value.location.x - inset) / trackWidth, 0), 1)))
                    }
                    .onEnded { value in
                        onDragEnded(Double(min(max((value.location.x - inset) / trackWidth, 0), 1)))
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

    /// Single-entry memo of the most recently derived gradient, keyed AND
    /// retained by the artwork image itself (not just an `ObjectIdentifier`).
    ///
    /// The previous version of this cache kept only `ObjectIdentifier(image):
    /// colors` entries without retaining the `NSImage` each identifier came
    /// from. `ObjectIdentifier` is just a bit pattern derived from an object's
    /// address — once that `NSImage` was deallocated (nothing else here held
    /// a reference to it), a *different*, later-allocated `NSImage` could land
    /// at the exact same address and collide with the stale identifier still
    /// sitting in the dictionary, silently handing back a wrong, unrelated
    /// track's colors. Storing the actual `image` alongside its colors and
    /// comparing with `===` (identity, not `Equatable`) fixes this at the
    /// root: as long as `memo.image` is the same live object, the address
    /// can't have been recycled out from under it.
    private static var memo: (image: NSImage, colors: (top: Color, bottom: Color))?

    /// The waveform's two gradient stops for a given artwork image — the
    /// average color of its top half, and of its bottom half. `nil` artwork
    /// (nothing playing, or artwork not yet loaded) and any extraction
    /// failure both fall back to `monochromeFallback` for both stops.
    static func waveformGradientColors(for image: NSImage?) -> (top: Color, bottom: Color) {
        let fallback = (monochromeFallback, monochromeFallback)
        guard let image else { return fallback }
        if let memo, memo.image === image { return memo.colors }

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cgImage.width > 0, cgImage.height > 0 else {
            return fallback
        }

        let result = topBottomColors(of: cgImage) ?? fallback
        memo = (image, result)
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
