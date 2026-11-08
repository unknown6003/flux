import AppKit

/// The five Settings pages. The names match Flux 0.21.
public enum SettingsPage: String, CaseIterable, Sendable {
    case general, menuBar, notch, lockScreen, about

    public var title: String {
        switch self {
        case .general: L("settings.general", "General")
        case .menuBar: L("settings.menuBar", "Menu Bar")
        case .notch: L("settings.notch", "Notch")
        case .lockScreen: L("settings.lockScreen", "Lock Screen")
        case .about: L("settings.about", "About")
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .menuBar: "menubar.rectangle"
        case .notch: "rectangle.topthird.inset.filled"
        case .lockScreen: "lock"
        case .about: "info.circle"
        }
    }
}

/// A page can name the view that gets focus when it opens.
@MainActor
public protocol SettingsPageFocus: AnyObject {
    var preferredFirstResponder: NSView? { get }
}

/// Settings window with a sidebar. It holds one page at a time.
///
/// The parent owns this controller. Keep a strong reference while the window
/// is open and release it in `onClose`. Bind the app menu "Settings…" item
/// (key equivalent ⌘,) to `show(_:)`. Esc closes the window unless the
/// focused page handles `cancelOperation(_:)` first.
@MainActor
public final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    public typealias PageFactory = @MainActor (SettingsPage) -> NSViewController

    /// Called after the window closed and the page was released.
    public var onClose: (@MainActor () -> Void)?
    /// Called before a page is discarded, so the parent can stop page work.
    public var onPageWillDisappear: (@MainActor (SettingsPage) -> Void)?

    public private(set) var currentPage: SettingsPage?

    private let makePage: PageFactory
    private let sidebar: SettingsSidebarController
    private let host = NSViewController()
    private weak var pageController: NSViewController?

    public init(initialPage: SettingsPage = .general, makePage: @escaping PageFactory) {
        self.makePage = makePage
        sidebar = SettingsSidebarController()
        host.view = NSView()

        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.canCollapse = false
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 220
        split.addSplitViewItem(sidebarItem)
        let contentItem = NSSplitViewItem(viewController: host)
        contentItem.minimumThickness = 480
        split.addSplitViewItem(contentItem)

        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        window.contentViewController = split
        window.setContentSize(NSSize(width: 760, height: 560))
        window.minSize = NSSize(width: 680, height: 420)
        super.init(window: window)
        window.delegate = self
        sidebar.onSelect = { [weak self] page in self?.select(page, focusPage: false) }
        select(initialPage, focusPage: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows the window on the given page, or the current page when nil.
    public func show(_ page: SettingsPage? = nil) {
        if let page { select(page, focusPage: true) }
        if window?.isVisible != true { window?.center() }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        if page == nil { window?.makeFirstResponder(sidebar.tableView) }
    }

    /// Replaces the page. The old page controller and its view are removed,
    /// so no inactive page stays in memory.
    public func select(_ page: SettingsPage, focusPage: Bool) {
        sidebar.setSelection(page)
        guard page != currentPage else { return }
        discardPage()
        let controller = makePage(page)
        host.addChild(controller)
        let view = controller.view
        view.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.view.bottomAnchor),
        ])
        pageController = controller
        currentPage = page
        window?.title = page.title
        if focusPage, let target = (controller as? SettingsPageFocus)?.preferredFirstResponder {
            window?.makeFirstResponder(target)
        }
    }

    private func discardPage() {
        guard let controller = pageController, let page = currentPage else { return }
        onPageWillDisappear?(page)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        pageController = nil
        currentPage = nil
    }

    public func windowWillClose(_ notification: Notification) {
        discardPage()
        let callback = onClose
        onClose = nil
        callback?()
    }
}

private final class SettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

@MainActor
private final class SettingsSidebarController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    enum Item {
        case header(String)
        case page(SettingsPage)
    }

    let items: [Item] = [
        .header(L("settings.group.flux", "Flux")),
        .page(.menuBar), .page(.notch), .page(.lockScreen),
        .header(L("settings.group.system", "System")),
        .page(.general), .page(.about),
    ]
    let tableView = NSTableView()
    var onSelect: (@MainActor (SettingsPage) -> Void)?
    private var applyingSelection = false

    override func loadView() {
        let column = NSTableColumn(identifier: .init("page"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowSizeStyle = .default
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel(L("settings.sidebar", "Settings sections"))
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        view = scroll
    }

    func setSelection(_ page: SettingsPage) {
        _ = view
        guard let row = items.firstIndex(where: { if case .page(page) = $0 { true } else { false } }),
              tableView.selectedRow != row else { return }
        applyingSelection = true
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        applyingSelection = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = items[row] { true } else { false }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .page = items[row] { true } else { false }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: "")
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = text
        cell.addSubview(text)
        var leading = cell.leadingAnchor
        switch items[row] {
        case .header(let title):
            text.stringValue = title
        case .page(let page):
            text.stringValue = page.title
            let image = NSImageView(image: FluxUIStyle.symbol(page.symbolName, label: page.title) ?? NSImage())
            image.translatesAutoresizingMaskIntoConstraints = false
            image.setAccessibilityElement(false)
            cell.imageView = image
            cell.addSubview(image)
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 18),
            ])
            leading = image.trailingAnchor
        }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leading, constant: 6),
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applyingSelection, tableView.selectedRow >= 0,
              case .page(let page) = items[tableView.selectedRow] else { return }
        onSelect?(page)
    }
}
