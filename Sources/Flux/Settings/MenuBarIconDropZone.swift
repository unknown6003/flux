import AppKit
import SwiftUI

struct MenuBarIconLane: NSViewRepresentable {
    @ObservedObject var controller: MenuBarDragController
    @ObservedObject var manager: MenuBarIconManager
    let section: MenuBarSection
    let icons: [MenuBarIconManager.Icon]
    let alwaysHiddenEnabled: Bool

    func makeNSView(context: Context) -> MenuBarIconLaneView {
        let view = MenuBarIconLaneView(frame: .zero)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: MenuBarIconLaneView, context: Context) {
        view.configure(controller: controller, manager: manager, section: section,
                       icons: icons, alwaysHiddenEnabled: alwaysHiddenEnabled)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MenuBarIconLaneView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 500, height: 88)
    }
}

@MainActor
final class MenuBarIconLaneView: MenuBarDragDestinationView {
    private var icons: [MenuBarIconManager.Icon] = []
    private weak var manager: MenuBarIconManager?
    private let scroll = NSScrollView()
    private let strip = MenuBarDragDestinationView()
    private var sources: [MenuBarDragSourceView] = []
    private var alwaysHiddenEnabled = true
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = strip
        addSubview(scroll)
        insertionAt = { [weak self] point in
            guard let self else { return nil }
            return self.insertion(at: self.strip.convert(point, from: self))
        }
        strip.insertionAt = { [weak self] point in self?.insertion(at: point) }
        strip.markerAt = { [weak self] point in self?.marker(at: point) ?? 12 }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(controller: MenuBarDragController, manager: MenuBarIconManager,
                   section: MenuBarSection, icons: [MenuBarIconManager.Icon], alwaysHiddenEnabled: Bool) {
        self.controller = controller
        self.manager = manager
        self.section = section
        strip.controller = controller
        strip.section = section
        acceptsDrops = section != .alwaysHidden || alwaysHiddenEnabled
        strip.acceptsDrops = acceptsDrops
        guard !controller.isDragging else { return }
        self.alwaysHiddenEnabled = alwaysHiddenEnabled
        let ordered = icons.sorted { $0.frame.minX < $1.frame.minX }
        guard self.icons != ordered || sources.isEmpty else { needsDisplay = true; return }
        let old = Dictionary(uniqueKeysWithValues: sources.compactMap { source in source.icon.map { ($0.id, source) } })
        let next = ordered.map { icon -> MenuBarDragSourceView in
            let source = old[icon.id] ?? controller.makeSourceView(for: icon)
            source.icon = icon
            source.moveMenu = { [weak self, weak source] in
                guard let self, let source, let icon = source.icon,
                      self.manager?.isTrusted == true, self.manager?.isUpdatingIcons == false,
                      NSApp.isActive, source.window?.isKeyWindow == true else { return nil }
                return self.makeMenu(for: icon)
            }
            source.toolTip = [icon.title, icon.source, icon.isMovable ? "Click for move options" : "Fixed system icon"]
                .compactMap { $0 }.joined(separator: " · ")
            source.setAccessibilityElement(true)
            source.setAccessibilityRole(.button)
            source.setAccessibilityLabel(icon.title)
            source.setAccessibilityHelp(icon.isMovable ? "Drag to place. Press Space for move options." : "Fixed system icon")
            return source
        }
        if next != sources {
            sources.filter { !next.contains($0) }.forEach { $0.removeFromSuperview() }
            next.filter { $0.superview !== strip }.forEach { strip.addSubview($0) }
        }
        sources = next
        self.icons = ordered
        setAccessibilityElement(false)
        setAccessibilityLabel("\(section.displayName), \(icons.count) icons. Drop between icons to place.")
        needsLayout = true
        needsDisplay = true
    }

    private func slot(at point: NSPoint) -> (icons: [MenuBarIconManager.Icon], index: Int) {
        let available = sources.filter { $0.icon?.id != controller?.draggedIconID }
        let index = available.firstIndex { point.x < $0.frame.midX } ?? available.count
        return (available.compactMap(\.icon), index)
    }

