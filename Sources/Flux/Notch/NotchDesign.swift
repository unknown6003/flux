import SwiftUI

/// The notch UI's shared design language (Alcove-derived): the spacing,
/// typography, opacity, and radius tokens every widget under
/// `Sources/Flux/Notch/Widgets` consumes instead of hand-rolling its own
/// literals, plus the two view modifiers (`notchScrollFade`, `paneInsets`)
/// that keep scrollable content and side-by-side (Duo) panes visually
/// consistent across widgets.
///
/// Established during the M8 pass that fixed a batch of CI-snapshot-
/// confirmed layout bugs:
/// - bottom-clipped scroll content (Calendar/Timers/Clipboard's last row
///   clipping hard into the panel's 32pt bottom corner radius) — see
///   `notchScrollFade(edge:)` / `scrollFadeContentInset`.
/// - Calendar's agenda floating centered with dead margins instead of
///   leading-aligned — not a token, but the *reason* `contentPadding` here
///   is documented as chrome-supplied rather than something a widget
///   should re-apply: the bug was a missing leading-alignment frame, not a
///   padding token problem (see `CalendarWidget`'s `agenda`).
/// - Shelf's relative-age captions reading future tense ("in 0s") for
///   just-added items — not a token either; see `Formatters.age(from:to:)`.
/// - Timers' stock white `Stepper` clashing with the dark panel — not a
///   token; see `TimersWidget`'s custom stepper, which does reuse
///   `capsuleFill`/spacing tokens from here.
/// - cramped Duo-pane padding — see `paneInsets`.
///
/// Every token here is a plain, documented constant (or `Font`/`Color`
/// value) rather than a wrapper type — widgets apply them with the exact
/// same modifiers (`.padding`, `.font`, `.foregroundStyle`, ...) they'd use
/// for a literal, so adopting a token is always a same-shape substitution.
enum NotchDesign {

    // MARK: - Spacing

    /// Base 4pt spacing scale. Every widget's `VStack`/`HStack` spacing and
    /// padding literal should resolve to one of these four (or one of the
    /// semantic aliases just below) rather than an ad-hoc number.
    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16

    /// The gap between rows in a list (agenda rows, clipboard rows, timer
    /// rows, tile strips) — every widget's list already converged on this
    /// value independently; this is the one place they now share it.
    static let rowSpacing: CGFloat = space2
    /// The gap between stacked sections within one widget's body (header →
    /// content, content → divider, and so on).
    static let sectionSpacing: CGFloat = space3
    /// The panel's own edge padding. This is supplied by `NotchRootView`'s
    /// chrome (`ExpandedChrome.padding(.horizontal, 16)`), NOT re-applied
    /// inside a widget's own view — documented here only as the reference
    /// value `paneInsets` below is defined relative to, so the two can
    /// never silently drift apart.
    static let contentPadding: CGFloat = space4

    // MARK: - Typography

    /// A header's primary title — e.g. a Now Playing track title.
    static let titleFont = Font.system(size: 15, weight: .semibold)
    /// A row's primary line — event titles, clipboard previews, timer labels.
    static let bodyFont = Font.system(size: 12, weight: .medium)
    /// A row's secondary/supporting line.
    static let captionFont = Font.system(size: 11)
    /// A section header ("TODAY", "TOMORROW") — small, semibold, tracked out.
    static let microFont = Font.system(size: 9, weight: .semibold)

    /// Monospaced-digit variants, one per distinct existing use site rather
    /// than a single size — a countdown row, a scrubber's elapsed/remaining
    /// pair, a stepper's minutes label, and a calendar time range were each
    /// already sized differently on purpose (row prominence vs. an inline
    /// caption), so unifying them to one size would be a real visual
    /// regression, not a cleanup.
    static let monoDigitsCaption = Font.system(size: 10, design: .monospaced)
    static let monoDigitsBody = Font.system(size: 12, design: .monospaced)
    static let monoDigitsLarge = Font.system(size: 14, weight: .semibold, design: .monospaced)
    static let monoDigitsSmall = Font.system(size: 11).monospacedDigit()

    // MARK: - Opacity ramp

    /// Full-strength foreground — primary titles/labels.
    static let primaryOpacity: Double = 1.0
    /// Section headers, secondary row lines, hover-revealed row controls.
    static let secondaryOpacity: Double = 0.55
    /// Tertiary captions — timestamps, locations, ages.
    static let tertiaryOpacity: Double = 0.45
    /// Dim/disabled/empty-state iconography.
    static let quaternaryOpacity: Double = 0.3
    /// Hairline rules/dividers against the near-black panel background.
    static let hairlineOpacity: Double = 0.08

    // MARK: - Radii

    /// The expanded shape's own bottom corner radius (`NotchShape`) —
    /// tracked here only as a documentation reference for why
    /// `notchScrollFade`/`scrollFadeContentInset` exist, NOT redeclared or
    /// used as an actual corner radius by any widget (`NotchShape` remains
    /// the one place that draws it).
    static let panelRadius: CGFloat = 32
    /// Now Playing's artwork tile. Not applied by any view in this file's
    /// own scope — `FlippingArtwork` (`NowPlayingComponents.swift`) owns
    /// that clip shape and belongs to a different agent's files this pass;
    /// tracked here as the documented reference value regardless, so a
    /// future change to either side has something shared to check against.
    static let artRadius: CGFloat = 13
    /// Shelf's thumbnail tile.
    static let tileRadius: CGFloat = 8
    /// A list row's hover/selection background.
    static let rowRadius: CGFloat = 8
    /// The quiet white wash used to fill capsules/rows/buttons across the
    /// notch's near-monochrome surface (preset capsules, hover states, the
    /// `PermissionGatedView` action button, the custom stepper's buttons).
    static let capsuleFill = Color.white.opacity(0.14)

