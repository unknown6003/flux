import AppKit

/// Shared look for the black notch widgets. Widgets sit inside
/// `NotchPanelController`, which already sets the dark appearance.
@MainActor
enum NotchWidgetStyle {
    /// A compact root view with dark appearance, so a widget also looks
    /// right when a test or preview hosts it outside the panel.
    static func root() -> NSView {
        let view = NSView()
        view.appearance = NSAppearance(named: .darkAqua)
        view.setContentHuggingPriority(.defaultHigh, for: .vertical)
        return view
    }

    /// A borderless symbol button with a VoiceOver label and tooltip.
    static func iconButton(_ symbol: String, label: String, size: CGFloat, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(image: FluxUIStyle.symbol(symbol, label: label) ?? NSImage(), target: target, action: action)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.symbolConfiguration = .init(pointSize: size, weight: .medium)
        button.contentTintColor = .labelColor
        button.setAccessibilityLabel(label)
        button.toolTip = label
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    static func setSymbol(_ button: NSButton, _ symbol: String, label: String) {
        button.image = FluxUIStyle.symbol(symbol, label: label)
        button.setAccessibilityLabel(label)
        button.toolTip = label
    }

    /// Minutes and seconds, or hours when needed. Negative and non-finite values read as 0:00.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Keeps focus on the same control after a state update, when the
    /// control is still in the window and can take focus.
    static func restoreFocus(_ responder: NSResponder?, in window: NSWindow?) {
        guard let window, let view = responder as? NSView, view.window === window,
              !view.isHiddenOrHasHiddenAncestor, view.acceptsFirstResponder else { return }
        if window.firstResponder !== view { window.makeFirstResponder(view) }
    }
}

/// Holds at most one `PermissionCardView`. A card is rebuilt only when its
/// key changes, so a focused card button keeps focus across equal updates.
@MainActor
final class NotchCardHost: NSView {
    private(set) var key: String?
    private var card: PermissionCardView?

    func show(key: String, _ content: PermissionCardView.Content,
              onAction: (() -> Void)?, onSecondary: (() -> Void)? = nil) {
        isHidden = false
        guard key != self.key else { return }
        clear()
        self.key = key
        let card = PermissionCardView(content: content)
        card.onAction = onAction
        card.onSecondary = onSecondary
        FluxUIStyle.pin(card, in: self)
        self.card = card
    }

    func hide() {
        isHidden = true
        clear()
    }

    private func clear() {
        card?.removeFromSuperview()
        card = nil
        key = nil
    }
}
