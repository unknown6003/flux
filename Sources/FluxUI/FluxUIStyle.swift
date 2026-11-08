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

    /// A label. Wrapping labels resist horizontal growth, so the container
    /// width decides their line breaks.
    static func label(_ text: String, style: NSFont.TextStyle = .body, secondary: Bool = false, wraps: Bool = true) -> NSTextField {
        let field = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        field.font = .preferredFont(forTextStyle: style)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        field.isSelectable = false
        if wraps {
            field.preferredMaxLayoutWidth = 0
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        } else {
            field.maximumNumberOfLines = 1
            field.lineBreakMode = .byTruncatingTail
            field.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        }
        return field
    }

    static func symbol(_ name: String, label: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)
    }

    static func button(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .push
        button.setAccessibilityLabel(title)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    /// A vertical stack. `fill` makes every child as wide as the stack.
    static func vstack(_ views: [NSView], spacing: CGFloat = 8, fill: Bool = true) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = fill ? .width : .leading
        stack.spacing = spacing
        stack.setHuggingPriority(.defaultHigh, for: .vertical)
        return stack
    }

    static func hstack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return view
    }

    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    /// A grouped area like System Settings form groups. Its height follows its content.
    static func group(_ content: NSView) -> NSView { GroupView(content: content) }

    /// Pins `view` to all edges of `container`, with insets.
    static func pin(_ view: NSView, in container: NSView, inset: NSEdgeInsets = NSEdgeInsetsZero) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset.left),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset.right),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: inset.top),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset.bottom),
        ])
    }

    /// A vertical scroll view whose document is as wide as the visible area
    /// and as tall as `content`. Use it as a Settings page root view.
    static func page(_ content: NSView) -> NSScrollView {
        let document = FlippedView()
        pin(content, in: document, inset: NSEdgeInsets(top: 20, left: 24, bottom: 24, right: 24))
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        return scroll
    }

    /// A titled section: headline, then a group of rows with separators.
    static func section(_ title: String?, _ rows: [NSView]) -> NSStackView {
        var items: [NSView] = []
        for (index, row) in rows.enumerated() {
            if index > 0 { items.append(separator()) }
            items.append(row)
        }
        let box = group(vstack(items, spacing: 8))
        var parts: [NSView] = []
        if let title {
            let header = label(title, style: .headline)
            header.setAccessibilityRole(.staticText)
            parts.append(header)
        }
        parts.append(box)
        let stack = vstack(parts, spacing: 6)
        if let title {
            stack.setAccessibilityElement(true)
            stack.setAccessibilityRole(.group)
            stack.setAccessibilityLabel(title)
        }
        return stack
    }

    /// A form row: title and optional helper text on the left, control on the right.
    static func row(_ title: String, helper: String? = nil, control: NSView?) -> NSStackView {
        var texts: [NSView] = [label(title)]
        if let helper { texts.append(label(helper, style: .callout, secondary: true)) }
        let text = vstack(texts, spacing: 2)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [text]
        if let control {
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
            control.setContentHuggingPriority(.required, for: .horizontal)
            views.append(control)
            if control.accessibilityLabel()?.isEmpty ?? true { control.setAccessibilityLabel(title) }
        }
        let stack = hstack(views, spacing: 12)
        stack.distribution = .fill
        return stack
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A rounded fill behind grouped content. It sizes itself to the content
/// with constraints, unlike `NSBox.contentView`, which the box sizes.
@MainActor
final class GroupView: NSView {
    init(content: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        FluxUIStyle.pin(content, in: self, inset: NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
        layer?.borderWidth = 0.5
    }
}
