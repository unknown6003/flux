import AppKit
import FluxCore

public enum ClipboardWidgetKind: String, Equatable, Sendable {
    case text, url, color, file, image, other
}

/// A copied color as sRGB values, 0...1.
public struct ClipboardWidgetColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}

/// One clipboard row. The parent keeps the payload and copies it back.
/// The row holds only a short preview and an optional small image.
public struct ClipboardWidgetItem: Equatable {
    /// Longest preview the row keeps, in characters.
    public static let maximumPreviewLength = 200

    public var id: UUID
    /// At most `maximumPreviewLength` characters. `init` cuts longer text.
    public var preview: String
    public var kind: ClipboardWidgetKind
    /// A small thumbnail or file icon the parent already made. Never the full image.
    public var image: NSImage?
    public var color: ClipboardWidgetColor?
    /// False when the parent no longer has the payload. Copy is then off.
    public var hasPayload: Bool
    /// A link the parent checked. Open in Browser shows only for http and https.
    public var link: URL?

    public init(id: UUID, preview: String, kind: ClipboardWidgetKind, image: NSImage? = nil,
                color: ClipboardWidgetColor? = nil, hasPayload: Bool = true, link: URL? = nil) {
        self.id = id
        self.preview = String(preview.prefix(Self.maximumPreviewLength))
        self.kind = kind
        self.image = image
        self.color = color
        self.hasPayload = hasPayload
        self.link = link
    }

    var webLink: URL? {
        guard let link, let scheme = link.scheme?.lowercased(), scheme == "http" || scheme == "https",
              link.host?.isEmpty == false else { return nil }
        return link
    }
}

public struct ClipboardWidgetState: Equatable {
    /// Newest first. The widget shows at most `ClipboardWidgetController.maximumItems`.
    public var items: [ClipboardWidgetItem]
    /// The row the parent last copied back. It shows "Copied" until the parent clears it.
    public var copiedID: UUID?

    public init(items: [ClipboardWidgetItem] = [], copiedID: UUID? = nil) {
        self.items = items
        self.copiedID = copiedID
    }
}

public enum ClipboardWidgetAction: Equatable, Sendable {
    /// Copy this row's payload back to the pasteboard with its exact type.
    case copy(UUID)
    case remove(UUID)
    /// Open the row's checked http or https link.
    case openLink(UUID)
    /// Sent only after the user confirms Clear All.
    case clearAll
}

