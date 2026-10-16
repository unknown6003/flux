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
        let width = proposal.width ?? 500
        let columns = width >= 460 ? 2 : 1
        let rows = max(1, (icons.count + columns - 1) / columns)
        return CGSize(width: width, height: CGFloat(rows * 46 + 52))
    }
}

@MainActor
final class MenuBarIconLaneView: MenuBarDragDestinationView {
    private var icons: [MenuBarIconManager.Icon] = []
    private weak var manager: MenuBarIconManager?
    private var alwaysHiddenEnabled = true
    override var isFlipped: Bool { true }

    func configure(controller: MenuBarDragController, manager: MenuBarIconManager,
                   section: MenuBarSection, icons: [MenuBarIconManager.Icon], alwaysHiddenEnabled: Bool) {
        self.controller = controller
        self.manager = manager
        self.section = section
        acceptsDrops = section != .alwaysHidden || alwaysHiddenEnabled
        guard !controller.isDragging else { return }
        let changed = self.icons != icons || self.alwaysHiddenEnabled != alwaysHiddenEnabled || subviews.isEmpty
        self.icons = icons
        self.alwaysHiddenEnabled = alwaysHiddenEnabled
        if changed {
            subviews.forEach { $0.removeFromSuperview() }
            for icon in icons {
                let source = controller.makeSourceView(for: icon)
                source.showsHandle = true
                source.showsLabel = true
                source.toolTip = icon.isMovable ? "Drag \(icon.title) to another section" : icon.source
                source.setAccessibilityElement(true)
                source.setAccessibilityRole(.image)
                source.setAccessibilityLabel(icon.isMovable ? "Drag \(icon.title)" : icon.title)
                addSubview(source)
                let menu = NSPopUpButton(frame: .zero, pullsDown: true)
                menu.bezelStyle = .rounded
                menu.controlSize = .small
                menu.font = .systemFont(ofSize: 11)
                menu.addItem(withTitle: icon.isMovable ? "Move" : "Fixed")
                if icon.isMovable {
                    for destination in MenuBarSection.allCases {
                        let item = NSMenuItem(title: destination.displayName,
                                              action: #selector(moveIcon(_:)), keyEquivalent: "")
                        item.target = self
                        item.representedObject = (icon, destination)
                        item.isEnabled = destination != icon.section && (destination != .alwaysHidden || alwaysHiddenEnabled)
                        menu.menu?.addItem(item)
                    }
                    menu.menu?.addItem(.separator())
                    for (title, direction) in [("Move left", MenuBarIconManager.MoveDirection.towardDrawer),
                                               ("Move right", .towardClock)] {
                        let item = NSMenuItem(title: title, action: #selector(reorderIcon(_:)), keyEquivalent: "")
                        item.target = self
                        item.representedObject = (icon, direction)
                        item.isEnabled = manager.canMove(icon, toward: direction)
                        menu.menu?.addItem(item)
                    }
                }
                menu.menu?.autoenablesItems = false
                menu.setAccessibilityLabel("Move \(icon.title)")
                addSubview(menu)
            }
        }
        for (index, menu) in subviews.compactMap({ $0 as? NSPopUpButton }).enumerated() {
            menu.isEnabled = !manager.isUpdatingIcons && icons[index].isMovable
        }
        setAccessibilityElement(false)
        setAccessibilityLabel("\(section.displayName), \(icons.count) icons. Drop icons here.")
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let columns = bounds.width >= 460 ? 2 : 1
        let width = (bounds.width - 20 - CGFloat(columns - 1) * 8) / CGFloat(columns)
        for index in icons.indices {
            let x = 10 + CGFloat(index % columns) * (width + 8)
            let y = 42 + CGFloat(index / columns) * 46
            subviews[index * 2].frame = NSRect(x: x, y: y, width: max(0, width - 76), height: 40)
            subviews[index * 2 + 1].frame = NSRect(x: x + width - 76, y: y + 8, width: 76, height: 24)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.surfaceRaised.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9).fill()
        Theme.zone(section).setFill()
        NSBezierPath(ovalIn: NSRect(x: 12, y: 14, width: 7, height: 7)).fill()
        ((section.displayName + (acceptsDrops ? "" : " (off)")) as NSString).draw(at: NSPoint(x: 26, y: 9), withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: Theme.textPrimary
        ])
        ("\(icons.count)" as NSString).draw(at: NSPoint(x: bounds.width - 28, y: 9), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: Theme.textSecondary
        ])
        (section.subtitle as NSString).draw(at: NSPoint(x: 26, y: 27), withAttributes: [
            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: Theme.textSecondary
        ])
        if icons.isEmpty {
            ("Drop icons here" as NSString).draw(at: NSPoint(x: 26, y: 63), withAttributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.textSecondary
            ])
        }
        super.draw(dirtyRect)
    }

    @objc private func moveIcon(_ sender: NSMenuItem) {
        guard let (icon, section) = sender.representedObject as? (MenuBarIconManager.Icon, MenuBarSection) else { return }
        manager?.move(icon, to: section)
    }

    @objc private func reorderIcon(_ sender: NSMenuItem) {
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
