import SwiftUI
import AppKit

/// Alcove-parity lock-screen content: the black notch silhouette plus, below
/// it, up to three stacked pills — a Now Playing media pill, a live-activity
/// caption pill, and an optional "Press any key to unlock" pill. Genuinely
/// LIVE (unlike the M6 static silhouette this replaces): `nowPlaying`/
/// `activities` are `@ObservedObject`, so this view re-renders on its own the
/// instant either service's `@Published` state changes — a track change, a
/// battery percent tick, an activity expiring — with no timer, tracking area,
/// or button anywhere in this file. `LockScreenPresenter` only ever rebuilds
/// this view's plain `allow*`/`showUnlockPill` values (when the corresponding
/// settings change while locked); it never needs to re-derive nowPlaying/
/// activity CONTENT itself, since the `@ObservedObject` bindings already do
/// that.
///
/// Read-only, display-only, exactly like the view it replaces: no gesture,
/// no `Button`, no `onTapGesture` anywhere in this file or its pill subviews
/// — there is nothing on the lock screen for a click to do, and
/// `LockScreenPresenter.makePanel` additionally sets `ignoresMouseEvents`
/// unconditionally as defense in depth (see that function's own doc comment).
struct LockScreenContentView: View {
    let notchSize: CGSize
    @ObservedObject var nowPlaying: NowPlayingService
    @ObservedObject var activities: LiveActivityCenter
    let allowNowPlaying: Bool
    let allowActivities: Bool
    let showUnlockPill: Bool

    var body: some View {
        VStack(spacing: NotchDesign.space2) {
            NotchShape.collapsed
                .fill(Color.black)
                .frame(width: max(notchSize.width, 1), height: max(notchSize.height, 8))

            ForEach(Array(pills.enumerated()), id: \.offset) { _, pill in
                pillView(for: pill)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// What actually renders right now, computed fresh every body evaluation
    /// from the live `@ObservedObject` state — the pure derivation itself
    /// lives in `LockScreenPillLogic.visiblePills`, covered directly by
    /// `--selftest`.
    private var pills: [LockScreenPillKind] {
        LockScreenPillLogic.visiblePills(
            hasNowPlaying: nowPlaying.state != nil,
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

// MARK: - Pills
//
// Pure black capsules (not `NotchDesign.capsuleFill`'s translucent white
// wash — that's the ordinary notch panel's own material, not what Alcove's
// lock-screen pills use in the reference render this parity target is drawn
// from) with a white-opacity-ramp text/icon treatment, reusing
// `NotchDesign`'s spacing/typography/opacity tokens throughout so these read
// as the same design language as the rest of the notch suite, just on a
// solid rather than translucent fill.

private enum LockScreenPillMetrics {
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
}

private func lockScreenCapsule() -> some View {
    Capsule().fill(Color.black)
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
        .background(lockScreenCapsule())
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
        .background(lockScreenCapsule())
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
        .background(lockScreenCapsule())
    }
}
