import SwiftUI

/// The notch's silhouette.
///
/// A real notch housing isn't a plain rounded rectangle: the top edge is
/// flush and square (it's fused to the physical screen bezel, so rounding it
/// would look like a gap), but right where that top edge meets each top
/// corner there's a tiny concave "flare" — the outline hooks outward for a
/// few points before sweeping down into the housing, the way the bezel is
/// countersunk around the camera. The bottom two corners are ordinary convex
/// rounding, like any panel.
///
/// `topFlareRadius`/`bottomRadius` are both part of `animatableData`, so
/// `NotchRootView` can spring between the collapsed/activity/expanded corner
/// sets by animating this one shape rather than cross-fading three fixed
/// shapes (which would tear/pop instead of morphing).
struct NotchShape: Shape {
    var topFlareRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topFlareRadius, bottomRadius) }
        set {
            topFlareRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    init(topFlareRadius: CGFloat, bottomRadius: CGFloat) {
        self.topFlareRadius = topFlareRadius
        self.bottomRadius = bottomRadius
    }

    func path(in rect: CGRect) -> Path {
        // Clamp so a tiny collapsed rect (or a mid-spring overshoot past the
        // target value) never inverts a curve past the shape's own center.
        let half = min(rect.width, rect.height) / 2
        let top = min(max(topFlareRadius, 0), half)
        let bottom = min(max(bottomRadius, 0), half)

        var path = Path()

        // Flush top edge, inset by the flare radius on each side.
        path.move(to: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY))

        // Top-right flare: a cubic from the top edge to the right edge whose
        // control points sit close to the sharp outer corner (rather than
        // pulled toward the shape's interior, as a plain round corner would
        // be) — that bias is what reads as a concave "hook" instead of a
        // simple rounded corner.
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + top),
            control1: CGPoint(x: rect.maxX - top * 0.35, y: rect.minY),
            control2: CGPoint(x: rect.maxX, y: rect.minY + top * 0.35))

        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom))

        // Bottom-right: ordinary convex rounding, swept through the true
        // outer corner (increasing angle, counter-clockwise in SwiftUI's
        // y-down space, matches the standard rounded-rect corner idiom).
        path.addArc(center: CGPoint(x: rect.maxX - bottom, y: rect.maxY - bottom),
                    radius: bottom, startAngle: .degrees(0), endAngle: .degrees(90),
                    clockwise: false)

        path.addLine(to: CGPoint(x: rect.minX + bottom, y: rect.maxY))

        // Bottom-left: ordinary convex rounding.
        path.addArc(center: CGPoint(x: rect.minX + bottom, y: rect.maxY - bottom),
                    radius: bottom, startAngle: .degrees(90), endAngle: .degrees(180),
                    clockwise: false)

        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + top))

        // Top-left flare, mirrored.
        path.addCurve(
            to: CGPoint(x: rect.minX + top, y: rect.minY),
            control1: CGPoint(x: rect.minX, y: rect.minY + top * 0.35),
            control2: CGPoint(x: rect.minX + top * 0.35, y: rect.minY))

        path.closeSubpath()
        return path
    }
}

extension NotchShape {
    /// Collapsed: tight against the physical notch — small flare, tight
    /// bottom rounding.
    static let collapsed = NotchShape(topFlareRadius: 6, bottomRadius: 10)
    /// Activity: notch + wings — same flare, slightly softer bottom corners.
    static let activity = NotchShape(topFlareRadius: 6, bottomRadius: 14)
    /// Expanded: the full panel — same flare (it's still fused to the
    /// physical notch above it), generously rounded bottom.
    static let expanded = NotchShape(topFlareRadius: 6, bottomRadius: 24)
}
