import AppKit
import SwiftUI

/// Floating Liquid Glass music player for the minimal lock screen.
///
/// Layout mirrors Canape's clean centered glass card:
/// - Centered bold title + translucent artist, with a symmetric animated
///   waveform pinned to the top-right corner
/// - Elapsed time, interactive frosted pill scrubber, and negative remaining time
/// - Balanced 5-slot transport row: mute toggle, previous, bare play/pause,
///   next, and audio output route switcher
struct LockScreenMediaControlsView: View {
    @ObservedObject var model: LockScreenCardModel
    @State private var scrubFraction: Double?

    var body: some View {
        let state = model.state
        let hasMedia = state.showsMedia
        let hasAuxiliaryContent = state.showsActivity
        let pickerCount = model.isOutputPickerExpanded ? (state.audioOutput?.devices.count ?? 0) : 0
        let size = LockScreenMetrics.size(hasMedia: hasMedia,
                                          hasActivity: hasAuxiliaryContent,
                                          expandedOutputCount: pickerCount)

        Group {
            if hasMedia, let media = state.media {
                lockScreenGlassGroup {
                    VStack(spacing: 0) {
                        mediaCard(for: media, audioOutput: state.audioOutput)
                        if hasAuxiliaryContent {
                            auxiliaryPill(state.activity)
                                .padding(.top, LockScreenMetrics.captionGap)
                        }
                    }
                }
            } else if hasAuxiliaryContent {
                auxiliaryPill(state.activity)
            } else {
                Color.clear
            }
        }
        .frame(width: max(size.width, 1), height: max(size.height, 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(hasMedia ? "Lock Screen Now Playing" : "Lock Screen Activity")
        .environment(\.isSnapshotRender, model.isFixtureRender)
    }

    @ViewBuilder
    private func lockScreenGlassGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *), !model.isFixtureRender {
            GlassEffectContainer(spacing: LockScreenMetrics.captionGap) {
                content()
            }
        } else {
            content()
        }
#else
        content()
#endif
    }

    // MARK: - Media Card

