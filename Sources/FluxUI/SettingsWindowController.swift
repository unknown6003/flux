import AppKit

/// The five Settings pages, in sidebar order. The names match Flux 0.21.
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
        case .general: "gearshape.fill"
        case .menuBar: "menubar.rectangle"
        case .notch: "rectangle.topthird.inset.filled"
        case .lockScreen: "lock.fill"
        case .about: "info"
        }
    }

    /// The sidebar tile color, as in System Settings.
    var tileColor: NSColor {
        switch self {
        case .general, .about: .systemGray
        case .menuBar: .systemBlue
        case .notch: .systemIndigo
        case .lockScreen: .systemOrange
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
/// is open and release it in `onClose`; the window and its views go with it.
/// Bind the app menu "Settings…" item (key equivalent ⌘,) to `show(_:)`.
/// Esc closes the window unless the focused page handles `cancelOperation(_:)` first.
@MainActor
public final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    public typealias PageFactory = @MainActor (SettingsPage) -> NSViewController

    /// The window opens at this content size.
    public static let defaultSize = NSSize(width: 720, height: 560)
    /// The window can't be made smaller than this.
    public static let minimumSize = NSSize(width: 640, height: 420)

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
        contentItem.minimumThickness = 440
        split.addSplitViewItem(contentItem)

        let window = SettingsWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.toolbar = NSToolbar(identifier: "FluxSettings")
        window.toolbarStyle = .unified
        window.contentViewController = split
        window.setContentSize(Self.defaultSize)
        window.contentMinSize = Self.minimumSize
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
    let pages = SettingsPage.allCases
    let tableView = NSTableView()
    var onSelect: (@MainActor (SettingsPage) -> Void)?
    private var applyingSelection = false

    override func loadView() {
        tableView.addTableColumn(NSTableColumn(identifier: .init("page")))
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 28
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel(L("settings.sidebar", "Settings sections"))
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        view = scroll
    }

    func setSelection(_ page: SettingsPage) {
        _ = view
        guard let row = pages.firstIndex(of: page), tableView.selectedRow != row else { return }
        applyingSelection = true
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        applyingSelection = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { pages.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let page = pages[row]
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: page.title)
        text.lineBreakMode = .byTruncatingTail
        let image = NSImageView(image: Self.tile(page))
        image.setAccessibilityElement(false)
        cell.textField = text
        for view in [image, text] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 20),
            image.heightAnchor.constraint(equalToConstant: 20),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applyingSelection, pages.indices.contains(tableView.selectedRow) else { return }
        onSelect?(pages[tableView.selectedRow])
    }

    /// A white symbol on a rounded color tile, like the System Settings sidebar.
    static func tile(_ page: SettingsPage) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        let symbol = FluxUIStyle.symbol(page.symbolName, label: page.title)?.withSymbolConfiguration(configuration)
        let color = page.tileColor
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            if let symbol {
                let size = symbol.size
                symbol.draw(in: NSRect(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2,
                                       width: size.width, height: size.height))
            }
            return true
        }
        image.accessibilityDescription = page.title
        return image
    }
}
