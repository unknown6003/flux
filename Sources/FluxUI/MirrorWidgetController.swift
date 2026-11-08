import AppKit
import FluxCore

public enum MirrorWidgetStatus: Equatable, Sendable {
    case starting
    case running
    /// The parent has not got Camera access. Nothing claims access is given.
    case needsPermission
    /// No camera, or macOS denied access.
    case unavailable
    /// Another app took the camera, or the system stopped it.
    case interrupted
    case failed
}

public enum MirrorWidgetAction: Equatable, Sendable {
    case requestPermission
    case openSettings
    case retry
}

/// The Mirror notch widget. It embeds a preview view that the parent owns,
/// for example one backed by its camera layer, in a black rounded area.
/// It has no AVFoundation, capture session, frame capture or image cache.
@MainActor
public final class MirrorWidgetController: NSViewController {
    public static let cornerRadius: CGFloat = 16
    public static let previewHeight: CGFloat = 150

    public private(set) var status: MirrorWidgetStatus
    private let onAction: @MainActor (MirrorWidgetAction) -> Void
    private var preview: NSView?
    private let frameView = NSView()
    private let statusLabel = FluxUIStyle.label("", style: .caption1, secondary: true, wraps: true)
    private let card = NotchCardHost()

    public init(status: MirrorWidgetStatus = .starting, preview: NSView? = nil,
                onAction: @escaping @MainActor (MirrorWidgetAction) -> Void) {
        self.status = status
        self.preview = preview
        self.onAction = onAction
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func loadView() {
        let root = NotchWidgetStyle.root()
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)

        frameView.wantsLayer = true
        frameView.layer?.backgroundColor = NSColor.black.cgColor
        frameView.layer?.cornerRadius = Self.cornerRadius
        frameView.layer?.cornerCurve = .continuous
        frameView.layer?.masksToBounds = true
        frameView.setAccessibilityElement(false)
        frameView.translatesAutoresizingMaskIntoConstraints = false
        frameView.heightAnchor.constraint(equalToConstant: Self.previewHeight).isActive = true

        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        frameView.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerYAnchor.constraint(equalTo: frameView.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: frameView.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: frameView.trailingAnchor, constant: -12),
        ])

        FluxUIStyle.pin(FluxUIStyle.vstack([frameView, card], spacing: 0), in: root)
        view = root
        attachPreview()
        apply()
    }

    /// Replaces the parent's preview view. Pass nil to remove it. The old
    /// view is removed from the widget; the parent keeps ownership.
    public func setPreview(_ newPreview: NSView?) {
        guard newPreview !== preview else { return }
        preview?.removeFromSuperview()
        preview = newPreview
        if isViewLoaded {
            attachPreview()
            apply()
        }
    }

    public func update(_ newStatus: MirrorWidgetStatus) {
        guard newStatus != status else { return }
        status = newStatus
        if isViewLoaded { apply() }
    }

    private func attachPreview() {
        guard let preview, preview.superview !== frameView else { return }
        preview.removeFromSuperview()
        preview.translatesAutoresizingMaskIntoConstraints = false
        frameView.addSubview(preview, positioned: .below, relativeTo: statusLabel)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: frameView.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: frameView.trailingAnchor),
            preview.topAnchor.constraint(equalTo: frameView.topAnchor),
            preview.bottomAnchor.constraint(equalTo: frameView.bottomAnchor),
        ])
    }

    private func apply() {
        let focus = view.window?.firstResponder
        defer { NotchWidgetStyle.restoreFocus(focus, in: view.window) }
        let name = Widget.mirror.displayName

        switch status {
        case .starting, .running:
            card.hide()
            frameView.isHidden = false
            let running = status == .running
            preview?.isHidden = !running
            statusLabel.isHidden = running && preview != nil
            statusLabel.stringValue = running
                ? L("mirror.noPreview", "No camera picture")
                : L("mirror.starting", "Starting camera\u{2026}")
            view.setAccessibilityLabel(running && preview != nil
                ? String(format: L("mirror.running", "%@: camera on"), name)
                : "\(name): \(statusLabel.stringValue)")
        case .needsPermission:
            showCard("needsPermission", .init(symbolName: "camera",
                     title: L("mirror.permission", "Use your camera as a mirror"),
                     message: L("mirror.permission.message", "Flux can show a quick mirror using your Mac\u{2019}s camera."),
                     actionTitle: L("mirror.grant", "Grant Access")),
                     onAction: { [weak self] in self?.onAction(.requestPermission) })
        case .unavailable:
            showCard("unavailable", .init(symbolName: "video.slash",
                     title: L("mirror.unavailable", "No camera found"),
                     message: L("mirror.unavailable.message", "Connect a camera, or allow Flux in System Settings."),
                     actionTitle: L("mirror.openSettings", "Open Settings"),
                     secondaryTitle: L("mirror.checkAgain", "Check Again")),
                     onAction: { [weak self] in self?.onAction(.openSettings) },
                     onSecondary: { [weak self] in self?.onAction(.retry) })
        case .interrupted:
            showCard("interrupted", .init(symbolName: "pause.circle",
                     title: L("mirror.interrupted", "Camera paused"),
                     message: L("mirror.interrupted.message", "Another app may be using the camera."),
                     actionTitle: L("mirror.retry", "Try Again")),
                     onAction: { [weak self] in self?.onAction(.retry) })
        case .failed:
            showCard("failed", .init(symbolName: "exclamationmark.triangle",
                     title: L("mirror.failed", "The camera didn\u{2019}t start"),
                     message: L("mirror.failed.message", "Try again. If it keeps failing, restart Flux."),
                     actionTitle: L("mirror.retry", "Try Again")),
                     onAction: { [weak self] in self?.onAction(.retry) })
        }
    }

    private func showCard(_ key: String, _ content: PermissionCardView.Content,
                          onAction: (() -> Void)?, onSecondary: (() -> Void)? = nil) {
        preview?.isHidden = true
        frameView.isHidden = true
        card.show(key: key, content, onAction: onAction, onSecondary: onSecondary)
        view.setAccessibilityLabel("\(Widget.mirror.displayName): \(content.title)")
    }
}
