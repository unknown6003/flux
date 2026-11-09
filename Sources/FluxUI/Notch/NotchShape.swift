import CoreGraphics
import SwiftUI

// Ported from Flux 0.21.35: Sources/Flux/Notch/NotchShape.swift and
// Sources/Flux/Notch/NotchMetrics.swift. Values are unchanged.

/// The notch silhouette: square top corners flush with the screen edge and
/// continuous bottom corners. Both radii animate with the state spring.
public struct NotchShape: Shape {
    public var topRadius: CGFloat
    public var bottomRadius: CGFloat

    public var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    public init(topRadius: CGFloat, bottomRadius: CGFloat) {
        self.topRadius = topRadius
        self.bottomRadius = bottomRadius
    }

    public func path(in rect: CGRect) -> Path {
        let half = min(rect.width, rect.height) / 2
        let top = min(max(topRadius, 0), half)
        let bottom = min(max(bottomRadius, 0), half)
        return UnevenRoundedRectangle(
            topLeadingRadius: top,
            bottomLeadingRadius: bottom,
            bottomTrailingRadius: bottom,
            topTrailingRadius: top,
            style: .continuous
        ).path(in: rect)
    }

    public static let collapsed = NotchShape(topRadius: 0, bottomRadius: 12)
    public static let activity = NotchShape(topRadius: 0, bottomRadius: 18)
    public static let expanded = NotchShape(topRadius: 0, bottomRadius: 34)
}

/// The fixed notch sizes. Every widget shares one expanded footprint.
public enum NotchMetrics {
    public static let wingWidth: CGFloat = 90
    public static let minimumExpandedWidth: CGFloat = 328
    public static let maxExpandedHeight: CGFloat = 164
    public static let duoCalendarPaneFraction: CGFloat = 0.36
    public static let shadowMarginHeight: CGFloat = 28
    public static let shadowMarginWidth: CGFloat = 48

    public static func expandedWidth(for notchWidth: CGFloat) -> CGFloat {
        max(notchWidth + wingWidth * 2, minimumExpandedWidth)
    }

    public static func expandedHeight(for notchWidth: CGFloat) -> CGFloat {
        maxExpandedHeight
    }

    public static func duoWidth(for notchWidth: CGFloat) -> CGFloat {
        expandedWidth(for: notchWidth)
    }

    public static func duoHeight(for notchWidth: CGFloat) -> CGFloat {
        expandedHeight(for: notchWidth)
    }

    /// The fixed transparent panel: the expanded shell plus shadow room.
    public static func panelBounds(for notchWidth: CGFloat) -> CGSize {
        CGSize(width: expandedWidth(for: notchWidth) + shadowMarginWidth,
               height: expandedHeight(for: notchWidth) + shadowMarginHeight)
    }

    /// The physical notch in the panel's top-left coordinate space.
    public static func collapsedFrame(notchRect: CGRect, panelFrame: CGRect) -> CGRect {
        guard notchRect.width > 0, notchRect.height > 0,
              panelFrame.width > 0, panelFrame.height > 0 else { return .zero }
        let top = panelFrame.maxY - notchRect.maxY
        return CGRect(x: notchRect.minX - panelFrame.minX,
                      y: top,
                      width: notchRect.width,
                      height: notchRect.height)
    }
}
