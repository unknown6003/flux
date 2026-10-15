import AppKit
import SwiftUI

struct MenuBarIconDropZone: NSViewRepresentable {
    let controller: MenuBarDragController
    let section: MenuBarSection

    func makeNSView(context: Context) -> MenuBarDragDestinationView {
        let view = MenuBarDragDestinationView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        view.controller = controller
        view.section = section
        view.wantsLayer = true
        view.layer?.cornerRadius = 6
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.separatorColor.cgColor
        let label = NSTextField(labelWithString: "Drop icons here")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 7, width: 100, height: 16)
        label.autoresizingMask = [.width]
        view.addSubview(label)
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel("Drop icons in \(section.displayName)")
        return view
    }

    func updateNSView(_ view: MenuBarDragDestinationView, context: Context) {
        view.controller = controller
        view.section = section
        view.layer?.borderColor = NSColor.separatorColor.cgColor
    }
}

struct MenuBarIconDragHandle: NSViewRepresentable {
    let controller: MenuBarDragController
    let icon: MenuBarIconManager.Icon

    func makeNSView(context: Context) -> MenuBarDragSourceView {
        let view = controller.makeSourceView(for: icon)
        view.showsHandle = true
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: MenuBarDragSourceView, context: Context) {
        view.controller = controller
        view.icon = icon
        view.toolTip = "Drag \(icon.title) into a section or back to the menu bar"
        view.setAccessibilityLabel("Drag \(icon.title)")
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

    static func dismantleNSView(_ view: MenuBarDragSettingsAnchorView, coordinator: ()) {
        view.controller?.close()
    }
}

final class MenuBarDragSettingsAnchorView: NSView {
    weak var controller: MenuBarDragController?
    weak var manager: MenuBarIconManager?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        bindWindow()
    }

    func bindWindow() {
        if let window, let manager { controller?.open(manager: manager, window: window) }
        else { controller?.close() }
    }
}
