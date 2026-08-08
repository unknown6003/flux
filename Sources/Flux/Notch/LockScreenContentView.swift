import SwiftUI
import AppKit

/// Alcove-parity lock-screen content: the black notch silhouette plus, below
/// it, a live media surface, activity caption, and optional unlock pill.
/// `nowPlaying`/`activities` are `@ObservedObject`, so this view re-renders on
/// its own as tracks, artwork, battery captions, and activity expiry change.
///
/// The media surface is deliberately split from this safe base view. When
/// `showsMediaControls` is true, this view reserves the media card's space but
/// does not own its hit-testing; `LockScreenMediaControlsView` is hosted in a
/// small second panel by `LockScreenPresenter`. The rest of the lock-screen
/// surface remains mouse-transparent, so the password UI can never be blocked
/// by a decorative overlay.
struct LockScreenContentView: View {
    let notchSize: CGSize
    @ObservedObject var nowPlaying: NowPlayingService
    @ObservedObject var activities: LiveActivityCenter
    let allowNowPlaying: Bool
    let allowActivities: Bool
    let showUnlockPill: Bool
    let showsMediaControls: Bool

    var body: some View {
        VStack(spacing: NotchDesign.space2) {
            NotchShape.collapsed
                .fill(Color.black)
                .frame(width: max(notchSize.width, 1), height: max(notchSize.height, 8))

            // The interactive media card lives in a separate, tightly-sized
            // window. This clear spacer keeps the live activity/unlock pills
            // below it without making the safe base panel mouse-sensitive.
            if showsMediaControls,
               LockScreenMediaControlLogic.shouldShow(hasNowPlaying: nowPlaying.state != nil,
                                                       allowNowPlaying: allowNowPlaying) {
                Color.clear
                    .frame(height: LockScreenPillMetrics.mediaControlsHeight)
            }

            ForEach(Array(pills.enumerated()), id: \.offset) { _, pill in
                pillView(for: pill)
            }
        }
        // `maxHeight: .infinity` alongside `maxWidth` — `LockScreenPresenter`
        // gives this a fixed-height panel (`contentHeightBudget`, sized for
        // the silhouette plus all three pills), not a height that hugs this
        // stack's own intrinsic content. Without it, this frame only ever
        // expanded horizontally, so the stack centered vertically in
        // whatever extra height the panel had (fewer pills showing = more
        // slack) instead of staying pinned under the notch the way the
        // Alcove reference does; `alignment: .top` is what actually pins it
        // once the frame has real slack to place it within.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// What actually renders right now, computed fresh every body evaluation
    /// from the live `@ObservedObject` state — the pure derivation itself
    /// lives in `LockScreenPillLogic.visiblePills`, covered directly by
    /// `--selftest`.
    private var pills: [LockScreenPillKind] {
        LockScreenPillLogic.visiblePills(
            hasNowPlaying: nowPlaying.state != nil && !showsMediaControls,
            allowNowPlaying: allowNowPlaying,
            hasActivityCaption: activities.current?.captionText != nil,
            allowActivities: allowActivities,
            showUnlockPill: showUnlockPill)
    }

    @ViewBuilder
    private func pillView(for pill: LockScreenPillKind) -> some View {
        switch pill {
        case .nowPlaying:
            // `pills` already required `nowPlaying.state != nil` to include
            // this case — re-guarding here (rather than force-unwrapping)
            // costs nothing and keeps this function safe to call on its own.
            if let state = nowPlaying.state {
                LockScreenMediaPill(artwork: nowPlaying.artwork, title: state.title, artist: state.artist)
            }
        case .activity:
            if let current = activities.current, let caption = current.captionText {
                LockScreenActivityPill(systemName: Self.iconName(from: current.leading), caption: caption)
            }
        case .unlock:
            LockScreenUnlockPill()
        }
    }

    /// The wing icon to caption the activity pill with — mirrors
    /// `LiveActivity.captionText`'s own "prefer trailing, fall back to
    /// leading" text search, but for the icon half: every existing producer
    /// (battery, Bluetooth, calendar, timer, HUD) puts its glyph on
    /// `leading`, so that's read first; `trailing` is checked too only in
    /// case some future producer flips the convention. `nil` (no icon, just
    /// the caption text) for anything that carries no icon on either side.
    private static func iconName(from content: LiveActivity.Content) -> String? {
        switch content {
        case .icon(let name), .iconText(let name, _), .gauge(_, let name):
            return name
        case .none, .text, .artwork:
            return nil
        }
    }
}

/// The three kinds of pill this view can show, in the fixed stacking order
/// `LockScreenPillLogic.visiblePills` always returns them in (Now Playing,
/// then the activity caption, then the unlock pill) — matching the Alcove
/// reference's own ordering (media first, notifications below it, the
/// unlock affordance last, closest to where the user's eye lands after
/// glancing at the clock).
enum LockScreenPillKind: Equatable {
    case nowPlaying
    case activity
    case unlock
}

/// Pure derivation of which pills should be visible — extracted so
/// `--selftest` can exercise the full on/off matrix without a real
/// `NowPlayingService`/`LiveActivityCenter`/lock session. Order is fixed
/// (see `LockScreenPillKind`'s own doc comment); this only ever decides
/// inclusion, never re-orders.
enum LockScreenPillLogic {
    static func visiblePills(hasNowPlaying: Bool, allowNowPlaying: Bool,
                              hasActivityCaption: Bool, allowActivities: Bool,
                              showUnlockPill: Bool) -> [LockScreenPillKind] {
        var pills: [LockScreenPillKind] = []
        if hasNowPlaying && allowNowPlaying {
            pills.append(.nowPlaying)
        }
        if hasActivityCaption && allowActivities {
            pills.append(.activity)
        }
        if showUnlockPill {
            pills.append(.unlock)
        }
        return pills
    }
}

/// Pure gating for the companion interactive card — kept separate from the
/// pill allow-list so `--selftest` can verify that a missing track never leaves
/// an invisible mouse-sensitive panel behind.
enum LockScreenMediaControlLogic {
    static func shouldShow(hasNowPlaying: Bool, allowNowPlaying: Bool) -> Bool {
        hasNowPlaying && allowNowPlaying
    }
}

// MARK: - Pills
//
// Glass capsules with a dark tint and a small top highlight. The tint keeps
// lock-screen wallpaper from reducing contrast while the material lets these
// read as part of the wallpaper rather than as flat black stickers.

enum LockScreenPillMetrics {
    static let horizontalPadding: CGFloat = NotchDesign.space3
    static let verticalPadding: CGFloat = NotchDesign.space2
    static let maxWidth: CGFloat = 260
    /// The media pill's artwork tile — sized and radiused independently of
    /// `NotchDesign.artRadius` (13pt, the much larger 56pt expanded-panel
    /// tile): a proportionally smaller radius reads correctly at this much
    /// smaller size, the same "own constant, not a borrowed one" reasoning
    /// `FlippingArtwork`'s `side`/`cornerRadius` already documents for its
    /// own (different) fixed size.
    static let artworkSide: CGFloat = 18
    static let artworkRadius: CGFloat = 4
    /// Fixed height reserved by the safe base panel for the interactive media
    /// card hosted in the companion overlay window.
    static let mediaControlsHeight: CGFloat = 94
    static let mediaControlsWidth: CGFloat = 280
}

/// The Now Playing pill: artwork + title/artist, truncated (never marquee —
/// there's no interaction on the lock screen to make a scrolling reveal
/// meaningful, and per the build spec this is deliberately simpler than
/// `NowPlayingExpandedView`'s `MarqueeText`).
private struct LockScreenMediaPill: View {
    let artwork: NSImage?
    let title: String
    let artist: String?

