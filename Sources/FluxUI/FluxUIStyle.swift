import AppKit

/// Looks up a user-facing string in the host app's `FluxUI` table.
/// The default English value is used when no translation exists.
func L(_ key: String, _ value: String) -> String {
    NSLocalizedString(key, tableName: "FluxUI", bundle: .main, value: value, comment: "")
}

/// Restrained brand color. Use it only for the current choice and focus.
@MainActor
public enum FluxUIStyle {
    /// Amber in dark appearance, a darker amber ink in light appearance so
    /// text keeps a 4.5:1 contrast on white.
    public static let accent = NSColor(name: "FluxAccent") { @Sendable appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark
            ? NSColor(srgbRed: 0.98, green: 0.69, blue: 0.20, alpha: 1)
            : NSColor(srgbRed: 0.62, green: 0.38, blue: 0.00, alpha: 1)
    }

    static func label(_ text: String, style: NSFont.TextStyle = .body, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .preferredFont(forTextStyle: style)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        field.isSelectable = false
        return field
    }

    static func symbol(_ name: String, label: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)
    }

    static func button(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .push
        button.setAccessibilityLabel(title)
        return button
    }

    static func vstack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    static func hstack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    /// A grouped box that matches System Settings form groups.
    static func group(_ content: NSView) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 8
        box.borderWidth = 0
        box.fillColor = .quaternarySystemFill
        box.titlePosition = .noTitle
        box.contentViewMargins = NSSize(width: 12, height: 10)
        box.contentView = content
        return box
    }
}
