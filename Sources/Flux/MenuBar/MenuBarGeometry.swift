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
}