    var body: some View {
        HStack(spacing: NotchDesign.space2) {
            artworkView
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(NotchDesign.bodyFont)
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let artist, !artist.isEmpty {
                    Text(artist)
                        .font(NotchDesign.captionFont)
                        .foregroundStyle(Color.white.opacity(NotchDesign.secondaryOpacity))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, LockScreenPillMetrics.horizontalPadding)
        .padding(.vertical, LockScreenPillMetrics.verticalPadding)
        // No `.frame(maxWidth:)` here: a maxWidth frame EXPANDS to
        // min(proposal, max) regardless of content size, which stretched
        // every pill to a near-panel-width black bar (snapshot-verified).
        // Intrinsic sizing + the panel's own width proposal caps long titles
        // (Text truncates); `maxWidth` in the metrics is now only the text
        // column's cap below.
        .notchGlass(Capsule(), tint: Color.black.opacity(0.46))
    }

    @ViewBuilder
    private var artworkView: some View {
        let side = LockScreenPillMetrics.artworkSide
        if let artwork {
            Image(nsImage: artwork)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: LockScreenPillMetrics.artworkRadius, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: LockScreenPillMetrics.artworkRadius, style: .continuous)
                .fill(Color.white.opacity(0.12))
                .frame(width: side, height: side)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.white.opacity(NotchDesign.tertiaryOpacity))
                )
        }
    }
}

/// A compact, iOS-style transport card for the lock screen. It is hosted in a
/// separate, tightly-sized panel by `LockScreenPresenter`, so its buttons are
/// the only lock-screen pixels that accept mouse events. The service remains
/// the single source of truth; this view only translates taps into the same
/// `NowPlayingCommand` values used by the full notch player.
struct LockScreenMediaControlsView: View {
    @ObservedObject var nowPlaying: NowPlayingService
    let onCommand: (NowPlayingCommand) -> Void

