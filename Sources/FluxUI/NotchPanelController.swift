import AppKit
import FluxCore
import QuartzCore

extension Widget {
    var displayName: String {
        switch self {
        case .nowPlaying: L("notch.nowPlaying", "Now Playing")
        case .shelf: L("notch.shelf", "File Shelf")
        case .calendar: L("notch.calendar", "Calendar")
        case .mirror: L("notch.mirror", "Mirror")
        case .clipboard: L("notch.clipboard", "Clipboard")
        }
    }
}

/// Pure geometry for the notch panel. The parent passes screen values it read
/// from `NSScreen` (`frame`, `auxiliaryTopLeftArea`, `auxiliaryTopRightArea`).
/// On a display without a notch, `cameraWidth` is zero.
public struct NotchGeometry: Equatable, Sendable {
    public static let wingExtent: CGFloat = 40
    public static let maximumExpandedWidth: CGFloat = 440

    public var screenFrame: CGRect
    /// Width of the camera housing. Zero when the display has no notch.
    public var cameraWidth: CGFloat
    /// Height of the menu bar area that holds the notch.
    public var topInset: CGFloat

    public init(screenFrame: CGRect, cameraWidth: CGFloat, topInset: CGFloat) {
        self.screenFrame = screenFrame
        self.cameraWidth = max(0, cameraWidth)
        self.topInset = max(0, topInset)
    }

    /// Builds geometry from the two auxiliary areas beside the notch.
    public init(screenFrame: CGRect, topLeftArea: CGRect?, topRightArea: CGRect?, menuBarHeight: CGFloat) {
        if let left = topLeftArea, let right = topRightArea {
            self.init(screenFrame: screenFrame, cameraWidth: right.minX - left.maxX, topInset: max(left.height, right.height))
        } else {
            self.init(screenFrame: screenFrame, cameraWidth: 0, topInset: menuBarHeight)
        }
    }

    public var hasNotch: Bool { cameraWidth > 0 }

    /// The camera area. Content never goes here.
    public var cameraRect: CGRect {
        CGRect(x: screenFrame.midX - cameraWidth / 2, y: screenFrame.maxY - topInset, width: cameraWidth, height: topInset)
    }

    /// Compact state: the notch plus up to 40 pt on each side.
    public func wingRect(extent: CGFloat = NotchGeometry.wingExtent) -> CGRect {
        let side = min(max(0, extent), NotchGeometry.wingExtent)
        let width = cameraWidth + side * 2
        return CGRect(x: screenFrame.midX - width / 2, y: screenFrame.maxY - topInset, width: width, height: topInset)
    }

    /// Expanded state, up to 440 pt wide and never wider than the screen.
    public func expandedRect(contentHeight: CGFloat) -> CGRect {
        let width = min(NotchGeometry.maximumExpandedWidth, screenFrame.width)
        let height = topInset + max(0, contentHeight)
        return CGRect(x: screenFrame.midX - width / 2, y: screenFrame.maxY - height, width: width, height: height)
    }
}
