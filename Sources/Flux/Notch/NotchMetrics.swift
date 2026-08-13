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

    /// Alcove's width-to-height guide: 2.1:1 — 420x190 on the representative
    /// 200pt camera housing used by the snapshot suite.
    static let expandedAspectRatio: CGFloat = 2.1

    /// The shared Alcove drawer height. Every standard widget uses this same
    /// visible footprint so switching pages never causes a subtle vertical
    /// jump or leaves page-specific whitespace behind.
    static let maxExpandedHeight: CGFloat = 190

    /// The extra width used by Alcove's side-by-side Now Playing + Calendar
    /// layout. Duo is the one intentional two-pane exception to the standard
    /// single-widget footprint.
    static let duoExtraWidth: CGFloat = 220

    /// The expanded width from the Alcove guide. The minimum keeps the drawer
    /// usable on machines whose reported notch is narrower than the reference.
    static func expandedWidth(for notchWidth: CGFloat, style: NotchStyle = .alcove) -> CGFloat {
        max(notchWidth * expandedAspectRatio, 400)
    }

    /// Alcove reserves the tallest content height for every standard page.
    static func expandedHeight(for notchWidth: CGFloat, style: NotchStyle = .alcove) -> CGFloat {
        maxExpandedHeight
    }

    /// The visible height for one widget. The old implementation returned a
    /// different value for each widget, which made the notch visibly resize as
    /// pages changed. Content is now allowed to be compact inside one stable
    /// Alcove envelope; Duo remains intentionally wider because it is a
    /// two-pane layout.
    static func expandedHeight(for _: WidgetID,
                               notchWidth: CGFloat,
                               style: NotchStyle = .alcove) -> CGFloat {
        expandedHeight(for: notchWidth, style: style)
    }

    static func duoWidth(for notchWidth: CGFloat, style: NotchStyle = .alcove) -> CGFloat {
        expandedWidth(for: notchWidth, style: style)
            + (style == .alcove ? duoExtraWidth : 0)
    }

    static func duoHeight(for notchWidth: CGFloat, style: NotchStyle = .alcove) -> CGFloat {
        expandedHeight(for: notchWidth, style: style)
    }

    /// The share of the expanded panel's *content* width that Duo view gives
    /// its Calendar pane; Now Playing takes the rest.
    ///
    /// A fraction keeps both Duo panes balanced inside the dedicated wider
    /// two-pane layout.
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
    /// The envelope reserves the widest/tallest footprint of the selected
    /// style. Standard Alcove widgets now use the same visible height; Duo is
    /// intentionally wider because it contains two panes.
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
        CGSize(width: max(expandedWidth(for: notchWidth, style: style),
                          duoWidth(for: notchWidth, style: style)) + shadowMarginWidth,
               height: max(expandedHeight(for: notchWidth, style: style),
                           duoHeight(for: notchWidth, style: style)) + shadowMarginHeight)
    }
}
