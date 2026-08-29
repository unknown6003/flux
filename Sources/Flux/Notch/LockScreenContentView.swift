import SwiftUI
import AppKit

/// The safe, mouse-transparent part of the lock-screen presentation: the
/// physical camera-housing silhouette only. The interactive media surface is
/// hosted in a separate, centered panel by `LockScreenPresenter`, so the
/// password field and the rest of macOS's lock UI remain untouched.
struct LockScreenContentView: View {
    let notchSize: CGSize

    var body: some View {
        NotchShape.collapsed
            .fill(Color.black)
            .frame(width: max(notchSize.width, 1), height: max(notchSize.height, 8))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .accessibilityHidden(true)
    }
}

/// The two kinds of lock-screen affordance, in stable media/activity order.
/// The pure derivation is retained separately from the views so the whole
/// preference matrix can be checked by the headless self-test.
enum LockScreenPillKind: Equatable {
    case nowPlaying
    case activity
}

enum LockScreenPillLogic {
    static func visiblePills(hasNowPlaying: Bool, allowNowPlaying: Bool,
                              hasActivityCaption: Bool, allowActivities: Bool) -> [LockScreenPillKind] {
        var pills: [LockScreenPillKind] = []
        if hasNowPlaying && allowNowPlaying {
            pills.append(.nowPlaying)
        }
        if hasActivityCaption && allowActivities {
            pills.append(.activity)
        }
        return pills
    }
}

/// Pure gating for the lock-screen widget. Keeping it independent of AppKit
/// makes it possible to prove that the companion panel disappears whenever
/// all of its content is disabled, instead of leaving an invisible
/// mouse-sensitive window over the password UI.
enum LockScreenMediaControlLogic {
    static func shouldShow(hasNowPlaying: Bool, allowNowPlaying: Bool) -> Bool {
        hasNowPlaying && allowNowPlaying
    }

    static func shouldShowWidget(hasNowPlaying: Bool,
                                 allowNowPlaying: Bool,
                                 hasActivityCaption: Bool,
                                 allowActivities: Bool) -> Bool {
        !LockScreenPillLogic.visiblePills(
            hasNowPlaying: hasNowPlaying,
            allowNowPlaying: allowNowPlaying,
            hasActivityCaption: hasActivityCaption,
            allowActivities: allowActivities).isEmpty
    }
}

// MARK: - Widget metrics

enum LockScreenPillMetrics {
    /// Tahoe's lock-screen controls are a centered, floating glass surface:
    /// generous artwork, clear hierarchy, and one soft continuous corner.
    static let mediaControlsWidth: CGFloat = 348
    static let activityOnlyWidth: CGFloat = 240
    static let mediaCardHeight: CGFloat = 164
    static let mediaCardCornerRadius: CGFloat = 24
    static let artworkSide: CGFloat = 64
    static let artworkRadius: CGFloat = 14
    static let auxiliaryPillHeight: CGFloat = 38

    static func widgetSize(hasMedia: Bool, hasAuxiliaryContent: Bool) -> CGSize {
        if hasMedia {
            let auxiliaryHeight = hasAuxiliaryContent
                ? NotchDesign.space2 + auxiliaryPillHeight
                : 0
            return CGSize(width: mediaControlsWidth,
                          height: mediaCardHeight + auxiliaryHeight)
        }
        return CGSize(width: hasAuxiliaryContent ? activityOnlyWidth : 1,
                      height: hasAuxiliaryContent ? auxiliaryPillHeight : 1)
    }
}

/// An Apple-style lock-screen media widget. It is deliberately a single
/// surface — artwork, title, progress, transport, and any secondary lock
/// affordances — rather than a media card followed by unrelated floating
/// pills. The panel is hosted separately so only the transport buttons accept
/// mouse events.
struct LockScreenMediaControlsView: View {
    @ObservedObject var nowPlaying: NowPlayingService
    @ObservedObject var activities: LiveActivityCenter
    let allowNowPlaying: Bool
    let allowActivities: Bool
    let onCommand: (NowPlayingCommand) -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var prominentControlForeground: Color {
        colorScheme == .dark ? .black : .white
    }

    var body: some View {
        let hasMedia = LockScreenMediaControlLogic.shouldShow(
            hasNowPlaying: nowPlaying.state != nil,
            allowNowPlaying: allowNowPlaying)
        let pills = LockScreenPillLogic.visiblePills(
            hasNowPlaying: nowPlaying.state != nil,
            allowNowPlaying: allowNowPlaying,
            hasActivityCaption: activities.current?.captionText != nil,
            allowActivities: allowActivities)
        let hasAuxiliaryContent = pills.contains(.activity)
        let size = LockScreenPillMetrics.widgetSize(hasMedia: hasMedia,
                                                    hasAuxiliaryContent: hasAuxiliaryContent)

        Group {
            if hasMedia, let state = nowPlaying.state {
                VStack(spacing: 0) {
                    mediaCard(for: state)
                    if hasAuxiliaryContent {
                        auxiliaryPills(pills)
                            .padding(.top, NotchDesign.space2)
                    }
                }
            } else if hasAuxiliaryContent {
                auxiliaryPills(pills)
            } else {
                Color.clear
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(hasMedia ? "Lock Screen Now Playing" : "Lock Screen Activity")
    }

    private func mediaCard(for state: NowPlayingState) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: NotchDesign.space3) {
                artwork
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.title)
                        .font(NotchDesign.titleFont)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let artist = state.artist, !artist.isEmpty {
                        Text(artist)
                            .font(NotchDesign.captionFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: state.isPlaying ? "waveform" : "music.note")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(height: LockScreenPillMetrics.artworkSide)

            progressRow(for: state)
                .padding(.top, 7)

            transportRow(for: state)
                .padding(.top, 5)
        }
        .padding(.horizontal, NotchDesign.space4)
        .padding(.vertical, NotchDesign.space3)
        .frame(width: LockScreenPillMetrics.mediaControlsWidth,
               height: LockScreenPillMetrics.mediaCardHeight)
        .lockScreenGlass(
            in: RoundedRectangle(cornerRadius: LockScreenPillMetrics.mediaCardCornerRadius,
                                 style: .continuous))
    }

