import AppKit
import FluxCore

/// The fixed state of one shelf file. No spinner or progress value.
public enum FileShelfWidgetItemStatus: Equatable, Sendable {
    case ready
    /// The parent is still copying the file into the shelf.
    case copying
    /// The copy failed or the file is gone. The row can only be removed.
    case failed
}

/// One shelf row. The parent validates `dragURL` and owns the file behind it.
public struct FileShelfWidgetItem: Equatable {
    public var id: UUID
    public var name: String
    /// An app icon or a thumbnail the parent already made. Nil shows a document symbol.
    public var image: NSImage?
    /// The parent-owned file URL for drag out. Nil turns drag out off for this row.
    public var dragURL: URL?
    public var status: FileShelfWidgetItemStatus

    public init(id: UUID, name: String, image: NSImage? = nil, dragURL: URL? = nil,
                status: FileShelfWidgetItemStatus = .ready) {
        self.id = id
        self.name = name
        self.image = image
        self.dragURL = dragURL
        self.status = status
    }
}

public enum FileShelfWidgetStatus: Equatable, Sendable {
    case ready
    /// The parent is reading the stored shelf.
    case loading
    /// The parent is working, for example copying a drop. New drops are refused.
    case busy
    /// The shelf cannot be read. Try Again sends `.retry`.
    case failed
}

public struct FileShelfWidgetState: Equatable {
    public var items: [FileShelfWidgetItem]
    public var status: FileShelfWidgetStatus

    public init(items: [FileShelfWidgetItem] = [], status: FileShelfWidgetStatus = .ready) {
        self.items = items
        self.status = status
    }
}

public enum FileShelfWidgetAction: Equatable, Sendable {
    /// The user dropped these file URLs on the widget. Sent once per drop.
    case drop([URL])
    case open(UUID)
    case showInFinder(UUID)
    case airDrop(UUID)
    case copy(UUID)
    case remove(UUID)
    /// Sent only after the user confirms Clear All.
    case clearAll
    case retry
}

/// A file drag event on the widget root, for the window owner. Points are in
/// window coordinates. `session` is the AppKit `draggingSequenceNumber`.
public enum FileShelfDragEvent: Equatable {
    /// The drag left the root with no drop. Nil values mean AppKit gave no drag info.
    case exited(session: Int?, location: NSPoint?)
    /// The root took a drop and sent `.drop`.
    case dropped(session: Int)
    case ended(session: Int)
}

