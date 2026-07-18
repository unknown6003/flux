import SwiftUI
import Combine
import Foundation

/// Wraps `NowPlayingService` as a `NotchWidget`: a mini artwork + animated
/// equalizer bars for the notch's compact strip, and a full transport UI
/// (artwork, title/artist, scrubber, previous/play-pause/next) for the
/// expanded panel. Owns no now-playing state of its own — `NowPlayingService`
/// is the single source of truth; this class only adapts it to the
/// `NotchWidget` surface and starts/stops it on presentation.
@MainActor
final class NowPlayingWidget: NotchWidget {
    let id: WidgetID = .nowPlaying

    /// Settings-driven; set by the wiring agent's Combine sink from
    /// `SettingsStore.notchNowPlayingEnabled`. `NotchWidgetRegistry` reads
    /// this every time it computes `enabledWidgets`.
    var isEnabled: Bool

    let service: NowPlayingService

    init(service: NowPlayingService, isEnabled: Bool = true) {
        self.service = service
        self.isEnabled = isEnabled
    }

    // MARK: - NotchWidget

    func makeExpandedView() -> AnyView {
        AnyView(NowPlayingExpandedView(service: service))
    }

    func makeCompactView() -> AnyView? {
        AnyView(NowPlayingCompactView(service: service))
    }

    func willPresent() {
        service.setActive(true)
    }

    func didDismiss() {
        service.setActive(false)
    }
}

// MARK: - Compact (notch strip) view

/// Mini artwork + a 3-bar equalizer. The bars only animate while something is
/// actually playing — a paused/stopped track renders static bars instead, so
/// no `TimelineView(.animation)` (and its per-frame redraw) exists at all in
/// that case. The view itself only exists while this widget is presented
/// (`willPresent`/`didDismiss` bracket that), so gating on `isPlaying` alone
/// here is sufficient to satisfy "animate only while playing AND visible".
private struct NowPlayingCompactView: View {
    @ObservedObject var service: NowPlayingService

    var body: some View {
        HStack(spacing: 4) {
            artwork
            if service.state?.isPlaying == true {
                AnimatedEqualizerBars()
            } else {
                StaticEqualizerBars()
            }
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let image = service.artwork {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else {
            Image(systemName: "music.note")
                .font(.system(size: 11))
                .foregroundStyle(Theme.accentColor)
                .frame(width: 16, height: 16)
        }
    }
}

/// Three bars whose heights oscillate independently while playing — each
/// rides its own sine phase/frequency so they don't lock into visible
/// unison, a cheap way to suggest a spectrum without any real audio analysis.
private struct AnimatedEqualizerBars: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(Theme.accentColor)
                        .frame(width: 2, height: barHeight(t, index: index))
                }
            }
            .frame(width: 14, height: 12, alignment: .bottom)
        }
    }

    private func barHeight(_ t: TimeInterval, index: Int) -> CGFloat {
        let frequency = 2.4 + Double(index) * 0.7
        let phase = Double(index) * 1.9
        let wave = (sin(t * frequency + phase) + 1) / 2
        return 3 + CGFloat(wave) * 9
    }
}

/// Static, dimmed mid-height bars — shown when nothing is playing, so the
/// equalizer never visually claims playback that isn't happening.
private struct StaticEqualizerBars: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach([5, 8, 5], id: \.self) { height in
                Capsule()
                    .fill(Theme.accentColor.opacity(0.5))
                    .frame(width: 2, height: CGFloat(height))
            }
        }
        .frame(width: 14, height: 12, alignment: .bottom)
    }
}

// MARK: - Expanded panel view

private struct NowPlayingExpandedView: View {
    @ObservedObject var service: NowPlayingService

    @State private var isDragging = false
    @State private var dragValue: TimeInterval = 0

