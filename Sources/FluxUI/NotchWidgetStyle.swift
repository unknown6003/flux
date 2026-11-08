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
        let bounded = seconds.isFinite ? min(max(0, seconds), Double(Int32.max)) : 0
        let total = Int(bounded.rounded(.down))
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

/// A one-column list for notch widgets. Enter and Delete act on the
/// selected row. A right click selects the row, then asks for its menu.
@MainActor
final class NotchListTable: NSTableView {
    var onEnter: ((Int) -> Void)?
    var onDelete: ((Int) -> Void)?
    var menuForRow: ((Int) -> NSMenu?)?

    static func make(rowHeight: CGFloat) -> (NSScrollView, NotchListTable) {
        let table = NotchListTable()
        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsMultipleSelection = false
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return (scroll, table)
    }

    /// Height for `rows` visible rows, at most `limit`.
    func height(rows: Int, limit: Int) -> CGFloat {
        CGFloat(min(max(rows, 1), limit)) * (rowHeight + intercellSpacing.height)
    }

    override func keyDown(with event: NSEvent) {
        let row = selectedRow
        if row >= 0, event.keyCode == 36 || event.keyCode == 76 {
            onEnter?(row)
        } else if row >= 0, event.keyCode == 51 || event.keyCode == 117 {
            onDelete?(row)
        } else {
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
        return menuForRow?(row)
    }
}

/// A menu item that runs a closure. The item is its own target.
@MainActor
final class NotchMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, enabled: Bool = true, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}

/// One reusable list row: a 28 pt image or color swatch, a title and a detail line.
@MainActor
final class NotchListRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("NotchListRow")
    private let icon = NSImageView()
    private let title = FluxUIStyle.label("", wraps: false)
    private let detail = FluxUIStyle.label("", style: .caption1, secondary: true, wraps: false)

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 5
        icon.layer?.masksToBounds = true
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
        ])
        title.lineBreakMode = .byTruncatingMiddle
        let texts = FluxUIStyle.vstack([title, detail], spacing: 1)
        let row = FluxUIStyle.hstack([icon, texts], spacing: 8)
        FluxUIStyle.pin(row, in: self, inset: NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4))
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
        for child in [icon, title, detail] as [NSView] { child.setAccessibilityElement(false) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(image: NSImage?, symbol: String, swatch: NSColor? = nil,
                   title: String, detail: String, dimmed: Bool = false) {
        if let swatch {
            icon.image = nil
            icon.layer?.backgroundColor = swatch.cgColor
        } else {
            icon.layer?.backgroundColor = nil
            icon.image = image ?? FluxUIStyle.symbol(symbol, label: "")
            icon.contentTintColor = image == nil ? .secondaryLabelColor : nil
        }
        self.title.stringValue = title
        self.title.textColor = dimmed ? .secondaryLabelColor : .labelColor
        self.detail.stringValue = detail
        self.detail.isHidden = detail.isEmpty
        setAccessibilityLabel(detail.isEmpty ? title : "\(title), \(detail)")
    }
}

/// A header with a title and a Clear All button. Clear All first shows an
/// inline question with Cancel and Clear. Only Clear calls `onConfirm`.
@MainActor
final class NotchClearHeader: NSStackView {
    var onConfirm: (() -> Void)?
    private let titleLabel: NSTextField
    private let clearButton: NSButton
    private let question: NSTextField
    private let cancelButton: NSButton
    private let confirmButton: NSButton
    private(set) var isConfirming = false

    init(title: String, question: String) {
        titleLabel = FluxUIStyle.label(title, style: .headline, wraps: false)
        self.question = FluxUIStyle.label(question, style: .callout, wraps: false)
        clearButton = NSButton(title: L("notch.clearAll", "Clear All"), target: nil, action: nil)
        cancelButton = NSButton(title: L("notch.cancel", "Cancel"), target: nil, action: nil)
        confirmButton = NSButton(title: L("notch.clear", "Clear"), target: nil, action: nil)
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        for button in [clearButton, cancelButton, confirmButton] {
            button.bezelStyle = .push
            button.controlSize = .small
            button.target = self
            button.setAccessibilityLabel(button.title)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        clearButton.action = #selector(askClear)
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        confirmButton.action = #selector(confirm)
        confirmButton.hasDestructiveAction = true
        for view in [titleLabel, self.question, FluxUIStyle.spacer(), clearButton, cancelButton, confirmButton] {
            addArrangedSubview(view)
        }
        show(confirming: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Hides Clear All when there is nothing to clear, and drops an open question.
    func setCanClear(_ canClear: Bool) {
        if !canClear, isConfirming { show(confirming: false) }
        clearButton.isEnabled = canClear
        clearButton.isHidden = isConfirming || !canClear
    }

    private func show(confirming: Bool) {
        isConfirming = confirming
        titleLabel.isHidden = confirming
        clearButton.isHidden = confirming
        question.isHidden = !confirming
        cancelButton.isHidden = !confirming
        confirmButton.isHidden = !confirming
    }

    @objc private func askClear() {
        show(confirming: true)
        window?.makeFirstResponder(cancelButton)
    }

    @objc private func cancel() {
        show(confirming: false)
        window?.makeFirstResponder(clearButton)
    }

    @objc private func confirm() {
        show(confirming: false)
        onConfirm?()
    }
}
