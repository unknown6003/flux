import CoreGraphics

/// Shared sizing constants for the notch panel's collapsed/activity/expanded
/// footprints. Hoisted out of `NotchRootView` (which lays the shapes out) so
/// `NotchWindowController` (which sizes the *fixed* `NSPanel` those shapes
/// render inside — see its own doc comment on why the panel itself never
/// animates) and `NotchSnapshot` (which needs the same numbers to size its
/// off-screen capture window) can't drift out of sync with the SwiftUI side.
///
/// M7 redesign (Alcove scale): the old panel was one constant 600pt-wide,
/// 280pt-tall block for every widget. The new panel is compact and sized
/// *per widget* — the visible `NotchShape` grows only as large as the active
/// widget actually needs (`expandedHeight(for:)`), not a single one-size-fits
/// all box. The fixed `NSPanel`/off-screen bounds still have to be bigger
/// than any single widget's footprint, though — see `panelBounds(for:)`.
enum NotchMetrics {
    /// Width of each side "wing" shown around the blank physical-notch area
    /// while a live activity is current.
    static let wingWidth: CGFloat = 90

    /// Extra width the *visible* expanded shape gains when Duo view (Now
    /// Playing + Calendar side by side — see `NotchViewModel.duoActive`) is
    /// showing: `NotchRootView.size(for:)` adds this on top of
    /// `expandedWidth(for:)` whenever the active widget is laid out as Duo.
    /// Also reserved in the *fixed panel bounds* below (`panelBounds(for:)`),
    /// same as every other widget's own footprint, so the panel/off-screen
    /// window never has to resize when Duo becomes active.
    static let duoExtraWidth: CGFloat = 220

    /// The tallest any single widget's expanded height (`expandedHeight(for:)`
    /// below) gets — the base the fixed panel bounds height derives from (see
    /// `panelBounds(for:)`). Individual widgets render shorter than this; the
    /// panel itself never resizes when the active widget changes.
    ///
    /// Derived from `expandedHeight(for:)` across every `WidgetID` rather than
    /// hand-maintained as a separate constant — a previous version duplicated
    /// this as `static let maxExpandedHeight: CGFloat = 190`, which happened
    /// to still be correct after `.nowPlaying`'s height was bumped to 185 only
    /// because 185 still came in under the hand-picked 190. That was luck, not
    /// a guarantee: the next widget height bump past 190 would have silently
    /// clipped against a stale constant nobody updated. Deriving it instead
    /// makes that whole class of bug impossible — this can never again
    /// disagree with the switch it's supposed to summarize.
    static var maxExpandedHeight: CGFloat {
        WidgetID.allCases.map { expandedHeight(for: $0) }.max() ?? 190
    }

    /// Width of the *visible* expanded shape for a given physical notch
    /// width — compact, Alcove-scale (≈2.1× the notch itself) rather than
    /// the old notch-width-plus-440-fixed-floor box. Widened further while
    /// Duo view is showing (see `duoExtraWidth`).
    static func expandedWidth(for notchWidth: CGFloat) -> CGFloat {
        max(notchWidth * 2.1, 400)
    }

    /// Height of the *visible* expanded shape, per widget — Alcove-style
    /// panels size to their content rather than reserving one constant
    /// height for every widget regardless of how little (Shelf) or how much
    /// (Calendar/Clipboard) it actually needs to show.
    static func expandedHeight(for widget: WidgetID) -> CGFloat {
        switch widget {
        // 185, not the original 165: the content stack (56pt art row + times/
        // track + transport + notch-clearing top padding) needs ~180pt — at
        // 165 the transport row clipped into the bottom corner radius,
        // verified via CI snapshot render.
        case .nowPlaying: return 185
        case .shelf: return 150
        case .mirror: return 170
        case .timers: return 185
        case .calendar: return 190
        case .clipboard: return 190
        }
    }

    /// Extra room reserved in the fixed panel/off-screen bounds — beyond the
    /// widest/tallest *visible* shape ever gets — purely so the expanded
    /// shape's drop shadow (`NotchRootView.shapeLayer`: radius 16, y offset 4)
    /// has somewhere to bleed into. Before this existed, `panelBounds`' width
    /// exactly equaled Duo's full-width footprint and its height exactly
    /// equaled `maxExpandedHeight` — zero margin on either axis — so the
    /// shadow was hard-clipped at the panel/window edge on the widest/tallest
    /// widget states. `shadowMarginHeight` only needs to cover the bottom
    /// (the shape is top-anchored — see `panelBounds(for:)`'s own doc comment
    /// — so all the vertical margin naturally lands below it, where the
    /// shadow's `y: 4` offset pushes most of its bleed anyway); the shadow's
    /// upward bleed above the shape has nowhere real to render regardless,
    /// since that's off the physical notch's own top edge. `shadowMarginWidth`
    /// splits evenly left/right since the shape is horizontally centered.
    static let shadowMarginHeight: CGFloat = 28
    static let shadowMarginWidth: CGFloat = 48

    /// The fixed frame `NotchWindowController.position` sizes the real
    /// `NSPanel` to, and `NotchSnapshot` sizes its off-screen capture window
    /// to — wide/tall enough to fit every widget's expanded footprint, Duo's
    /// widened state (Now Playing + Calendar side by side), *and* the
    /// expanded shadow's own bleed margin, so that frame never has to change
    /// size again once this milestone ships (only the SwiftUI `NotchShape`
    /// drawn inside it grows/shrinks — see both callers' own doc comments on
    /// why the panel itself never animates).
    ///
    /// This is deliberately wider/taller than any single `expandedWidth(for:)`
    /// / `expandedHeight(for:)` pair: the *visible* shape is centered inside
    /// these bounds at its own, smaller, per-widget size (see
    /// `NotchRootView.size(for:)` / `.rect(for:panelWidth:)`).
    ///
    /// Growing these bounds doesn't require any compensating change to how
    /// the shape is positioned: `NotchWindowController.position` derives the
    /// panel's origin as `(notchRect.midX - bounds.width / 2, screen.maxY -
    /// bounds.height)` — the first term keeps the panel horizontally centered
    /// on the physical notch regardless of `bounds.width`, and the second
    /// keeps the panel's *top* edge pinned to `screen.maxY` regardless of
    /// `bounds.height` (since `origin.y + bounds.height` always simplifies
    /// back to `screen.maxY`). Inside the panel, `NotchRootView`'s outer
    /// `.frame(alignment: .top)` centers the shape horizontally and pins it
    /// to the panel's top edge the same way, using plain SwiftUI alignment
    /// rather than bounds-derived math — so it too is unaffected by these
    /// margins growing. Net effect: the added margin surfaces entirely below
    /// (and, symmetrically, to either side of) the visible shape, exactly
    /// where the shadow needs it, with no change anywhere else required.
    static func panelBounds(for notchWidth: CGFloat) -> CGSize {
        CGSize(width: expandedWidth(for: notchWidth) + duoExtraWidth + shadowMarginWidth,
               height: maxExpandedHeight + shadowMarginHeight)
    }
}
