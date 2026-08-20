import SwiftUI
import AppKit
import Combine
import Foundation

/// Wraps `NowPlayingService` as a `NotchWidget`: a mini artwork + animated
/// equalizer bars for the notch's compact strip/wings, and a full transport
/// UI (artwork, title/artist, waveform, scrubber, previous/play-pause/next,
/// source) for the expanded panel. Owns no now-playing state of its own —
/// `NowPlayingService` is the single source of truth; this class only adapts
/// it to the `NotchWidget` surface and starts/stops it on presentation.
///
/// `makeCompactView()` is still used for the collapsed notch's live-activity
/// wings and for `NotchSnapshot`'s fixture rendering, but — per the M7 shell
/// rework — it's no longer shown as a strip above `makeExpandedView()`'s
/// content in the expanded panel; the expanded view now carries its own
/// artwork/title header instead, so nothing above it would be redundant.
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

// MARK: - Compact (notch strip / wings) view

/// Mini artwork + a 3-bar equalizer, monochrome (white) throughout — no
/// `Theme.accentColor` here, matching the expanded panel's monochrome design
/// language. The bars only animate while something is actually playing — a
/// paused/stopped track renders static bars instead, so no
/// `TimelineView(.animation)` (and its per-frame redraw) exists at all in
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
                .foregroundStyle(NotchDesign.secondaryColor)
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
                        .fill(NotchDesign.primaryColor.opacity(0.9))
                        .frame(width: 2, height: barHeight(t, index: index))
                }
            }
            .frame(width: 14, height: 12, alignment: .bottom)
        }
    }

    private func barHeight(_ t: TimeInterval, index: Int) -> CGFloat {
        EqualizerAnimation.barHeight(time: t, index: index, base: 3, span: 9,
                                      freqBase: 2.4, freqStep: 0.7, phaseStep: 1.9)
    }
}

/// Static, dimmed mid-height bars — shown when nothing is playing, so the
/// equalizer never visually claims playback that isn't happening.
private struct StaticEqualizerBars: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach([5, 8, 5], id: \.self) { height in
                Capsule()
                    .fill(NotchDesign.tertiaryColor)
                    .frame(width: 2, height: CGFloat(height))
            }
        }
        .frame(width: 14, height: 12, alignment: .bottom)
    }
}

// MARK: - Expanded panel view

/// A compact two-row composition: enlarged artwork and track metadata share
/// the first row with the scrubber, while transport controls occupy a second
/// row. Keeping the scrubber beside the metadata is intentional — the shell's
/// expanded height is fixed, so giving each piece its own full-width row makes
/// the transport clip at the bottom.
private struct NowPlayingExpandedView: View {
    @ObservedObject var service: NowPlayingService
    @Environment(\.isNarrowPane) private var isNarrowPane

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

    private func content(for state: NowPlayingState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow(state)
                .frame(height: 64, alignment: .top)
            // The shell height is fixed. Let the transport row consume the
            // remaining safe space so it sits against the chrome's bottom
            // inset instead of leaving an accidental dead band below it.
            Spacer(minLength: 0)
            transportRow(state)
                .padding(.top, 5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
    }

    // MARK: Row 1 — artwork, title/artist, waveform

    private func headerRow(_ state: NowPlayingState) -> some View {
        HStack(alignment: .center, spacing: NotchDesign.space3) {
            FlippingArtwork(image: service.artwork,
                            flipKey: AnyHashable(flipKey(for: state)),
                            side: 64)

            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(text: state.title, font: NotchDesign.titleFont,
                            color: NotchDesign.primaryColor, height: 18)
                if let artist = state.artist {
                    MarqueeText(text: artist, font: .system(size: 13),
                                color: NotchDesign.secondaryColor, height: 16)
                }
                Spacer(minLength: 0)
                scrubberSection(state)
            }
            .frame(maxWidth: .infinity, maxHeight: 64, alignment: .leading)

            // Duo's Calendar pane is intentionally narrow. The waveform is a
            // decorative affordance, so give that width back to the title and
            // artist instead of allowing their marquee to start truncated.
            if !isNarrowPane {
                WaveformVisualizer(isPlaying: state.isPlaying,
                                    color: NotchDesign.primaryColor.opacity(0.85))
            }
        }
    }

    /// Identifies "the current track" for `FlippingArtwork`'s flip trigger.
    /// Includes whether artwork is currently present so a track's artwork
    /// arriving asynchronously (after its metadata) also triggers a flip
    /// reveal, rather than silently popping in — folding that into the key
    /// avoids needing a second, `NSImage`-comparing change handler entirely.
    private func flipKey(for state: NowPlayingState) -> String {
        "\(state.sourceBundleID ?? "")|\(state.title)|\(state.artist ?? "")|\(state.album ?? "")|\(service.artwork != nil)"
    }

