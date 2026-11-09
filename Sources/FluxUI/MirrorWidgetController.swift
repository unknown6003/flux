import AppKit
import FluxCore
import SwiftUI

public enum MirrorWidgetStatus: Equatable, Sendable {
    case starting
    case running
    /// The parent has not got Camera access. Nothing claims access is given.
    case needsPermission
    /// No camera.
    case unavailable
    /// Another app took the camera, or the system stopped it.
    case interrupted
    case failed
    /// macOS denied Camera access. The card offers System Settings.
    case denied
}

public enum MirrorWidgetAction: Equatable, Sendable {
    case requestPermission
    case openSettings
    case retry
}

/// The Mirror notch widget: the 0.21.35 SwiftUI mirror. It embeds a preview
/// view that the parent owns. It has no capture session of its own.
@MainActor
public final class MirrorWidgetController: NSViewController, NotchContentProviding {
    public static let cornerRadius: CGFloat = 16

    public private(set) var status: MirrorWidgetStatus
    let model: MirrorNotchModel

    public init(status: MirrorWidgetStatus = .starting, preview: NSView? = nil,
                onAction: @escaping @MainActor (MirrorWidgetAction) -> Void) {
        self.status = status
        model = MirrorNotchModel(status: status, preview: preview, onAction: onAction)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func loadView() {
        view = NotchWidgetHost.make(notchContent())
    }

    public func notchContent() -> AnyView { AnyView(MirrorExpandedView(model: model)) }

    /// Nil removes the preview, for example before the camera stops.
    public func setPreview(_ newPreview: NSView?) {
        guard model.preview !== newPreview else { return }
        model.preview = newPreview
    }

    public func update(_ newStatus: MirrorWidgetStatus) {
        guard newStatus != status else { return }
        status = newStatus
        model.status = newStatus
    }
}