    // MARK: - Scroll fade (bottom-clipping fix)

    /// Which edge of a scrollable widget's content area fades to
    /// transparent. Bottom is the default — every vertical list (Calendar,
    /// Timers, Clipboard) was clipping its last row hard against the
    /// panel's 32pt bottom corner radius (`panelRadius`) instead of fading
    /// it out Alcove-style. Shelf's horizontal tile strip fades on its
    /// TRAILING edge instead — its corner curve reads left→right, so a
    /// leading fade would dim the very first tile for no reason.
    enum ScrollFadeEdge {
        case bottom
        case trailing
    }

    /// The fade's length — long enough to visibly soften the last row/tile
    /// before the corner radius, short enough not to dim more than the very
    /// end of the content.
    static let scrollFadeLength: CGFloat = 16

    /// The matching content inset a scrollable widget's inner stack should
    /// add on the SAME edge passed to `notchScrollFade(edge:)`, so the last
    /// row's actual content clears the fade zone rather than fading out from
    /// underneath it (which would look identical to just clipping again).
    static let scrollFadeContentInset: CGFloat = 10

    // MARK: - Pane insets (Duo-pane crowding fix)

    /// The extra edge padding a widget's expanded view applies on top of
    /// whatever chrome its host composes it into.
    ///
    /// `NotchRootView.ExpandedChrome` applies exactly ONE 16pt horizontal
    /// inset (`contentPadding`) around whichever content it hosts — a
    /// single widget's full-width panel, or, in Duo view, the WHOLE
    /// Now-Playing + Calendar `HStack` as one unit, with zero spacing
    /// around the divider in between. That means a widget composed as a
    /// Duo pane gets chrome's 16pt on its OUTER edge (the panel edge) but
    /// nothing at all on its INNER edge (the divider) — the crowding this
    /// token fixes.
    ///
    /// Applied symmetrically (both leading AND trailing) rather than only
    /// on the divider-facing edge, deliberately: `NowPlayingExpandedView`/
    /// `CalendarExpandedView` are the exact same view whether rendered solo
    /// or as a Duo pane, with no way to know which context they're in, so
    /// the fix has to look correct either way. A little extra breathing
    /// room beyond chrome's 16 on the solo panel's already-fine edges is a
    /// fair trade for a real gap at the divider in Duo — and staying
    /// symmetric means neither layout ever ends up lopsided.
    ///
    /// NOTE for the orchestrator: the more surgical fix — padding only the
    /// divider-facing edge of each pane — belongs in `NotchRootView.
    /// duoContent` (e.g. `.padding(.trailing, paneInsets)` on the Now
    /// Playing pane, `.padding(.leading, paneInsets)` on the Calendar pane,
    /// or padding added around the divider itself), which is that agent's
    /// file, not this one's. This token's symmetric application here is the
    /// safe fix available without touching it.
    static let paneInsets: CGFloat = space2
}

// MARK: - Scroll fade modifier

/// A fixed-length opaque→transparent mask on one edge of `content` — see
/// `NotchDesign.ScrollFadeEdge`/`scrollFadeLength` for why. Built as a
/// `VStack`/`HStack` of an opaque `Color.black` region plus a fixed-length
/// `LinearGradient` (rather than one gradient spanning the whole view) so
/// the fade's length stays constant regardless of how tall/wide the masked
/// content actually is — a `LinearGradient` alone, sized to the content via
/// unit points, would stretch the fade across the entire scroll area instead
/// of just its last 16pt.
private struct NotchScrollFadeMask: View {
    let edge: NotchDesign.ScrollFadeEdge

    var body: some View {
        switch edge {
        case .bottom:
            VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: NotchDesign.scrollFadeLength)
            }
        case .trailing:
            HStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: NotchDesign.scrollFadeLength)
            }
        }
    }
}

private struct NotchScrollFadeModifier: ViewModifier {
    let edge: NotchDesign.ScrollFadeEdge

    func body(content: Content) -> some View {
        content.mask(NotchScrollFadeMask(edge: edge))
    }
}

extension View {
    /// Bug fix: masks the trailing `scrollFadeLength` points of a scrollable
    /// widget's content area (bottom by default; `.trailing` for Shelf's
    /// horizontal strip) so the last row/tile fades out toward the panel's
    /// bottom corner radius instead of being hard-clipped by it. Apply to
    /// the `ScrollView` itself; pair with `NotchDesign.scrollFadeContentInset`
    /// as a matching content-side inset on the SAME edge inside the
    /// `ScrollView`'s own stack, so real content clears the fade zone rather
    /// than fading out from underneath it.
    func notchScrollFade(edge: NotchDesign.ScrollFadeEdge = .bottom) -> some View {
        modifier(NotchScrollFadeModifier(edge: edge))
    }
}