    var body: some View {
        Group {
            if let state = nowPlaying.state {
                VStack(spacing: 6) {
                    header(for: state)
                    progress(for: state)
                    transportRow(for: state)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(width: LockScreenPillMetrics.mediaControlsWidth,
                       height: LockScreenPillMetrics.mediaControlsHeight)
                .notchGlass(
                    RoundedRectangle(cornerRadius: 24, style: .continuous),
                    tint: Color.black.opacity(0.44))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Now Playing")
            } else {
                Color.clear
                    .frame(width: LockScreenPillMetrics.mediaControlsWidth,
                           height: LockScreenPillMetrics.mediaControlsHeight)
            }
        }
    }

    private func header(for state: NowPlayingState) -> some View {
        HStack(spacing: 9) {
            artwork
            VStack(alignment: .leading, spacing: 1) {
                Text(state.title)
                    .font(NotchDesign.bodyFont)
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let artist = state.artist, !artist.isEmpty {
                    Text(artist)
                        .font(NotchDesign.captionFont)
                        .foregroundStyle(Color.white.opacity(NotchDesign.secondaryOpacity))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: state.isPlaying ? "waveform" : "pause")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(NotchDesign.tertiaryOpacity))
                .accessibilityHidden(true)
        }
        .frame(height: 28)
    }

    @ViewBuilder
    private var artwork: some View {
        if let artwork = nowPlaying.artwork {
            Image(nsImage: artwork)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.12))
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(NotchDesign.tertiaryOpacity))
                )
        }
    }

    @ViewBuilder
    private func progress(for state: NowPlayingState) -> some View {
        if let duration = state.duration, duration > 0 {
            if state.isPlaying {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    progressTrack(duration: duration, at: timeline.date)
                }
            } else {
                progressTrack(duration: duration, at: Date())
            }
        } else {
            Capsule()
                .fill(Color.white.opacity(NotchDesign.hairlineOpacity))
                .frame(height: 2)
        }
    }

    private func progressTrack(duration: TimeInterval,
                               at date: Date) -> some View {
        let elapsed = min(max(nowPlaying.currentElapsed(at: date) ?? 0, 0), duration)
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule()
                    .fill(Color.white.opacity(0.86))
                    .frame(width: geometry.size.width * elapsed / duration)
            }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }

    private func transportRow(for state: NowPlayingState) -> some View {
        HStack(spacing: 17) {
            transportButton("backward.fill", label: "Previous track", command: .previous)
            transportButton(state.isPlaying ? "pause.fill" : "play.fill",
                            label: state.isPlaying ? "Pause" : "Play",
                            command: .togglePlayPause,
                            prominent: true)
            transportButton("forward.fill", label: "Next track", command: .next)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func transportButton(_ systemName: String,
                                  label: String,
                                  command: NowPlayingCommand,
                                  prominent: Bool = false) -> some View {
        Button { onCommand(command) } label: {
            Image(systemName: systemName)
                .font(.system(size: prominent ? 16 : 14,
                              weight: prominent ? .semibold : .medium))
                .frame(width: prominent ? 34 : 30, height: 26)
        }
        .buttonStyle(NotchGlassButtonStyle(prominent: prominent))
        .accessibilityLabel(label)
    }
}

/// The live-activity caption pill: an icon (when the activity carries one)
/// plus its plain-text caption — monochrome, matching every other lock-
/// screen pill.
private struct LockScreenActivityPill: View {
    let systemName: String?
    let caption: String

    var body: some View {
        HStack(spacing: NotchDesign.space1) {
            if let systemName {
                Image(systemName: systemName)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(NotchDesign.secondaryOpacity))
            }
            Text(caption)
                .font(NotchDesign.captionFont)
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, LockScreenPillMetrics.horizontalPadding)
        .padding(.vertical, NotchDesign.space1)
        // Intrinsic width, same reasoning as the media pill above.
        .notchGlass(Capsule(), tint: Color.black.opacity(0.46))
    }
}

/// The Alcove hero-shot pill: a padlock glyph plus a localizable "Press any
/// key to unlock" line. Static text, no live state to observe — unlike the
/// two pills above, this one never changes shape once shown.
private struct LockScreenUnlockPill: View {
    /// `String(localized:)` rather than a bare literal — this codebase has no
    /// `.strings` catalog yet (every other UI string here is a plain
    /// literal), but this specific line is the one the build spec calls out
    /// as needing to be localizable, and `String(localized:)` costs nothing
    /// today (it falls back to the key itself with no catalog present) while
    /// being the correct seam if/when localization is ever added.
    private static let label = String(localized: "Press any key to unlock")

    var body: some View {
        HStack(spacing: NotchDesign.space1) {
            Image(systemName: "lock.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(NotchDesign.secondaryOpacity))
            Text(Self.label)
                .font(NotchDesign.captionFont)
                .foregroundStyle(Color.white.opacity(NotchDesign.secondaryOpacity))
        }
        .padding(.horizontal, LockScreenPillMetrics.horizontalPadding)
        .padding(.vertical, NotchDesign.space1)
        .notchGlass(Capsule(), tint: Color.black.opacity(0.46))
    }
}
