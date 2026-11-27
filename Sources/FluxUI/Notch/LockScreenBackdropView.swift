import AppKit
import CoreGraphics
import CoreText
import SwiftUI

/// Immutable state for the minimal full-screen lock-screen canvas.
public struct LockScreenBackdropState: Equatable {
    public var sourceKey: String?
    public var backdrop: CGImage?
    public var foregroundCutout: CGImage?
    public var showsDepthEffect: Bool
    /// Optional fixed timestamp for deterministic snapshot rendering.
    public var fixedDate: Date?
    /// Minimal bottom hint shown when the full-screen backdrop is active.
    public var unlockHint: String?

    public init(sourceKey: String? = nil,
                backdrop: CGImage? = nil,
                foregroundCutout: CGImage? = nil,
                showsDepthEffect: Bool = true,
                fixedDate: Date? = nil,
                unlockHint: String? = "Touch ID or Enter Password") {
        self.sourceKey = sourceKey
        self.backdrop = backdrop
        self.foregroundCutout = foregroundCutout
        self.showsDepthEffect = showsDepthEffect
        self.fixedDate = fixedDate
        self.unlockHint = unlockHint
    }

    public static var empty: LockScreenBackdropState { LockScreenBackdropState(unlockHint: nil) }
    public var hasBackdrop: Bool { backdrop != nil }

    public static func == (lhs: LockScreenBackdropState, rhs: LockScreenBackdropState) -> Bool {
        lhs.sourceKey == rhs.sourceKey
            && lhs.backdrop === rhs.backdrop
            && lhs.foregroundCutout === rhs.foregroundCutout
            && lhs.showsDepthEffect == rhs.showsDepthEffect
            && lhs.fixedDate == rhs.fixedDate
            && lhs.unlockHint == rhs.unlockHint
    }
}

/// Converts a time string (e.g. "10:08") into an exact vector glyph `Path` via
/// CoreText so macOS 26+ `.glassEffect(.clear, in: ...)` applies real hardware
/// Liquid Glass refraction directly to every clock digit.
public struct ClockGlyphShape: Shape, Sendable {
    public let text: String
    public let fontSize: CGFloat

    public init(text: String, fontSize: CGFloat) {
        self.text = text
        self.fontSize = fontSize
    }

    public func path(in rect: CGRect) -> Path {
        guard !text.isEmpty, fontSize > 0, rect.width > 0, rect.height > 0 else { return Path() }
        let cgPath = Self.makeCGPath(text: text, fontSize: fontSize)
        let bounds = cgPath.boundingBoxOfPath
        guard !bounds.isEmpty, bounds.width > 0, bounds.height > 0 else { return Path() }

        // Flip CoreText's Y-up glyph outline into SwiftUI's Y-down frame and center it.
        var flip = CGAffineTransform(translationX: -bounds.midX, y: -bounds.midY)
            .concatenating(CGAffineTransform(scaleX: 1, y: -1))
            .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY))
        guard let centered = cgPath.copy(using: &flip) else { return Path() }
        return Path(centered)
    }

    public static func makeCGPath(text: String, fontSize: CGFloat) -> CGPath {
        let baseFont = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let descriptor = baseFont.fontDescriptor.addingAttributes([
            .featureSettings: [
                [
                    NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                    NSFontDescriptor.FeatureKey.selectorIdentifier: kProportionalNumbersSelector,
                ],
            ],
        ])
        let font = NSFont(descriptor: descriptor, size: fontSize) ?? baseFont
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .kern: -fontSize * 0.025,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []

        let combined = CGMutablePath()
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let runAttributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = (runAttributes[kCTFontAttributeName as String] as? NSFont ?? font) as CTFont

            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)

            for i in 0..<count {
                var transform = CGAffineTransform(translationX: positions[i].x, y: positions[i].y)
                if let glyphPath = CTFontCreatePathForGlyph(runFont, glyphs[i], &transform) {
                    combined.addPath(glyphPath)
                }
            }
        }
        return combined
    }
}

/// Full-screen minimal lock screen:
///   Layer 0: Edge-blurred widescreen album artwork / wallpaper
///   Layer 1: Crisp date + giant Liquid Glass clock
///   Layer 2: Vision foreground cutout stepping in front of the clock (depth effect)
///   Layer 3: Quiet centered unlock hint near the bottom
struct LockScreenBackdropView: View {
    @ObservedObject var model: LockScreenBackdropModel
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            if let backdrop = model.state.backdrop {
                ZStack {
                    // Layer 0: Full-screen blurred-edge photo backdrop (no opacity transition so
                    // the native macOS lock screen never bleeds through on lock or wake).
                    Image(decorative: backdrop, scale: 1)
                        .interpolation(.high)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size.width, height: size.height)
                        .clipped()
                        .id(model.state.sourceKey ?? "backdrop")

                    // Layer 1: Date + Sculpted Liquid Glass Clock positioned in the upper sky band.
                    clockStack(backdrop: backdrop, in: size)

                    // Layer 2: Vision depth-effect foreground cutout in front of the clock.
                    if model.state.showsDepthEffect, let cutout = model.state.foregroundCutout {
                        Image(decorative: cutout, scale: 1)
                            .interpolation(.high)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: size.width, height: size.height)
                            .clipped()
                            .id((model.state.sourceKey ?? "cutout") + ".depth")
                    }

