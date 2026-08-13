import CoreGraphics

/// Shared sizing constants for the notch panel's collapsed/activity/expanded
/// footprints. Hoisted out of `NotchRootView` (which lays the shapes out) so
/// `NotchWindowController` (which sizes the *fixed* `NSPanel` those shapes
/// render inside — see its own doc comment on why the panel itself never
/// animates) and `NotchSnapshot` (which needs the same numbers to size its
/// off-screen capture window) can't drift out of sync with the SwiftUI side.
///
/// ## M12: ONE expanded size, for every widget
/// M7 made the panel size itself to each widget's content — a per-`WidgetID`
/// height between 150 and 190pt, plus a 220pt widening whenever Duo view was
/// active. The intent was Alcove-like compactness; the effect was a drawer
/// that visibly grew and shrank every time you swiped between pages, and
/// jumped wider whenever Now Playing happened to be showing beside Calendar.
/// That reads as restless, and it isn't what Alcove actually does.
///
/// There is now a single expanded footprint. Widgets adapt to the box; the
/// box never adapts to the widget. The per-widget height function is gone
/// entirely rather than deprecated — `expandedHeight` now takes a notch
/// width, so it is not *possible* to ask for "the Calendar panel's height".
enum NotchMetrics {
    /// Width of each side "wing" shown around the blank physical-notch area
    /// while a live activity is current.
    static let wingWidth: CGFloat = 90

    /// The expanded panel's width-to-height ratio: 2.1:1 — 360x171 on a
    /// current MacBook. This is the compact Alcove-sized footprint; the
    /// shadow margin below is not visible UI.
    ///
    /// Arrived at by rendering, not by taste. M12 shipped 2.35 at 500 wide,
    /// which was both too wide against the notch (2.5x its width reads as a
    /// separate panel sitting near it) and too deep. Correcting the width to
    /// 400 while keeping 2.2 gave 182, and the snapshot showed Now Playing's
    /// transport row clipped against the bottom edge — 182 minus the notch
    /// clearance and corner clearance leaves less usable height than the
    /// pre-M12 design's tallest widget had. 190 restores that, and is still
    /// 23pt shallower than what drew the complaint.
    static let expandedAspectRatio: CGFloat = 2.1

    /// The single expanded width. The multiplier keeps the panel proportional
    /// to the physical notch on hardware with an unusual one; the floor is
    /// what actually applies on every current MacBook, where a ~200pt notch
    /// puts the multiplied term at or below it.
    ///
    /// 2.0x/400 rather than M12's first pass at 2.4x/500. That was too wide
    /// against the notch it hangs from — two and a half times its width reads
    /// as a separate panel that happens to be near the notch, rather than a
    /// drawer pulled out of it — and, paired with a 2.35 ratio, too deep as
    /// well. The pre-M12 design sat at ~2.1x and never drew that complaint;
    /// the complaint was that the size *changed*, which is fixed
    /// independently by there being one size at all.
    static func expandedWidth(for notchWidth: CGFloat) -> CGFloat {
        max(notchWidth * 1.8, 360)
    }

    /// The single expanded height — derived from the width and
    /// `expandedAspectRatio` rather than stated independently, so the two can
    /// never drift. Rounded so the shape lands on whole points.
    ///
    /// Takes the notch width, NOT a `WidgetID`: there is no per-widget height
    /// any more, and this signature is what enforces that.
    static func expandedHeight(for notchWidth: CGFloat) -> CGFloat {
        (expandedWidth(for: notchWidth) / expandedAspectRatio).rounded()
    }

    /// The share of the expanded panel's *content* width that Duo view gives
    /// its Calendar pane; Now Playing takes the rest.
    ///
    /// A fraction rather than the old fixed 200pt, because with one fixed
    /// panel size Duo has to fit the box instead of growing it.
    ///
    /// 0.36, down from 0.42 when the panel was 100pt wider. Duo has to fit
    /// the one shared footprint rather than widen it, so the narrower panel
    /// has to come out of somewhere — and the Calendar pane degrades more
    /// gracefully (its rows wrap) than Now Playing's fixed artwork-plus-
    /// transport composition does.
    static let duoCalendarPaneFraction: CGFloat = 0.36

    /// Extra room reserved in the fixed panel/off-screen bounds — beyond the
    /// visible shape — purely so the expanded shape's drop shadow
    /// (`NotchRootView.shapeLayer`) has somewhere to bleed into. Without it
    /// the shadow is hard-clipped at the panel/window edge.
    /// `shadowMarginHeight` only needs to cover the bottom (the shape is
    /// top-anchored, so all the vertical margin lands below it, which is also
    /// where the shadow's own `y` offset pushes most of its bleed);
    /// `shadowMarginWidth` splits evenly left/right since the shape is
    /// horizontally centered.
    static let shadowMarginHeight: CGFloat = 28
    static let shadowMarginWidth: CGFloat = 48

    /// The fixed frame `NotchWindowController.position` sizes the real
    /// `NSPanel` to, and `NotchSnapshot` sizes its off-screen capture window
    /// to — the one expanded footprint plus the shadow's bleed margin.
    ///
    /// This got materially simpler in M12: it used to reserve the tallest
    /// widget's height *and* Duo's extra width, because either could apply
    /// depending on state. With a single expanded size there is exactly one
    /// footprint to reserve for.
    ///
    /// Growing these bounds needs no compensating change to how the shape is
    /// positioned: `NotchWindowController.position` derives the panel origin
    /// as `(notchRect.midX - bounds.width / 2, screen.maxY - bounds.height)`
    /// — the first term keeps the panel centered on the physical notch
    /// regardless of width, and the second keeps its *top* edge pinned to
    /// `screen.maxY` regardless of height (since `origin.y + bounds.height`
    /// always simplifies back to `screen.maxY`). Inside the panel,
    /// `NotchRootView`'s outer `.frame(alignment: .top)` does the same with
    /// plain SwiftUI alignment. So the margin surfaces entirely below, and
    /// symmetrically to either side of, the visible shape.
    static func panelBounds(for notchWidth: CGFloat) -> CGSize {
        CGSize(width: expandedWidth(for: notchWidth) + shadowMarginWidth,
               height: expandedHeight(for: notchWidth) + shadowMarginHeight)
    }
}