    private func insertion(at point: NSPoint) -> MenuBarIconManager.Insertion {
        let (icons, index) = slot(at: point)
        return .init(section: section, before: index < icons.count ? icons[index] : nil,
                     after: index > 0 ? icons[index - 1] : nil)
    }

    private func marker(at point: NSPoint) -> CGFloat {
        let available = sources.filter { $0.icon?.id != controller?.draggedIconID }
        let index = slot(at: point).index
        if index < available.count { return available[index].frame.minX }
        return available.last?.frame.maxX ?? strip.bounds.width - 18
    }

    override func layout() {
        super.layout()
        scroll.frame = NSRect(x: 0, y: 28, width: bounds.width, height: 54)
        let width = max(scroll.contentSize.width, CGFloat(sources.count) * 42 + 24)
        let atEnd = scroll.contentView.bounds.maxX >= strip.bounds.maxX - 1
        strip.frame = NSRect(x: 0, y: 0, width: width, height: 54)
        for (index, source) in sources.enumerated() {
            source.frame = NSRect(x: width - 12 - CGFloat(sources.count - index) * 42, y: 7, width: 42, height: 40)
        }
        if atEnd { scroll.contentView.scroll(to: NSPoint(x: max(0, width - scroll.contentSize.width), y: 0)) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let bar = NSRect(x: 0, y: 28, width: bounds.width, height: 54)
        Theme.surfaceRaised.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 9, yRadius: 9).fill()
        Theme.zone(section).withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 9, yRadius: 9).fill()
        ((section.displayName + (acceptsDrops ? "" : " (off)")) as NSString).draw(at: NSPoint(x: 2, y: 5), withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: Theme.textPrimary
        ])
        ("\(icons.count)" as NSString).draw(at: NSPoint(x: bounds.width - 25, y: 5), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: Theme.textSecondary
        ])
        if icons.isEmpty {
            ("Drop icons here" as NSString).draw(at: NSPoint(x: 16, y: 48), withAttributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.textSecondary
            ])
        }
        super.draw(dirtyRect)
    }

    private func makeMenu(for icon: MenuBarIconManager.Icon) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for destination in MenuBarSection.allCases {
            let item = NSMenuItem(title: destination.displayName, action: #selector(moveIcon(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = (icon, destination)
            item.isEnabled = icon.isMovable && destination != icon.section
                && (destination != .alwaysHidden || alwaysHiddenEnabled)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, direction) in [("Move left", MenuBarIconManager.MoveDirection.towardDrawer), ("Move right", .towardClock)] {
            let item = NSMenuItem(title: title, action: #selector(reorderIcon(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = (icon, direction)
            item.isEnabled = manager?.canMove(icon, toward: direction) == true
            menu.addItem(item)
        }
        return menu
    }

    @objc private func moveIcon(_ sender: NSMenuItem) {
        guard manager?.isUpdatingIcons == false else { return }
        guard let (icon, section) = sender.representedObject as? (MenuBarIconManager.Icon, MenuBarSection) else { return }
        manager?.move(icon, to: section)
    }

    @objc private func reorderIcon(_ sender: NSMenuItem) {
        guard manager?.isUpdatingIcons == false else { return }
        guard let (icon, direction) = sender.representedObject as? (MenuBarIconManager.Icon, MenuBarIconManager.MoveDirection) else { return }
        manager?.move(icon, toward: direction)
    }
}

struct MenuBarDragSettingsAnchor: NSViewRepresentable {
    let controller: MenuBarDragController
    let manager: MenuBarIconManager

    func makeNSView(context: Context) -> MenuBarDragSettingsAnchorView {
        let view = MenuBarDragSettingsAnchorView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: MenuBarDragSettingsAnchorView, context: Context) {
        view.controller = controller
        view.manager = manager
        view.bindWindow()
    }

    static func dismantleNSView(_ view: MenuBarDragSettingsAnchorView, coordinator: ()) { view.controller?.close() }
}

final class MenuBarDragSettingsAnchorView: NSView {
    weak var controller: MenuBarDragController?
    weak var manager: MenuBarIconManager?
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); bindWindow() }
    func bindWindow() {
        if let window, let manager { controller?.open(manager: manager, window: window) }
        else { controller?.close() }
    }
}
