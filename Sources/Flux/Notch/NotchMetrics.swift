import CoreGraphics

/// Shared sizing constants for the notch panel's collapsed/activity/expanded
/// footprints. Hoisted out of `NotchRootView` (which lays the shapes out) so
/// `NotchWindowController` (which sizes the *fixed* `NSPanel` those shapes
/// render inside — see its own doc comment on why the panel itself never
/// animates) and `NotchSnapshot` (which needs the same numbers to size its
/// off-screen capture window) can't drift out of sync with the SwiftUI side.
///
/// The canonical Alcove drawer uses one stable visible footprint for every
/// standard widget. The fixed window envelope means AppKit never has to
/// animate or resize an `NSPanel` as pages change.
enum NotchMetrics {
    /// Width of each side "wing" shown around the blank physical-notch area
    /// while a live activity is current.
    static let wingWidth: CGFloat = 90

    /// The smallest Alcove drawer width. It only applies to unusually narrow
    /// simulated/notched displays; normal hardware derives its width from the
    /// physical notch and the two Alcove wings below.
    static let minimumExpandedWidth: CGFloat = 328

    /// Alcove's stable visible height. Every page, including Duo, uses this
    /// same shell; content adapts inside it rather than resizing the notch.
    static let maxExpandedHeight: CGFloat = 164

    /// The exact shared Alcove width: physical notch plus one wing on each
    /// side. Activity and expanded states therefore have one identical
    /// horizontal footprint; only their content/height changes.
    static func expandedWidth(for notchWidth: CGFloat, style: NotchStyle = .alcove) -> CGFloat {
        max(notchWidth + wingWidth * 2, minimumExpandedWidth)
    }

    /// Alcove reserves the tallest content height for every standard page.
    static func expandedHeight(for notchWidth: CGFloat, style: NotchStyle = .alcove) -> CGFloat {
        maxExpandedHeight
    }

    /// The visible height for one widget. The old implementation returned a
    /// different value for each widget, which made the notch visibly resize as
    /// pages changed. Content is now allowed to be compact inside one stable
    /// Alcove envelope; Duo is composed responsively inside that same shell.
    static func expandedHeight(for _: WidgetID,
                               notchWidth: CGFloat,
                               style: NotchStyle = .alcove) -> CGFloat {
        expandedHeight(for: notchWidth, style: style)
    }

    static func duoWidth(for notchWidth: CGFloat, style: NotchStyle = .alcove) -> CGFloat {
        // Duo is an internal composition, not a different shell size.
        expandedWidth(for: notchWidth, style: style)
    }

    static func duoHeight(for notchWidth: CGFloat, style: NotchStyle = .alcove) -> CGFloat {
        expandedHeight(for: notchWidth, style: style)
    }

    /// The share of the expanded panel's *content* width that Duo view gives
    /// its Calendar pane; Now Playing takes the rest.
    ///
    /// A fraction keeps both Duo panes balanced inside the shared shell.
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
    /// The envelope reserves the one stable Alcove footprint plus shadow bleed.
    /// Duo deliberately does not widen it: its two panes are responsive inside
    /// the same shell as every other page.
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
    static func panelBounds(for notchWidth: CGFloat, style: NotchStyle = .alcove) -> CGSize {
        CGSize(width: expandedWidth(for: notchWidth, style: style) + shadowMarginWidth,
               height: expandedHeight(for: notchWidth, style: style) + shadowMarginHeight)
    }
}
