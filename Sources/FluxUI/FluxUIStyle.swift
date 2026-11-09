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
        let stack = fill ? WidthStackView(views: views) : NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
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

    /// Settings form metrics, close to System Settings.
    enum Form {
        static let pageInset = NSEdgeInsets(top: 12, left: 20, bottom: 20, right: 20)
        static let sectionSpacing: CGFloat = 18
        static let rowInset = NSEdgeInsets(top: 7, left: 0, bottom: 7, right: 0)
        static let rowMinHeight: CGFloat = 22
        static var helperFont: NSFont { NSFont.preferredFont(forTextStyle: .subheadline) }
        static var headerFont: NSFont { NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold) }
    }

    /// A vertical scroll view whose document is as wide as the visible area
    /// and as tall as `content`. Use it as a Settings page root view.
    static func page(_ content: NSView) -> NSScrollView {
        let document = FlippedView()
        pin(content, in: document, inset: Form.pageInset)
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

    /// A section: an optional header, a rounded group of rows with
    /// separators, and an optional one-line footer.
    static func section(_ title: String?, _ rows: [NSView], footer: String? = nil) -> NSStackView {
        var items: [NSView] = []
        for (index, row) in rows.enumerated() {
            if index > 0 { items.append(separator()) }
            items.append(row is FormRowView ? row : FormRowView.padded(row))
        }
        let box = group(vstack(items, spacing: 0))
        var parts: [NSView] = []
        if let title {
            let header = label(title, wraps: false)
            header.font = Form.headerFont
            header.setAccessibilityRole(.staticText)
            parts.append(header)
        }
        parts.append(box)
        if let footer { parts.append(label(footer, style: .subheadline, secondary: true)) }
        let stack = vstack(parts, spacing: 6)
        if let title {
            stack.setAccessibilityElement(true)
            stack.setAccessibilityRole(.group)
            stack.setAccessibilityLabel(title)
        }
        return stack
    }

    /// A form row: title and optional one-line help on the left, the control
    /// on the right. The control keeps its size; the text wraps.
    static func row(_ title: String, helper: String? = nil, control: NSView?) -> NSView {
        if let control, control.accessibilityLabel()?.isEmpty ?? true { control.setAccessibilityLabel(title) }
        return FormRowView(title: title, helper: helper, control: control)
    }

    /// Secondary text for the control side of a row, for example "Allowed".
    static func value(_ text: String) -> NSTextField {
        let field = label(text, secondary: true, wraps: false)
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        return field
    }
}

/// One Settings row. Text sits on the leading side and the control on the
/// trailing side, vertically centered, so every control in a group lines up.
@MainActor
final class FormRowView: NSView {
    init(title: String, helper: String?, control: NSView?) {
        super.init(frame: .zero)
        let titleLabel = FluxUIStyle.label(title)
        var texts: [NSTextField] = [titleLabel]
        if let helper, !helper.isEmpty {
            let help = FluxUIStyle.label(helper, secondary: true)
            help.font = FluxUIStyle.Form.helperFont
            texts.append(help)
        }
        // A row whose controls are all off dims its text, as in System Settings.
        if let control, Self.isDisabled(control) {
            texts.forEach { $0.textColor = .tertiaryLabelColor }
        }
        let text = FluxUIStyle.vstack(texts, spacing: 2)
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        let inset = FluxUIStyle.Form.rowInset
        var constraints = [
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset.left),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: inset.top),
            heightAnchor.constraint(greaterThanOrEqualToConstant: FluxUIStyle.Form.rowMinHeight + inset.top + inset.bottom),
        ]
        if let control {
            control.translatesAutoresizingMaskIntoConstraints = false
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
            control.setContentHuggingPriority(.required, for: .horizontal)
            addSubview(control)
            constraints += [
                control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset.right),
                control.centerYAnchor.constraint(equalTo: centerYAnchor),
                control.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: inset.top),
                text.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -16),
            ]
        } else {
            constraints.append(text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset.right))
        }
        // Weak preferences: text takes the free width, the row stays as short as it can.
        let fill = text.trailingAnchor.constraint(equalTo: trailingAnchor)
        fill.priority = .init(1)
        let compact = heightAnchor.constraint(equalToConstant: 0)
        compact.priority = .init(1)
        constraints += [fill, compact]
        NSLayoutConstraint.activate(constraints)
    }

    private static func isDisabled(_ view: NSView) -> Bool {
        if let control = view as? NSControl { return !control.isEnabled }
        let controls = view.subviews.compactMap { $0 as? NSControl }
        return !controls.isEmpty && controls.allSatisfy { !$0.isEnabled }
    }

    /// Gives any other view the same row padding, so it lines up in a group.
    static func padded(_ view: NSView) -> NSView {
        let wrapper = NSView()
        FluxUIStyle.pin(view, in: wrapper, inset: FluxUIStyle.Form.rowInset)
        return wrapper
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// AppKit alignment chooses an edge; it does not stretch arranged views.
/// Keep the width constraints current when a page replaces its sections.
@MainActor
private final class WidthStackView: NSStackView {
    private var filledViews: [NSView] = []
    private var widths: [NSLayoutConstraint] = []
    private var horizontalInset: CGFloat = -1

    override func updateConstraints() {
        let attached = arrangedSubviews.filter { $0.superview === self }
        let inset = edgeInsets.left + edgeInsets.right
        if attached != filledViews || inset != horizontalInset {
            NSLayoutConstraint.deactivate(widths)
            filledViews = attached
            horizontalInset = inset
            widths = attached.map { $0.widthAnchor.constraint(equalTo: widthAnchor, constant: -inset) }
            NSLayoutConstraint.activate(widths)
        }
        super.updateConstraints()
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A rounded fill behind grouped content, like a System Settings group.
/// It sizes itself to the content with constraints, unlike `NSBox.contentView`.
@MainActor
final class GroupView: NSView {
    static let inset = NSEdgeInsets(top: 3, left: 12, bottom: 3, right: 12)

    init(content: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        FluxUIStyle.pin(content, in: self, inset: Self.inset)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            layer?.backgroundColor = (dark ? NSColor.white.withAlphaComponent(0.05) : NSColor.black.withAlphaComponent(0.03)).cgColor
            layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.08)).cgColor
        }
        layer?.borderWidth = 0.5
    }
}