    /// Apple's lock-screen player keeps the elapsed/remaining labels on the
    /// same horizontal line as the progress track. Keeping the labels beside
    /// the track prevents the old three-row stack from pushing the transport
    /// controls into the card's bottom edge on smaller displays.
    @ViewBuilder
    private func progressRow(for state: NowPlayingState) -> some View {
        if state.isPlaying {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                progressRowBody(for: state, at: timeline.date)
            }
        } else {
            progressRowBody(for: state, at: Date())
        }
    }

    @ViewBuilder
    private func progressRowBody(for state: NowPlayingState, at date: Date) -> some View {
        let elapsed = nowPlaying.currentElapsed(at: date) ?? state.elapsed ?? 0
        if let duration = state.duration, duration > 0 {
            let boundedElapsed = min(max(elapsed, 0), duration)
            HStack(spacing: 7) {
                Text(timeLabel(boundedElapsed))
                    .frame(width: 31, alignment: .leading)
                progressTrack(duration: duration, elapsed: boundedElapsed)
                Text("-\(timeLabel(max(duration - boundedElapsed, 0)))")
                    .frame(width: 35, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(height: 12)
        } else {
            Capsule()
                .fill(Color.primary.opacity(0.24))
                .frame(height: 3)
        }
    }

    private func progressTrack(duration: TimeInterval, elapsed: TimeInterval) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.24))
                Capsule()
                    .fill(Color.primary.opacity(0.9))
                    .frame(width: geometry.size.width * elapsed / duration)
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func auxiliaryPills(_ pills: [LockScreenPillKind]) -> some View {
        HStack(spacing: NotchDesign.space2) {
            ForEach(Array(pills.enumerated()), id: \.offset) { _, pill in
                switch pill {
                case .nowPlaying:
                    EmptyView()
                case .activity:
                    if let current = activities.current, let caption = current.captionText {
                        LockScreenActivityPill(systemName: Self.iconName(from: current.leading),
                                                caption: caption)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: LockScreenPillMetrics.auxiliaryPillHeight)
    }

    @ViewBuilder
    private var artwork: some View {
        if let artwork = nowPlaying.artwork {
            Image(nsImage: artwork)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: LockScreenPillMetrics.artworkSide,
                       height: LockScreenPillMetrics.artworkSide)
                .clipShape(RoundedRectangle(cornerRadius: LockScreenPillMetrics.artworkRadius,
                                            style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: LockScreenPillMetrics.artworkRadius,
                             style: .continuous)
                .fill(Color.primary.opacity(0.12))
                .frame(width: LockScreenPillMetrics.artworkSide,
                       height: LockScreenPillMetrics.artworkSide)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary))
        }
    }

    private func transportRow(for state: NowPlayingState) -> some View {
        HStack(spacing: 24) {
            transportButton("backward.end.fill", label: "Previous track", command: .previous)
            transportButton(state.isPlaying ? "pause.fill" : "play.fill",
                            label: state.isPlaying ? "Pause" : "Play",
                            command: .togglePlayPause,
                            prominent: true)
            transportButton("forward.end.fill", label: "Next track", command: .next)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func transportButton(_ systemName: String,
                                  label: String,
                                  command: NowPlayingCommand,
                                  prominent: Bool = false) -> some View {
        Button { onCommand(command) } label: {
            if prominent {
                Image(systemName: systemName)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(prominentControlForeground)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(.primary))
            } else {
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func timeLabel(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded(.down)), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func iconName(from content: LiveActivity.Content) -> String? {
        switch content {
        case .icon(let name), .iconText(let name, _), .gauge(_, let name):
            return name
        case .none, .text, .artwork:
            return nil
        }
    }
}

/// Uses Apple's Liquid Glass compositor on a real macOS 26 lock screen when
/// the app is built with the macOS 26 SDK. The release runner still builds
/// against the macOS 15 SDK, so the newer symbol is isolated behind a compiler
/// check and older builds retain the same native translucent material surface.
/// The off-screen snapshot harness has no wallpaper/backdrop to lens and uses
/// that material fallback deliberately to keep visual review honest.
private struct LockScreenGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    @ViewBuilder
    func body(content: Content) -> some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *), !isSnapshotRender {
            content
                .glassEffect(.regular, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.14), lineWidth: 0.5))
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.14), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.20), radius: 14, y: 6)
        }
#else
        content
            .background(.regularMaterial, in: shape)
            .overlay(shape.stroke(Color.primary.opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.20), radius: 14, y: 6)
#endif
    }
}

private extension View {
    func lockScreenGlass<S: Shape>(in shape: S) -> some View {
        modifier(LockScreenGlassModifier(shape: shape))
    }
}

/// The live-activity caption pill: an icon (when the activity carries one)
/// plus its plain-text caption. It stays visually subordinate to the media
/// surface and is kept in the same centered widget lane.
private struct LockScreenActivityPill: View {
    let systemName: String?
    let caption: String

    var body: some View {
        HStack(spacing: NotchDesign.space2) {
            if let systemName {
                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.12)))
            }
            Text(caption)
                .font(NotchDesign.bodyFont)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, NotchDesign.space3)
        .frame(height: LockScreenPillMetrics.auxiliaryPillHeight)
        .lockScreenGlass(in: Capsule())
    }
}