                    // Layer 3: Quiet minimal bottom prompt.
                    if let hint = model.state.unlockHint, !hint.isEmpty {
                        VStack {
                            Spacer()
                            Text(hint)
                                .font(.system(size: max(11.5, min(13.5, size.height * 0.013)), weight: .medium))
                                .foregroundStyle(.white.opacity(0.84))
                                .shadow(color: .black.opacity(0.45), radius: 6, y: 1)
                                .padding(.bottom, max(24, size.height * 0.056))
                        }
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipped()
                .allowsHitTesting(false)
            } else {
                Color.clear
            }
        }
        .environment(\.isSnapshotRender, model.isFixtureRender)
    }

    @ViewBuilder
    private func clockStack(backdrop: CGImage, in screenSize: CGSize) -> some View {
        if let fixed = model.state.fixedDate {
            clockContent(date: fixed, backdrop: backdrop, in: screenSize)
        } else {
            TimelineView(.everyMinute) { timeline in
                clockContent(date: timeline.date, backdrop: backdrop, in: screenSize)
            }
        }
    }

    struct ClockLayout {
        let dateFontSize: CGFloat
        let clockFontSize: CGFloat
        let topOffset: CGFloat
        let dateLineHeight: CGFloat
        let stackSpacing: CGFloat
        let clockWidth: CGFloat
        let clockHeight: CGFloat
        let clockRect: CGRect

        init(screenSize: CGSize) {
            dateFontSize = max(18, min(30, screenSize.height * 0.0265))
            clockFontSize = max(120, min(230, screenSize.height * 0.205))
            topOffset = max(56, screenSize.height * 0.095)
            dateLineHeight = ceil(dateFontSize * 1.24)
            stackSpacing = max(2, screenSize.height * 0.004)
            clockWidth = min(screenSize.width * 0.78, clockFontSize * 3.1)
            clockHeight = clockFontSize * 0.80
            clockRect = CGRect(
                x: (screenSize.width - clockWidth) * 0.5,
                y: topOffset + dateLineHeight + stackSpacing,
                width: clockWidth,
                height: clockHeight
            )
        }
    }

    private func clockContent(date: Date, backdrop: CGImage, in screenSize: CGSize) -> some View {
        let layout = ClockLayout(screenSize: screenSize)
        let dateText = Self.formatDate(date)
        let timeText = Self.formatTime(date)

        return VStack(spacing: layout.stackSpacing) {
            Text(dateText)
                .font(.system(size: layout.dateFontSize, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(.white.opacity(0.92))
                .shadow(color: .black.opacity(0.26), radius: 10, y: 2)
                .frame(height: layout.dateLineHeight)

            LiquidGlassClockDigits(
                text: timeText,
                fontSize: layout.clockFontSize,
                sourceKey: model.state.sourceKey,
                backdrop: backdrop,
                canvasSize: screenSize,
                clockRectTopLeft: layout.clockRect
            )
            .frame(width: layout.clockWidth, height: layout.clockHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, layout.topOffset)
    }

    static func formatDate(_ date: Date, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return formatter.string(from: date).replacingOccurrences(of: ",", with: "")
    }

    static func formatTime(_ date: Date, locale: Locale = .current) -> String {
        let template = DateFormatter.dateFormat(fromTemplate: "jmm", options: 0, locale: locale) ?? "HH:mm"
        let is24Hour = template.contains("H") || template.contains("k")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = is24Hour ? "HH:mm" : "h:mm"
        return formatter.string(from: date)
    }
}

/// Renders clock digits as sculpted 3D refractive crystal glass using our Metal
/// GPU heightfield shader over the live wallpaper, with a translucent fallback
/// if Metal is unavailable.
private struct LiquidGlassClockDigits: View {
    let text: String
    let fontSize: CGFloat
    let sourceKey: String?
    let backdrop: CGImage
    let canvasSize: CGSize
    let clockRectTopLeft: CGRect

    var body: some View {
        Group {
            if let rendered = LiquidGlassRenderer.shared.renderClockGlass(
                sourceKey: sourceKey,
                backdrop: backdrop,
                canvasSizePt: canvasSize,
                clockRectTopLeftPt: clockRectTopLeft,
                timeText: text,
                fontSize: fontSize
            ) {
                Image(decorative: rendered, scale: 2.0)
                    .interpolation(.high)
                    .resizable()
            } else {
                fallbackDigits(shape: ClockGlyphShape(text: text, fontSize: fontSize))
            }
        }
        .shadow(color: .black.opacity(0.22), radius: 14, y: 4)
        .accessibilityHidden(true)
    }

    private func fallbackDigits(shape: ClockGlyphShape) -> some View {
        ZStack {
            shape
                .fill(.ultraThinMaterial)
                .opacity(0.70)

            shape
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.28), location: 0.0),
                            .init(color: .white.opacity(0.08), location: 0.50),
                            .init(color: .white.opacity(0.20), location: 1.0),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            shape
                .stroke(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.85), location: 0.0),
                            .init(color: .white.opacity(0.18), location: 0.45),
                            .init(color: .white.opacity(0.58), location: 1.0),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: max(1.3, fontSize * 0.0095)
                )
                .clipShape(shape)
        }
    }
}