    private func mediaCard(for media: NowPlayingWidgetState, audioOutput: LockScreenAudioOutputState?) -> some View {
        let isPlaying = media.status == .playing
        let pickerDevices = Array((audioOutput?.devices ?? []).prefix(LockScreenMetrics.outputPickerMaxRows))
        let showPicker = model.isOutputPickerExpanded && !pickerDevices.isEmpty
        let cardHeight = LockScreenMetrics.size(hasMedia: true,
                                                hasActivity: false,
                                                expandedOutputCount: showPicker ? pickerDevices.count : 0).height
        let cardShape = RoundedRectangle(cornerRadius: LockScreenMetrics.cardCornerRadius, style: .continuous)

        let cardBody = VStack(spacing: 0) {
            // Top row: Small album art thumbnail (left) — Centered Title & Artist — Live waveform (right).
            ZStack {
                VStack(spacing: 2) {
                    Text(media.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.96))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .shadow(color: .black.opacity(0.36), radius: 4, y: 1)

                    if !media.artist.isEmpty {
                        Text(media.artist)
                            .font(.system(size: 13.5, weight: .regular))
                            .foregroundStyle(.white.opacity(0.76))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .shadow(color: .black.opacity(0.30), radius: 3, y: 1)
                    }
                }
                .padding(.horizontal, 44)
                .frame(maxWidth: .infinity, alignment: .center)

                HStack {
                    smallArtwork(media.artwork)
                    Spacer()
                    LockScreenWaveformView(isPlaying: isPlaying)
                }
            }
            .frame(height: 40)

            // Middle row: Elapsed — Interactive Pill Scrubber — Remaining.
            progressRow(for: media)
                .padding(.top, 10)

            // Bottom row: Mute — Prev / Play-Pause / Next — Audio Output Route.
            transportRow(isPlaying: isPlaying,
                         canGoPrevious: media.canGoPrevious,
                         canGoNext: media.canGoNext,
                         audioOutput: audioOutput)
                .padding(.top, 12)

            if showPicker {
                outputPickerList(devices: pickerDevices)
                    .padding(.top, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: LockScreenMetrics.mediaWidth, height: cardHeight, alignment: .top)

        return ZStack {
            // Pixel-aligned slice of the lock-screen wallpaper directly inside
            // this window so macOS 26/27 `.glassEffect(.clear)` performs real
            // chromatic edge refraction & optical lensing over the exact pixels behind it.
            if let slice = model.state.backdropSlice {
                Image(decorative: slice, scale: 1)
                    .interpolation(.high)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: LockScreenMetrics.mediaWidth, height: cardHeight)
                    .clipShape(cardShape)
            }

            cardBody
                .lockScreenLiquidGlass(in: cardShape, hasInWindowBackdrop: model.state.backdropSlice != nil)
        }
        .frame(width: LockScreenMetrics.mediaWidth, height: cardHeight)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: showPicker)
    }

    @ViewBuilder
    private func smallArtwork(_ image: NSImage?) -> some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(.white.opacity(0.22), lineWidth: 0.6)
                )
                .shadow(color: .black.opacity(0.28), radius: 4, y: 2)
        } else {
            Color.clear.frame(width: 36, height: 36)
        }
    }

    // MARK: - Progress & Interactive Scrubber

    @ViewBuilder
    private func progressRow(for media: NowPlayingWidgetState) -> some View {
        if media.status == .playing {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                progressRowBody(for: media, at: timeline.date)
            }
        } else {
            progressRowBody(for: media, at: Date())
        }
    }

    @ViewBuilder
    private func progressRowBody(for media: NowPlayingWidgetState, at date: Date) -> some View {
        if let duration = media.duration, duration > 0 {
            let liveElapsed = min(max(model.elapsed(at: date), 0), duration)
            let displayedElapsed = scrubFraction.map { $0 * duration } ?? liveElapsed
            let progress = min(max(displayedElapsed / duration, 0), 1)

            HStack(spacing: 9) {
                Text(timeLabel(displayedElapsed))
                    .frame(minWidth: 32, alignment: .leading)

                LockScreenScrubberBar(
                    progress: progress,
                    isDragging: scrubFraction != nil,
                    onChanged: { fraction in scrubFraction = fraction },
                    onEnded: { fraction in
                        scrubFraction = nil
                        model.onAction(.seek(fraction * duration))
                    }
                )

                Text("-\(timeLabel(max(duration - displayedElapsed, 0)))")
                    .frame(minWidth: 36, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.80))
            .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
            .frame(height: 16)
        } else {
            Capsule()
                .fill(.white.opacity(0.24))
                .frame(height: 5.5)
                .frame(height: 16)
        }
    }

    // MARK: - Transport Row

    private func transportRow(isPlaying: Bool,
                              canGoPrevious: Bool,
                              canGoNext: Bool,
                              audioOutput: LockScreenAudioOutputState?) -> some View {
        let isMuted = audioOutput?.isMuted ?? false
        let canMute = audioOutput?.canMute ?? false
        let outputSymbol = audioOutput?.currentSymbolName ?? "display"
        let hasMultipleOutputs = (audioOutput?.devices.count ?? 0) > 1

        return HStack(spacing: 0) {
            LockScreenTransportButton(
                systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2",
                label: isMuted ? "Unmute" : "Mute",
                fontSize: 14.5,
                weight: .medium,
                foregroundOpacity: isMuted ? 0.92 : (canMute ? 0.48 : 0.28),
                frameSize: 34,
                isEnabled: canMute
            ) {
                model.onAction(.toggleMute)
            }

            Spacer(minLength: 8)

            HStack(spacing: 24) {
                LockScreenTransportButton(
                    systemName: "backward.fill",
                    label: "Previous track",
                    fontSize: 19,
                    weight: .semibold,
                    foregroundOpacity: canGoPrevious ? 0.94 : 0.35,
                    frameSize: 38,
                    isEnabled: canGoPrevious
                ) {
                    model.onAction(.previous)
                }

                LockScreenTransportButton(
                    systemName: isPlaying ? "pause.fill" : "play.fill",
                    label: isPlaying ? "Pause" : "Play",
                    fontSize: 25,
                    weight: .bold,
                    foregroundOpacity: 0.98,
                    frameSize: 44,
                    isEnabled: true
                ) {
                    model.onAction(isPlaying ? .pause : .play)
                }

                LockScreenTransportButton(
                    systemName: "forward.fill",
                    label: "Next track",
                    fontSize: 19,
                    weight: .semibold,
                    foregroundOpacity: canGoNext ? 0.94 : 0.35,
                    frameSize: 38,
                    isEnabled: canGoNext
                ) {
                    model.onAction(.next)
                }
            }

            Spacer(minLength: 8)

            LockScreenTransportButton(
                systemName: outputSymbol,
                label: audioOutput.map { "Audio output: \($0.currentDeviceName)" } ?? "Audio output",
                fontSize: 15,
                weight: .medium,
                foregroundOpacity: model.isOutputPickerExpanded ? 1.0 : (hasMultipleOutputs ? 0.80 : 0.50),
                frameSize: 34,
                isEnabled: hasMultipleOutputs
            ) {
                model.isOutputPickerExpanded.toggle()
            }
        }
        .frame(height: 44)
    }

    // MARK: - Inline Audio Output Picker

    private func outputPickerList(devices: [LockScreenAudioDevice]) -> some View {
        VStack(spacing: 4) {
            Rectangle()
                .fill(.white.opacity(0.14))
                .frame(height: 0.5)
                .padding(.bottom, 4)

            ForEach(devices) { device in
                Button {
                    model.onAction(.selectAudioOutput(device.id))
                    model.isOutputPickerExpanded = false
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: device.symbolName)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 18)
                        Text(device.name)
                            .font(.system(size: 12, weight: device.isSelected ? .semibold : .regular))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        if device.isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .foregroundStyle(.white.opacity(device.isSelected ? 0.96 : 0.72))
                    .padding(.horizontal, 10)
                    .frame(height: LockScreenMetrics.outputPickerRowHeight - 4)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(.white.opacity(device.isSelected ? 0.14 : 0.0))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Auxiliary Activity Pill

    @ViewBuilder
    private func auxiliaryPill(_ caption: LockScreenActivityCaption?) -> some View {
        HStack(spacing: NotchDesign.space2) {
            if let caption {
                LockScreenActivityPill(systemName: caption.symbolName, caption: caption.text)
            }
        }
        .frame(maxWidth: .infinity, minHeight: LockScreenMetrics.captionHeight)
    }

    private func timeLabel(_ seconds: TimeInterval) -> String {
        let total = max(Int(min(seconds, Double(Int32.max)).rounded(.down)), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Interactive Pill Scrubber

private struct LockScreenScrubberBar: View {
    let progress: Double
    let isDragging: Bool
    let onChanged: (Double) -> Void
    let onEnded: (Double) -> Void

    @State private var isHovering = false

    private var trackHeight: CGFloat {
        isDragging ? 8.0 : (isHovering ? 6.5 : 5.5)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let clamped = min(max(progress, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.26))
                    .frame(width: width, height: trackHeight)
                Capsule()
                    .fill(.white.opacity(0.88))
                    .frame(width: max(trackHeight, width * CGFloat(clamped)), height: trackHeight)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onChanged(Double(min(max(value.location.x / width, 0), 1)))
                    }
                    .onEnded { value in
                        onEnded(Double(min(max(value.location.x / width, 0), 1)))
                    }
            )
            .animation(.spring(response: 0.20, dampingFraction: 0.82), value: trackHeight)
        }
        .frame(height: 16)
    }
}

// MARK: - Symmetric Centered Liquid Glass Waveform

/// 7-bar centered symmetric audio waveform pinned to the player's top-right.
private struct LockScreenWaveformView: View {
    let isPlaying: Bool
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    private static let barCount = 7
    private static let barWidth: CGFloat = 2.0
    private static let barSpacing: CGFloat = 2.0
    private static let maxHeight: CGFloat = 18
    /// Symmetric bell envelope so outer bars stay dainty while inner bars pulse.
    private static let envelope: [CGFloat] = [0.32, 0.58, 0.82, 1.0, 0.78, 0.56, 0.30]
    private static let staticHeights: [CGFloat] = [4, 7, 11, 14, 10, 7, 4]

    var body: some View {
        Group {
            if isPlaying {
                if isSnapshotRender {
                    bars(heights: [5, 11, 8, 17, 12, 9, 5])
                } else {
                    TimelineView(.animation) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        bars(heights: (0..<Self.barCount).map { animatedHeight(t: t, index: $0) })
                    }
                }
            } else {
                bars(heights: Self.staticHeights).opacity(0.45)
            }
        }
        .frame(width: CGFloat(Self.barCount) * Self.barWidth + CGFloat(Self.barCount - 1) * Self.barSpacing,
               height: Self.maxHeight,
               alignment: .center)
        .accessibilityHidden(true)
    }

    private func animatedHeight(t: TimeInterval, index: Int) -> CGFloat {
        let base: CGFloat = 3.5
        let peak = (Self.maxHeight - base) * Self.envelope[index]
        return EqualizerAnimation.barHeight(time: t, index: index, base: base, span: peak,
                                            freqBase: 2.3, freqStep: 0.62, phaseStep: 1.15)
    }

    private func bars(heights: [CGFloat]) -> some View {
        HStack(alignment: .center, spacing: Self.barSpacing) {
            ForEach(Array(heights.enumerated()), id: \.offset) { _, height in
                Capsule()
                    .fill(.white.opacity(0.76))
                    .frame(width: Self.barWidth, height: height)
            }
        }
    }
}

