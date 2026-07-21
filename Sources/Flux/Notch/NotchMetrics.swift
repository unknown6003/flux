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

    /// Extra width reserved in the *fixed panel bounds* (not the visible
    /// shape) for the upcoming Duo agent widget, which will widen the
    /// expanded shape beyond `expandedWidth(for:)` once it ships. Defined now
    /// — rather than added later as a breaking change to `panelBounds(for:)`
    /// — so the panel/off-screen window this milestone ships never has to be
    /// resized again just to make room for it.
    static let duoExtraWidth: CGFloat = 220

    /// The tallest any single widget's expanded height (`expandedHeight(for:)`
    /// below) gets — i.e. the fixed panel bounds height. Individual widgets
    /// render shorter than this; the panel itself is always exactly this
    /// tall so it never resizes when the active widget changes.
    static let maxExpandedHeight: CGFloat = 190

    /// Width of the *visible* expanded shape for a given physical notch
    /// width — compact, Alcove-scale (≈2.1× the notch itself) rather than
    /// the old notch-width-plus-440-fixed-floor box. Widened further, per
    /// widget, only once the Duo agent ships (see `duoExtraWidth`).
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

    /// The fixed frame `NotchWindowController.position` sizes the real
    /// `NSPanel` to, and `NotchSnapshot` sizes its off-screen capture window
    /// to — wide/tall enough to fit every widget's expanded footprint *and*
    /// the Duo agent's future widened state, so that frame never has to
    /// change size again once this milestone ships (only the SwiftUI
    /// `NotchShape` drawn inside it grows/shrinks — see both callers' own
    /// doc comments on why the panel itself never animates).
    ///
    /// This is deliberately wider/taller than any single `expandedWidth(for:)`
    /// / `expandedHeight(for:)` pair: the *visible* shape is centered inside
    /// these bounds at its own, smaller, per-widget size (see
    /// `NotchRootView.size(for:)` / `.rect(for:panelWidth:)`).
    static func panelBounds(for notchWidth: CGFloat) -> CGSize {
        CGSize(width: expandedWidth(for: notchWidth) + duoExtraWidth, height: maxExpandedHeight)
    }
}
