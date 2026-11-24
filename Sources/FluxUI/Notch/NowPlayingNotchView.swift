import AppKit
import FluxCore
import SwiftUI

// Ported from Flux 0.21.35: Sources/Flux/Notch/Widgets/NowPlayingWidget.swift
// (NowPlayingExpandedView). Layout, fonts and controls are unchanged; the
// media service is replaced by `NowPlayingWidgetState` and typed actions.

@MainActor
final class NowPlayingNotchModel: ObservableObject {
    @Published private(set) var state: NowPlayingWidgetState
    /// When `state.elapsed` was true. Elapsed time moves from here while playing.
    private(set) var receivedAt: Date
    let onAction: @MainActor (NowPlayingWidgetAction) -> Void

    init(state: NowPlayingWidgetState, onAction: @escaping @MainActor (NowPlayingWidgetAction) -> Void) {
        self.state = state
        self.onAction = onAction
        receivedAt = Date()
    }

    func update(_ newState: NowPlayingWidgetState) {
        receivedAt = Date()
        state = newState
    }

    var hasMedia: Bool { state.status == .playing || state.status == .paused }
    var isPlaying: Bool { state.status == .playing }

    func elapsed(at date: Date) -> TimeInterval {
        guard isPlaying else { return state.elapsed }
        return state.elapsed + max(0, date.timeIntervalSince(receivedAt))
    }
}

struct NowPlayingExpandedView: View {
    @ObservedObject var model: NowPlayingNotchModel
    @Environment(\.isNarrowPane) private var isNarrowPane

    @State private var isDragging = false
    @State private var dragValue: TimeInterval = 0

    var body: some View {
        Group {
            if model.hasMedia {
                content(for: model.state)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: NotchDesign.space2) {
            Image(systemName: "music.note")
                .font(.system(size: 28))
                .foregroundStyle(NotchDesign.quaternaryColor)
            Text("Nothing playing")
                .font(.callout)
                .foregroundStyle(NotchDesign.secondaryColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(for state: NowPlayingWidgetState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow(state)
                .frame(height: 58, alignment: .center)
            scrubberSection(state)
                .padding(.top, 14)
            Spacer(minLength: 6)
            transportRow(state)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
    }

    private func headerRow(_ state: NowPlayingWidgetState) -> some View {
        HStack(alignment: .center, spacing: 14) {
            FlippingArtwork(image: state.artwork,
                            flipKey: AnyHashable(flipKey(for: state)),
                            side: 58)

            VStack(alignment: .leading, spacing: 3) {
                MarqueeText(text: state.title, font: NotchDesign.titleFont,
                            color: NotchDesign.primaryColor, height: 19)
                if !state.artist.isEmpty {
                    MarqueeText(text: state.artist, font: .system(size: 13),
                                color: NotchDesign.secondaryColor, height: 16)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !isNarrowPane {
                WaveformVisualizer(isPlaying: model.isPlaying,
                                   color: NotchDesign.primaryColor.opacity(0.85))
            }
        }
    }

    private func flipKey(for state: NowPlayingWidgetState) -> String {
        "\(state.selectedSource?.rawValue ?? "")|\(state.title)|\(state.artist)||\(state.artwork != nil)"
    }

    @ViewBuilder
    private func scrubberSection(_ state: NowPlayingWidgetState) -> some View {
        if model.isPlaying {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                scrubberBody(state, at: timeline.date)
            }
        } else {
            scrubberBody(state, at: Date())
        }
    }

    @ViewBuilder
    private func scrubberBody(_ state: NowPlayingWidgetState, at date: Date) -> some View {
        if let duration = state.duration, duration > 0 {
            interactiveScrubber(duration: duration, at: date)
        } else {
            indeterminateScrubber
        }
    }

    private func interactiveScrubber(duration: TimeInterval, at date: Date) -> some View {
        let elapsed = min(max(isDragging ? dragValue : model.elapsed(at: date), 0), duration)
        let remaining = max(duration - elapsed, 0)
        return HStack(spacing: 10) {
            Text(Self.format(elapsed))
                .frame(minWidth: 32, alignment: .leading)

            ScrubberTrack(
                progress: elapsed / duration,
                isDragging: isDragging,
                onDragChanged: { progress in
                    isDragging = true
                    dragValue = progress * duration
                },
                onDragEnded: { progress in
                    let value = progress * duration
                    dragValue = value
                    isDragging = false
                    model.onAction(.seek(value))
                }
            )

            Text("-\(Self.format(remaining))")
                .frame(minWidth: 36, alignment: .trailing)
        }
        .font(NotchDesign.monoDigitsSmall)
        .foregroundStyle(NotchDesign.secondaryColor)
        .frame(height: 16)
    }

    private var indeterminateScrubber: some View {
        Capsule()
            .fill(NotchDesign.primaryColor.opacity(0.15))
            .frame(height: 4)
            .frame(height: 16)
    }

    static func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(min(seconds, Double(Int32.max)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func transportRow(_ state: NowPlayingWidgetState) -> some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: 32, height: 28)

            Spacer(minLength: 8)

            HStack(spacing: isNarrowPane ? 16 : 28) {
                transportButton("backward.fill", size: 17, label: "Previous track") { model.onAction(.previous) }
                transportButton(model.isPlaying ? "pause.fill" : "play.fill", size: 23, prominent: true,
                                label: model.isPlaying ? "Pause" : "Play") {
                    model.onAction(.togglePlayPause)
                }
                transportButton("forward.fill", size: 17, label: "Next track") { model.onAction(.next) }
            }

            Spacer(minLength: 8)

            sourceButton(state)
                .frame(width: 32, height: 28)
        }
        .frame(height: 30)
    }

    private func transportButton(_ systemName: String, size: CGFloat, prominent: Bool = false,
                                 label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: prominent ? .semibold : .medium))
                .foregroundStyle(NotchDesign.primaryColor)
                .frame(width: prominent ? 38 : 32, height: 28)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func sourceButton(_ state: NowPlayingWidgetState) -> some View {
        let hasApp = state.selectedSource
            .flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.rawValue) } != nil
        return Button {
            guard hasApp else { return }
            model.onAction(.openSource)
        } label: {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 15))
                .foregroundStyle(NotchDesign.primaryColor.opacity(
                    hasApp ? NotchDesign.tertiaryOpacity : NotchDesign.quaternaryOpacity))
        }
        .buttonStyle(.plain)
        .disabled(!hasApp)
        .accessibilityLabel("Open the app that\u{2019}s playing")
    }
}
