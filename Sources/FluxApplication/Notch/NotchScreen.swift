import AppKit

// Ported from Flux 0.21.35: Sources/Flux/MenuBar/MenuBarGeometry.swift
// (NotchScreenGeometry and the NSScreen notch helpers).

/// The physical camera housing, from the two menu-bar areas beside it.
public enum NotchScreenGeometry {
    /// AppKit's safe-area gap is a placement boundary, not the visible edge of
    /// the black housing. Two backing pixels per side keep the shell inside it.
    public static let collapsedSideInsetInPixels: CGFloat = 2

    public static func notchRect(frame: CGRect, safeAreaTop: CGFloat, menuBarThickness: CGFloat,
                                 leftArea: CGRect, rightArea: CGRect,
                                 backingScaleFactor: CGFloat = 1) -> CGRect? {
        guard rightArea.minX > leftArea.maxX else { return nil }
        let height = safeAreaTop > 0 ? safeAreaTop : menuBarThickness
        guard height > 0 else { return nil }
        let scale = backingScaleFactor > 0 ? backingScaleFactor : 1
        let measuredWidthInPixels = (rightArea.minX - leftArea.maxX) * scale
        let widthInPixels = max(measuredWidthInPixels.rounded(.down) - collapsedSideInsetInPixels * 2, 1)
        let centerInPixels = frame.midX * scale
        let minX = (centerInPixels - widthInPixels / 2) / scale
        return CGRect(x: minX, y: frame.maxY - height, width: widthInPixels / scale, height: height)
    }
}

extension NSScreen {
    var notchMenuBarThickness: CGFloat {
        max(frame.maxY - visibleFrame.maxY, NSStatusBar.system.thickness)
    }

    var hasPhysicalNotch: Bool { safeAreaInsets.top > 0 }

    /// The camera housing in screen coordinates, or nil without a notch.
    var physicalNotchRect: CGRect? {
        guard hasPhysicalNotch, let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea,
              right.minX > left.maxX else { return nil }
        return NotchScreenGeometry.notchRect(frame: frame, safeAreaTop: safeAreaInsets.top,
                                             menuBarThickness: notchMenuBarThickness,
                                             leftArea: left, rightArea: right,
                                             backingScaleFactor: backingScaleFactor)
    }

    var notchDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The built-in display with a notch. The notch shows only there.
    static var builtInNotchedScreen: NSScreen? {
        screens.first { $0.hasPhysicalNotch && $0.notchDisplayID.map { CGDisplayIsBuiltin($0) != 0 } == true }
    }
}
