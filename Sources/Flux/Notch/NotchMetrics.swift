import CoreGraphics

/// Shared sizing constants for the notch panel's collapsed/activity/expanded
/// footprints. Hoisted out of `NotchRootView` (which lays the shapes out) so
/// `NotchWindowController` (which sizes the *fixed* `NSPanel` those shapes
/// render inside — see its own doc comment on why the panel itself never
/// animates) and `NotchSnapshot` (which needs the same numbers to size its
/// off-screen capture window) can't drift out of sync with the SwiftUI side.
enum NotchMetrics {
    /// Width of each side "wing" shown around the blank physical-notch area
    /// while a live activity is current.
    static let wingWidth: CGFloat = 90

    /// Height of the expanded panel.
    static let expandedHeight: CGFloat = 280

    /// Width of the expanded panel for a given physical notch width — wide
    /// enough to clear the notch itself plus room for widget content, with a
    /// floor so a very narrow (or, in fixtures/tests, zero-width) notch still
    /// gets a sane-sized panel.
    static func expandedWidth(for notchWidth: CGFloat) -> CGFloat {
        max(notchWidth + 440, 600)
    }
}
