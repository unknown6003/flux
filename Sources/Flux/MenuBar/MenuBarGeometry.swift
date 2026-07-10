import AppKit

/// Notch- and menu-bar geometry helpers.
///
/// Everything Flux needs to reason about *where status items can physically live*
/// on a given screen. On Macs with a camera-housing notch that's only the strip to
/// the **right** of the notch — third-party status items can't cross or sit left of
/// it — so revealing more icons than fit there pushes the leftmost ones (and Flux's
/// own zone markers) out of sight behind the notch. These helpers let the engine
/// detect that and warn, instead of silently stranding a zone.
extension NSScreen {
    /// This screen's menu-bar strip height (correct on notched Macs too, where the
    /// bar is taller). Falls back to the system status-bar thickness.
    var menuBarThickness: CGFloat {
        max(frame.maxY - visibleFrame.maxY, NSStatusBar.system.thickness)
    }

    /// True when a camera-housing notch interrupts this screen's menu bar.
    var hasNotch: Bool {
        safeAreaInsets.top > 0
    }

    /// The region of the menu bar where third-party status items can actually be
    /// placed — the span to the **right** of the notch. On a screen without a notch
    /// this is the whole menu-bar strip. In global screen coordinates, so it can be
    /// compared directly against a status item's window frame.
    var statusItemRegion: NSRect {
        let barY = frame.maxY - menuBarThickness
        // `auxiliaryTopRightArea` is the usable menu-bar area to the right of the
        // notch; it's nil on non-notched screens, where the whole strip is usable.
        if let right = auxiliaryTopRightArea {
            return NSRect(x: right.minX, y: barY,
                          width: right.maxX - right.minX, height: menuBarThickness)
        }
        return NSRect(x: frame.minX, y: barY, width: frame.width, height: menuBarThickness)
    }

    /// This screen's camera-housing notch as a rectangle in the menu bar, or `nil`
    /// when the screen has no notch. Derived from the gap between the usable areas
    /// on either side of it: `auxiliaryTopLeftArea` ends at the notch's left edge and
    /// `auxiliaryTopRightArea` begins at its right edge. In global screen coordinates
    /// so it can position an overlay window directly over the notch.
    var notchRect: NSRect? {
        guard hasNotch,
              let left = auxiliaryTopLeftArea,
              let right = auxiliaryTopRightArea,
              right.minX > left.maxX else { return nil }
        return NSRect(x: left.maxX, y: frame.maxY - menuBarThickness,
                      width: right.minX - left.maxX, height: menuBarThickness)
    }

    /// Whether a status item with this window `frame` sits clear of the notch and
    /// will therefore actually render. macOS packs status items right-to-left from
    /// the clock; once they no longer fit in `statusItemRegion` the leftmost ones
    /// are pushed to (or past) the notch, where they're clipped out of sight even
    /// though their window frame and `isVisible` still read as placed. An item is
    /// clear when its left edge stays `slack` points right of the region's left
    /// edge — the notch's right edge on a notched Mac, the screen's left edge
    /// otherwise. A zero-width frame (macOS couldn't place it) never fits.
    func statusItemFitsBesideNotch(_ frame: NSRect, slack: CGFloat = 2) -> Bool {
        guard frame.width >= 1 else { return false }
        return frame.minX >= statusItemRegion.minX + slack
    }
}
