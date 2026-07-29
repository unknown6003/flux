import SwiftUI

/// The notch's silhouette: a rounded rectangle with independently animatable
/// top and bottom corner radii, drawn with **continuous** (squircle)
/// curvature.
///
/// ## M12: this is now Apple's curve, not a hand-rolled one
/// The previous version built the path by hand — circular `addArc` corners at
/// the bottom, and a bespoke cubic at each top corner whose control points
/// were pulled to 35% toward the outer corner to suggest a "flare" where the
/// panel meets the bezel. Two problems. The bottom corners were true circular
/// arcs, so curvature jumped discontinuously from zero along the straight
/// edge to `1/r` at the tangent point — the hard corner Apple's design
/// language specifically avoids. And the top cubic wasn't a circular arc, a
/// squircle, or anything else with a name; at a 6pt radius it read as an
/// ill-defined smudge rather than an intentional detail.
///
/// `UnevenRoundedRectangle(style: .continuous)` is Apple's own implementation
/// of the corner they use everywhere from app icons to sheets, so this now
/// matches the platform by construction instead of approximating it. Both
/// radii stay in `animatableData`, so `NotchRootView` can still spring
/// between the collapsed/activity/expanded corner sets by morphing one shape
/// rather than cross-fading three.
///
/// The top radius is ZERO, and that is not an oversight. The panel's top edge
/// is fused to the physical notch, which is a cutout meeting the screen's own
/// top edge — square. Any rounding there leaves a sliver of desktop showing in
/// each top corner, which reads as the drawer floating slightly away from the
/// bezel instead of hanging off it. (An earlier pass set it to 6 and the
/// rendered snapshot showed exactly that.) The property stays animatable
/// rather than being deleted, so a future state that genuinely wants a
/// detached, floating panel can round its top without reworking the shape.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    init(topRadius: CGFloat, bottomRadius: CGFloat) {
        self.topRadius = topRadius
        self.bottomRadius = bottomRadius
    }

    func path(in rect: CGRect) -> Path {
        // Clamp so a tiny collapsed rect — or a mid-spring overshoot past the
        // target radius — can never ask for a corner larger than the shape
        // can contain. A continuous corner degenerates visibly before it
        // degenerates gracefully, so this is clamped here rather than left to
        // whatever the shape does with an over-large radius.
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
}

extension NotchShape {
    /// Collapsed: tight against the physical notch. The bottom radius sits
    /// close to the real housing's own rounding, so the idle shape disappears
    /// into it.
    static let collapsed = NotchShape(topRadius: 0, bottomRadius: 12)

    /// Activity: notch + wings — same top, a touch softer at the bottom, to
    /// signal something has opened without committing to the full panel.
    static let activity = NotchShape(topRadius: 0, bottomRadius: 18)

    /// Expanded: the full drawer. A generous bottom radius, which continuous
    /// curvature carries at this size without reading as a stadium — a
    /// circular arc at the same radius is exactly where the old shape looked
    /// worst.
    static let expanded = NotchShape(topRadius: 0, bottomRadius: 34)
}