    var body: some View {
        Group {
            if let state = service.state {
                content(for: state)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note")
                .font(.system(size: 28))
                .foregroundStyle(Theme.accentColor.opacity(0.5))
            Text("Nothing playing")
                .font(.callout)
                .foregroundStyle(Color.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(for state: NowPlayingState) -> some View {
        HStack(alignment: .top, spacing: 16) {
            artworkView(state)

            VStack(alignment: .leading, spacing: 10) {
                titleBlock(state)
                Spacer(minLength: 0)
                scrubber(state)
                transportRow(state)
                Text(service.activeSourceName)
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.4))
            }
        }
    }

    // MARK: Artwork

    @ViewBuilder
    private func artworkView(_ state: NowPlayingState) -> some View {
        Group {
            if let image = service.artwork {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Theme.surfaceRaisedColor)
                    .overlay(Image(systemName: "music.note").foregroundStyle(Theme.accentColor))
            }
        }
        .frame(width: 120, height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
    }

    private func titleBlock(_ state: NowPlayingState) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(state.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if let artist = state.artist {
                Text(artist)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
    }

    // MARK: Scrubber

    /// The 1s tick only runs while playback is actually advancing — a
    /// paused/stopped track has nothing to extrapolate (`currentElapsed`
    /// just returns the last sample), so a plain, non-ticking render is used
    /// instead. This whole view only exists while the widget is presented
    /// (see `willPresent`/`didDismiss`), so no extra visibility gate is
    /// needed beyond `state.isPlaying`.
    @ViewBuilder
    private func scrubber(_ state: NowPlayingState) -> some View {
        if state.isPlaying {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                scrubberBody(state, at: timeline.date)
            }
        } else {
            scrubberBody(state, at: Date())
        }
    }

    /// A real, positive `duration` renders the interactive slider; anything
    /// else (`nil`, or `0`/negative — a live radio stream, or a source that
    /// simply hasn't reported one yet) has no meaningful "total" to scrub
    /// against, so it falls back to a non-interactive affordance instead of
    /// fabricating one — the previous behavior clamped a missing duration to
    /// a fake 1s, which both drew a nonsensical slider and could send a
    /// bogus absolute `.seek(dragValue)` clamped into that fake 0...1s range.
    @ViewBuilder
    private func scrubberBody(_ state: NowPlayingState, at date: Date) -> some View {
        if let duration = state.duration, duration > 0 {
            interactiveScrubber(state, duration: duration, at: date)
        } else {
            indeterminateScrubber(at: date)
        }
    }

    private func interactiveScrubber(_ state: NowPlayingState, duration: TimeInterval, at date: Date) -> some View {
        let elapsed = min(max(isDragging ? dragValue : (service.currentElapsed(at: date) ?? 0), 0), duration)
        let binding = Binding<TimeInterval>(
            get: { elapsed },
            set: { dragValue = $0 }
        )
        return VStack(spacing: 4) {
            Slider(value: binding, in: 0...duration, onEditingChanged: { editing in
                if editing { dragValue = elapsed }
                isDragging = editing
                if !editing { service.send(.seek(dragValue)) }
            })
            .tint(Theme.accentColor)

            HStack {
                Text(Self.format(elapsed))
                Spacer()
                Text(Self.format(duration))
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.5))
        }
    }

    /// No slider (nothing to drag against, and no `.seek` is ever sent from
    /// here), and no total-time label (there is no total) — just the elapsed
    /// time over a thin, static capsule that reads as "progress is happening,
    /// scale unknown" rather than a real, draggable timeline.
    private func indeterminateScrubber(at date: Date) -> some View {
        let elapsed = max(service.currentElapsed(at: date) ?? 0, 0)
        return VStack(spacing: 4) {
            Capsule()
                .fill(Color.white.opacity(0.15))
                .frame(height: 4)

            HStack {
                Text(Self.format(elapsed))
                Spacer()
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.5))
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Transport

    private func transportRow(_ state: NowPlayingState) -> some View {
        HStack(spacing: 20) {
            transportButton("backward.fill") { service.send(.previous) }
            transportButton(state.isPlaying ? "pause.fill" : "play.fill", prominent: true) {
                service.send(.togglePlayPause)
            }
            transportButton("forward.fill") { service.send(.next) }
        }
    }

    private func transportButton(_ systemName: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: prominent ? 18 : 14, weight: .semibold))
                .foregroundStyle(prominent ? Theme.accentColor : Color.white.opacity(0.8))
        }
        .buttonStyle(.plain)
    }
}