/// The File Shelf notch widget. It shows parent rows, takes file drops and
/// gives file drags. It does no file work: every change goes to the parent.
@MainActor
public final class FileShelfWidgetController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    public static let rowHeight: CGFloat = 36
    public static let visibleRows = 4

    public private(set) var state: FileShelfWidgetState
    private let onAction: @MainActor (FileShelfWidgetAction) -> Void
    /// Drag exit and drop on the root. It never carries file URLs; `.drop` does.
    public var onDragSession: (@MainActor (FileShelfDragEvent) -> Void)?
    private let header = NotchClearHeader(title: L("shelf.title", "File Shelf"),
                                          question: L("shelf.clearQuestion", "Remove all files from the shelf?"))
    private let (scroll, table) = NotchListTable.make(rowHeight: FileShelfWidgetController.rowHeight)
    private let card = NotchCardHost()
    private let note = FluxUIStyle.label("", style: .caption1, secondary: true, wraps: false)
    private var scrollHeight: NSLayoutConstraint?

    public init(state: FileShelfWidgetState, onAction: @escaping @MainActor (FileShelfWidgetAction) -> Void) {
        self.state = state
        self.onAction = onAction
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func loadView() {
        let root = FileShelfDropView()
        root.appearance = NSAppearance(named: .darkAqua)
        root.setContentHuggingPriority(.defaultHigh, for: .vertical)
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel(Widget.shelf.displayName)
        root.canDrop = { [weak self] in self?.state.status == .ready }
        root.isOwnDrag = { [weak self] source in (source as AnyObject?) === self?.table }
        root.onDrop = { [weak self] urls in self?.onAction(.drop(urls)) }
        root.onDragEvent = { [weak self] event in self?.onDragSession?(event) }

        header.onConfirm = { [weak self] in self?.onAction(.clearAll) }
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask([], forLocal: true)
        table.onEnter = { [weak self] row in self?.send(row) { .open($0) } }
        table.onDelete = { [weak self] row in self?.send(row) { .remove($0) } }
        table.menuForRow = { [weak self] row in self?.menu(row) }
        table.setAccessibilityLabel(L("shelf.files", "Shelf files"))
        let height = scroll.heightAnchor.constraint(equalToConstant: table.height(rows: 1, limit: Self.visibleRows))
        height.isActive = true
        scrollHeight = height

        NotchWidgetStyle.pinTop(FluxUIStyle.vstack([header, note, scroll, card], spacing: 6), in: root)
        view = root
        apply()
    }

    /// Replaces the state. An equal state changes nothing. Sends no action.
    public func update(_ newState: FileShelfWidgetState) {
        guard newState != state else { return }
        state = newState
        if isViewLoaded { apply() }
    }

    private func apply() {
        let focus = view.window?.firstResponder
        defer { NotchWidgetStyle.restoreFocus(focus, in: view.window) }
        let selectedID = table.selectedRow >= 0 && table.selectedRow < tableRows.count ? tableRows[table.selectedRow].id : nil
        tableRows = state.status == .failed ? [] : state.items
        header.setCanClear(!tableRows.isEmpty && state.status == .ready)

        switch state.status {
        case .ready: note.stringValue = ""
        case .loading: note.stringValue = L("shelf.loading", "Loading files\u{2026}")
        case .busy: note.stringValue = L("shelf.busy", "Adding files\u{2026}")
        case .failed: note.stringValue = ""
        }
        note.isHidden = note.stringValue.isEmpty

        if state.status == .failed {
            card.show(key: "failed", .init(symbolName: "exclamationmark.triangle",
                      title: L("shelf.failed", "Can\u{2019}t read the shelf"),
                      message: L("shelf.failed.message", "Flux couldn\u{2019}t load your shelf files."),
                      actionTitle: L("shelf.retry", "Try Again")),
                      onAction: { [weak self] in self?.onAction(.retry) })
        } else if tableRows.isEmpty && state.status == .ready {
            card.show(key: "empty", .empty(symbolName: "tray.and.arrow.down",
                      message: L("shelf.empty", "Drop files here")), onAction: nil)
        } else {
            card.hide()
        }
        scroll.isHidden = tableRows.isEmpty
        scrollHeight?.constant = table.height(rows: tableRows.count, limit: Self.visibleRows)
        table.reloadData()
        if let selectedID, let row = tableRows.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        view.setAccessibilityLabel(String(format: L("shelf.summary", "%@: %d files"),
                                          Widget.shelf.displayName, state.items.count))
    }

    /// The rows the table shows. Set only in `apply`, so the table and state agree.
    private var tableRows: [FileShelfWidgetItem] = []

    private func send(_ row: Int, _ make: (UUID) -> FileShelfWidgetAction) {
        guard tableRows.indices.contains(row) else { return }
        let item = tableRows[row]
        let action = make(item.id)
        guard item.status == .ready || action == .remove(item.id) else { return }
        onAction(action)
    }

    @objc private func doubleClicked() {
        guard table.clickedRow >= 0 else { return }
        send(table.clickedRow) { .open($0) }
    }

    private func menu(_ row: Int) -> NSMenu? {
        guard tableRows.indices.contains(row) else { return nil }
        let item = tableRows[row]
        let ready = item.status == .ready
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(NotchMenuItem(L("shelf.open", "Open"), enabled: ready) { [weak self] in self?.send(row) { .open($0) } })
        menu.addItem(NotchMenuItem(L("shelf.showInFinder", "Show in Finder"), enabled: ready) { [weak self] in self?.send(row) { .showInFinder($0) } })
        menu.addItem(NotchMenuItem(L("shelf.airDrop", "AirDrop"), enabled: ready) { [weak self] in self?.send(row) { .airDrop($0) } })
        menu.addItem(NotchMenuItem(L("shelf.copy", "Copy"), enabled: ready) { [weak self] in self?.send(row) { .copy($0) } })
        menu.addItem(.separator())
        menu.addItem(NotchMenuItem(L("shelf.remove", "Remove")) { [weak self] in self?.send(row) { .remove($0) } })
        return menu
    }

    // MARK: Table

    public func numberOfRows(in tableView: NSTableView) -> Int { tableRows.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: NotchListRowView.identifier, owner: nil) as? NotchListRowView
            ?? NotchListRowView(frame: .zero)
        let item = tableRows[row]
        let detail: String
        switch item.status {
        case .ready: detail = ""
        case .copying: detail = L("shelf.copying", "Copying\u{2026}")
        case .failed: detail = L("shelf.itemFailed", "Unavailable")
        }
        cell.configure(image: item.image, symbol: "doc", title: item.name, detail: detail, dimmed: item.status != .ready)
        return cell
    }

    public func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard tableRows.indices.contains(row), tableRows[row].status == .ready,
              let url = tableRows[row].dragURL, url.isFileURL else { return nil }
        return url as NSURL
    }
}

/// The widget root. It takes file URL drops only from a user drag, and
/// refuses drags that start in its own table.
@MainActor
private final class FileShelfDropView: NSView {
    var canDrop: () -> Bool = { false }
    var isOwnDrag: (Any?) -> Bool = { _ in false }
    var onDrop: (([URL]) -> Void)?
    var onDragEvent: ((FileShelfDragEvent) -> Void)?
    private let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { operation(sender) }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { operation(sender) }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard operation(sender) == .copy,
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              !urls.isEmpty else { return false }
        onDrop?(urls)
        onDragEvent?(.dropped(session: sender.draggingSequenceNumber))
        return true
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDragEvent?(.exited(session: sender?.draggingSequenceNumber, location: sender?.draggingLocation))
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        onDragEvent?(.ended(session: sender.draggingSequenceNumber))
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { true }

    private func operation(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard canDrop(), !isOwnDrag(sender.draggingSource),
              sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: options) else { return [] }
        return .copy
    }
}