// MARK: - Tactile Transport Button

private struct LockScreenTransportButton: View {
    let systemName: String
    let label: String
    let fontSize: CGFloat
    let weight: Font.Weight
    let foregroundOpacity: Double
    let frameSize: CGFloat
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: fontSize, weight: weight))
                .foregroundStyle(.white.opacity(foregroundOpacity))
                .shadow(color: .black.opacity(0.28), radius: 3, y: 1)
                .frame(width: frameSize, height: frameSize)
                .background(
                    Circle()
                        .fill(.white.opacity(isHovering && isEnabled ? 0.14 : 0))
                )
                .contentShape(Circle())
        }
        .buttonStyle(LockScreenPressScaleStyle())
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .accessibilityLabel(label)
    }
}

private struct LockScreenPressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.87 : 1.0)
            .animation(.spring(response: 0.18, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

// MARK: - Clear Liquid Glass Surface

/// Pure macOS 26+ `.glassEffect(.clear)` surface for authentic chromatic
/// refractive lensing, with a luminous frosted-glass fallback for macOS 14–15
/// and offscreen snapshots.
private struct LockScreenLiquidGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let hasInWindowBackdrop: Bool
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    @ViewBuilder
    func body(content: Content) -> some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *), !isSnapshotRender {
            if hasInWindowBackdrop {
                // Pure `.clear` directly over the in-window wallpaper slice unlocks
                // macOS 26/27's full chromatic edge refraction and lensing without muddying it.
                content
                    .glassEffect(.clear, in: shape)
            } else {
                content
                    .glassEffect(.clear.tint(.black.opacity(0.08)), in: shape)
            }
        } else {
            fallbackSurface(content)
        }
#else
        fallbackSurface(content)
#endif
    }

    private func fallbackSurface(_ content: Content) -> some View {
        content
            .background(
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(Color.black.opacity(0.20))
                }
            )
            .overlay(
                shape.stroke(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.42), location: 0.0),
                            .init(color: .white.opacity(0.10), location: 0.45),
                            .init(color: .white.opacity(0.28), location: 1.0),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
            )
            .shadow(color: .black.opacity(0.32), radius: 22, y: 10)
    }
}

private extension View {
    func lockScreenLiquidGlass<S: Shape>(in shape: S, hasInWindowBackdrop: Bool = false) -> some View {
        modifier(LockScreenLiquidGlassModifier(shape: shape, hasInWindowBackdrop: hasInWindowBackdrop))
    }
}

// MARK: - Auxiliary Activity Pill

private struct LockScreenActivityPill: View {
    let systemName: String?
    let caption: String

    var body: some View {
        HStack(spacing: NotchDesign.space2) {
            if let systemName {
                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.white.opacity(0.14)))
            }
            Text(caption)
                .font(NotchDesign.bodyFont)
                .foregroundStyle(.white.opacity(0.94))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, NotchDesign.space3)
        .frame(height: LockScreenMetrics.captionHeight)
        .lockScreenLiquidGlass(in: Capsule())
    }
}
