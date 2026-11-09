import AppKit
import SwiftUI

/// Shared helpers for the notch widget controllers.
@MainActor
enum NotchWidgetStyle {
    /// Minutes and seconds, or hours when needed. Negative and non-finite values read as 0:00.
    static func clock(_ seconds: TimeInterval) -> String {
        let bounded = seconds.isFinite ? min(max(0, seconds), Double(Int32.max)) : 0
        let total = Int(bounded.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Hosts one widget's SwiftUI content outside the notch, for example in a
/// fixture render. The notch itself uses `NotchContentProviding` directly.
@MainActor
enum NotchWidgetHost {
    /// The content area of the 0.21.35 expanded shell over a 180 pt notch.
    static let standaloneSize = CGSize(width: NotchMetrics.expandedWidth(for: 180) - 32,
                                       height: NotchMetrics.maxExpandedHeight - 32 - 14)

    static func make(_ content: AnyView) -> NSView {
        let view = NSHostingView(rootView: AnyView(content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .environment(\.colorScheme, .dark)))
        view.appearance = NSAppearance(named: .darkAqua)
        view.frame = NSRect(origin: .zero, size: standaloneSize)
        return view
    }
}
