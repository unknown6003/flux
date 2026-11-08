import AppKit

/// A card that asks for one permission, or shows one empty state.
/// It has one main action. The parent shows it only where the feature needs
/// the grant, never as a startup wall.
@MainActor
public final class PermissionCardView: NSView {
    public struct Content {
        public var symbolName: String
        public var title: String
        public var message: String
        /// The one main action, for example "Allow" or "Open Settings". Nil for an empty state.
        public var actionTitle: String?
        /// An optional quiet action, for example "Check Again".
        public var secondaryTitle: String?

        public init(symbolName: String, title: String, message: String, actionTitle: String? = nil, secondaryTitle: String? = nil) {
            self.symbolName = symbolName
            self.title = title
            self.message = message
            self.actionTitle = actionTitle
            self.secondaryTitle = secondaryTitle
        }

        /// A one-line empty state, for example "No events today".
        public static func empty(symbolName: String, message: String) -> Content {
            Content(symbolName: symbolName, title: "", message: message)
        }
    }

    public var onAction: (() -> Void)?
    public var onSecondary: (() -> Void)?
    public let actionButton = NSButton(title: "", target: nil, action: nil)
    private let secondaryButton = NSButton(title: "", target: nil, action: nil)

    public init(content: Content) {
        super.init(frame: .zero)
        let image = NSImageView(image: FluxUIStyle.symbol(content.symbolName, label: "") ?? NSImage())
        image.symbolConfiguration = .init(textStyle: .title2)
        image.contentTintColor = .secondaryLabelColor
        image.setAccessibilityElement(false)

        var rows: [NSView] = []
        if !content.title.isEmpty { rows.append(FluxUIStyle.label(content.title, style: .headline)) }
        rows.append(FluxUIStyle.label(content.message, secondary: !content.title.isEmpty))

        var buttons: [NSView] = []
        if let title = content.actionTitle {
            actionButton.title = title
            actionButton.bezelStyle = .push
            actionButton.keyEquivalent = "\r"
            actionButton.target = self
            actionButton.action = #selector(primary)
            actionButton.setAccessibilityLabel(title)
            buttons.append(actionButton)
        }
        if let title = content.secondaryTitle {
            secondaryButton.title = title
            secondaryButton.bezelStyle = .push
            secondaryButton.target = self
            secondaryButton.action = #selector(secondary)
            secondaryButton.setAccessibilityLabel(title)
            buttons.append(secondaryButton)
        }
        if !buttons.isEmpty { rows.append(FluxUIStyle.hstack(buttons)) }

        let text = FluxUIStyle.vstack(rows, spacing: 6)
        let row = FluxUIStyle.hstack([image, text], spacing: 12)
        row.alignment = .top
        let box = FluxUIStyle.group(row)
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor),
            box.topAnchor.constraint(equalTo: topAnchor),
            box.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(content.title.isEmpty ? content.message : content.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func primary() { onAction?() }
    @objc private func secondary() { onSecondary?() }
}
