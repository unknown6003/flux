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

    /// The expanded panel's width-to-height ratio.
    ///
    /// 2.35:1 is chosen, not inherited. Two constraints fix it: it has to be
    /// wide enough to seat Duo view (Now Playing beside Calendar) inside the
    /// *same* box every other widget gets — so Duo no longer needs a width of
    /// its own — and flat enough that a panel hanging off the notch still
    /// reads as a drawer rather than a window. The old effective ratio
    /// wandered between roughly 2.2:1 and 2.8:1 depending on which widget was
    /// showing, which is a large part of why the proportions looked arbitrary.
    static let expandedAspectRatio: CGFloat = 2.35

    /// The single expanded width. The `2.4 ×` term keeps the panel
    /// proportional to the physical notch on hardware with an unusual one;
    /// the floor is what actually applies on every current MacBook, where a
    /// ~200pt notch puts the multiplied term below it.
    static func expandedWidth(for notchWidth: CGFloat) -> CGFloat {
        max(notchWidth * 2.4, 500)
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
    /// panel size Duo has to fit the box instead of growing it — so its split
    /// has to scale with whatever that box is on the current hardware.
    static let duoCalendarPaneFraction: CGFloat = 0.42

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