    // MARK: Row 2 — scrubber

    /// The 1s tick only runs while playback is actually advancing — a
    /// paused/stopped track has nothing to extrapolate (`currentElapsed`
    /// just returns the last sample), so a plain, non-ticking render is used
    /// instead. This whole view only exists while the widget is presented
    /// (see `willPresent`/`didDismiss`), so no extra visibility gate is
    /// needed beyond `state.isPlaying`.
    @ViewBuilder
    private func scrubberSection(_ state: NowPlayingState) -> some View {
        if state.isPlaying {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                scrubberBody(state, at: timeline.date)
            }
        } else {
            scrubberBody(state, at: Date())
        }
    }

    /// A real, positive `duration` renders the interactive scrubber; anything
    /// else (`nil`, or `0`/negative — a live radio stream, or a source that
    /// simply hasn't reported one yet) has no meaningful "total" to scrub
    /// against, so it falls back to a bare, non-interactive capsule instead
    /// of fabricating one.
    @ViewBuilder
    private func scrubberBody(_ state: NowPlayingState, at date: Date) -> some View {
        if let duration = state.duration, duration > 0 {
            interactiveScrubber(state, duration: duration, at: date)
        } else {
            indeterminateScrubber
        }
    }

    private func interactiveScrubber(_ state: NowPlayingState, duration: TimeInterval, at date: Date) -> some View {
        let elapsed = min(max(isDragging ? dragValue : (service.currentElapsed(at: date) ?? 0), 0), duration)
        let remaining = max(duration - elapsed, 0)
        return VStack(spacing: 2) {
            HStack {
                Text(Self.format(elapsed))
                Spacer()
                Text("-\(Self.format(remaining))")
            }
            .font(NotchDesign.monoDigitsSmall)
            .foregroundStyle(NotchDesign.secondaryColor)

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
                    service.send(.seek(value))
                }
            )
        }
    }

    /// No knob, no time labels — there's no total to scrub against or
    /// measure remaining time from, so this is just a static, dim capsule
    /// that reads as "progress is happening, scale unknown."
    private var indeterminateScrubber: some View {
        Capsule()
            .fill(NotchDesign.primaryColor.opacity(0.15))
            .frame(height: 4)
    }

    private static func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Row 3 — transport

    /// Four elements, evenly spaced across the full width via `Spacer`s —
    /// no favorite/star button (there's no favorite API in the MediaRemote
    /// adapter, and a non-functional star would be a dead, dishonest
    /// control) — and monochrome white throughout, including
    /// play/pause: unlike the old amber "prominent" treatment, size alone
    /// (22pt vs 17pt) is what marks it as the visual anchor now.
    private func transportRow(_ state: NowPlayingState) -> some View {
        HStack {
            Spacer()
            transportButton("backward.fill", size: 17, label: "Previous track") { service.send(.previous) }
            Spacer()
            transportButton(state.isPlaying ? "pause.fill" : "play.fill", size: 22, prominent: true,
                            label: state.isPlaying ? "Pause" : "Play") {
                service.send(.togglePlayPause)
            }
            Spacer()
            transportButton("forward.fill", size: 17, label: "Next track") { service.send(.next) }
            Spacer()
            sourceButton(state)
            Spacer()
        }
        .frame(height: 28)
    }

    /// `label` is required, not optional: these are glyph-only controls, so
    /// without it VoiceOver announces every one of them as an unnamed
    /// "button" and the transport row is unusable.
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

    /// A generic "output" glyph rather than a per-app icon — mapping bundle
    /// IDs to specific glyphs (Apple Music note, Spotify logo, ...) isn't
    /// worth the maintenance surface for a single small affordance; tapping
    /// it opens the source app (via `NSWorkspace`) when its bundle ID is
    /// known, and is otherwise inert rather than guessing.
    private func sourceButton(_ state: NowPlayingState) -> some View {
        // Resolved up front so the control can *look* like what it is. When
        // the source app can't be resolved — no bundle id reported, or it
        // isn't installed — the button used to render identically and then do
        // nothing on click, the same dishonest affordance the clipboard's
        // non-copyable rows had.
        let appURL = state.sourceBundleID
            .flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        return Button {
            guard let appURL else { return }
            NSWorkspace.shared.open(appURL)
        } label: {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 15))
                .foregroundStyle(NotchDesign.primaryColor.opacity(
                    appURL == nil ? NotchDesign.quaternaryOpacity : NotchDesign.tertiaryOpacity))
        }
        .buttonStyle(.plain)
        .disabled(appURL == nil)
        .accessibilityLabel("Open the app that\u{2019}s playing")
    }
}