/// The Clipboard notch widget. It lists parent rows, filters them with a
/// local search and sends copy, open, remove and clear to the parent.
/// It never reads the pasteboard and keeps no history of its own.
@MainActor
public final class ClipboardWidgetController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    public static let maximumItems = 50
    public static let rowHeight: CGFloat = 36
    public static let visibleRows = 4

    public private(set) var state: ClipboardWidgetState
    private let onAction: @MainActor (ClipboardWidgetAction) -> Void
    private let header = NotchClearHeader(title: L("clipboard.title", "Clipboard"),
                                          question: L("clipboard.clearQuestion", "Remove all clipboard items?"))
    private let search = NSSearchField()
    private let (scroll, table) = NotchListTable.make(rowHeight: ClipboardWidgetController.rowHeight)
    private let card = NotchCardHost()
    private var scrollHeight: NSLayoutConstraint?
    /// The rows the table shows. Set only in `apply`, so the table and state agree.
    private var tableRows: [ClipboardWidgetItem] = []

    public init(state: ClipboardWidgetState, onAction: @escaping @MainActor (ClipboardWidgetAction) -> Void) {
        self.state = state
        self.onAction = onAction
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func loadView() {
        let root = NotchWidgetStyle.root()
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel(Widget.clipboard.displayName)

        header.onConfirm = { [weak self] in self?.onAction(.clearAll) }
        search.placeholderString = L("clipboard.search", "Search")
        search.setAccessibilityLabel(L("clipboard.search.label", "Search clipboard"))
        search.controlSize = .small
        search.delegate = self
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.onEnter = { [weak self] row in self?.send(row) { .copy($0) } }
        table.onDelete = { [weak self] row in self?.send(row) { .remove($0) } }
        table.menuForRow = { [weak self] row in self?.menu(row) }
        table.setAccessibilityLabel(L("clipboard.items", "Clipboard items"))
        let height = scroll.heightAnchor.constraint(equalToConstant: table.height(rows: 1, limit: Self.visibleRows))
        height.isActive = true
        scrollHeight = height

        NotchWidgetStyle.pinTop(FluxUIStyle.vstack([header, search, scroll, card], spacing: 6), in: root)
        view = root
        apply()
    }

    /// Replaces the state. An equal state changes nothing. Sends no action.
    public func update(_ newState: ClipboardWidgetState) {
        guard newState != state else { return }
        state = newState
        if isViewLoaded { apply() }
    }

    private func apply() {
        let focus = view.window?.firstResponder
        defer { NotchWidgetStyle.restoreFocus(focus, in: view.window) }
        let selectedID = tableRows.indices.contains(table.selectedRow) ? tableRows[table.selectedRow].id : nil
        let shown = Array(state.items.prefix(Self.maximumItems))
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        tableRows = query.isEmpty ? shown : shown.filter { $0.preview.localizedStandardContains(query) }
        header.setCanClear(!state.items.isEmpty)
        search.isHidden = state.items.isEmpty

        if state.items.isEmpty {
            card.show(key: "empty", .empty(symbolName: "doc.on.clipboard",
                      message: L("clipboard.empty", "Nothing copied yet")), onAction: nil)
        } else if tableRows.isEmpty {
            card.show(key: "noMatch", .empty(symbolName: "magnifyingglass",
                      message: L("clipboard.noMatch", "No matching items")), onAction: nil)
        } else {
            card.hide()
        }
        scroll.isHidden = tableRows.isEmpty
        scrollHeight?.constant = table.height(rows: tableRows.count, limit: Self.visibleRows)
        table.reloadData()
        if let selectedID, let row = tableRows.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        view.setAccessibilityLabel(String(format: L("clipboard.summary", "%@: %d items"),
                                          Widget.clipboard.displayName, shown.count))
    }

    private func send(_ row: Int, _ make: (UUID) -> ClipboardWidgetAction) {
        guard tableRows.indices.contains(row) else { return }
        let item = tableRows[row]
        let action = make(item.id)
        switch action {
        case .copy: guard item.hasPayload else { return }
        case .openLink: guard item.webLink != nil else { return }
        case .remove, .clearAll: break
        }
        onAction(action)
    }

    @objc private func clicked() {
        guard table.clickedRow >= 0 else { return }
        send(table.clickedRow) { .copy($0) }
    }

    private func menu(_ row: Int) -> NSMenu? {
        guard tableRows.indices.contains(row) else { return nil }
        let item = tableRows[row]
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(NotchMenuItem(L("clipboard.copy", "Copy"), enabled: item.hasPayload) { [weak self] in self?.send(row) { .copy($0) } })
        if item.webLink != nil {
            menu.addItem(NotchMenuItem(L("clipboard.openLink", "Open in Browser")) { [weak self] in self?.send(row) { .openLink($0) } })
        }
        menu.addItem(.separator())
        menu.addItem(NotchMenuItem(L("clipboard.remove", "Remove")) { [weak self] in self?.send(row) { .remove($0) } })
        return menu
    }

    // MARK: Search

    public func controlTextDidChange(_ obj: Notification) { apply() }

    /// Down moves from the search field into the list. Enter copies the first match.
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === search, !tableRows.isEmpty else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            view.window?.makeFirstResponder(table)
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.scrollRowToVisible(0)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            send(0) { .copy($0) }
            return true
        default:
            return false
        }
    }

    // MARK: Table

    public func numberOfRows(in tableView: NSTableView) -> Int { tableRows.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: NotchListRowView.identifier, owner: nil) as? NotchListRowView
            ?? NotchListRowView(frame: .zero)
        let item = tableRows[row]
        let detail: String
        if item.id == state.copiedID {
            detail = L("clipboard.copied", "Copied")
        } else if !item.hasPayload {
            detail = L("clipboard.unavailable", "No longer available")
        } else {
            detail = Self.kindName(item.kind)
        }
        let preview = item.preview.isEmpty ? Self.kindName(item.kind) : item.preview
        cell.configure(image: item.image, symbol: Self.symbol(item.kind), swatch: item.color?.nsColor,
                       title: preview.replacingOccurrences(of: "\n", with: " "), detail: detail,
                       dimmed: !item.hasPayload)
        return cell
    }

    private static func kindName(_ kind: ClipboardWidgetKind) -> String {
        switch kind {
        case .text: L("clipboard.kind.text", "Text")
        case .url: L("clipboard.kind.url", "Link")
        case .color: L("clipboard.kind.color", "Colour")
        case .file: L("clipboard.kind.file", "File")
        case .image: L("clipboard.kind.image", "Image")
        case .other: L("clipboard.kind.other", "Clipboard item")
        }
    }

    private static func symbol(_ kind: ClipboardWidgetKind) -> String {
        switch kind {
        case .text: "text.alignleft"
        case .url: "link"
        case .color: "paintpalette"
        case .file: "doc"
        case .image: "photo"
        case .other: "doc.on.clipboard"
        }
    }
}
