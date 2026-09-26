import AppKit
import ApplicationServices
import Combine

/// Reads the real SystemUIServer menu-bar items and lets the Settings drawer move
/// them across Flux's one shown/hidden boundary.
@MainActor
final class MenuBarIconManager: ObservableObject {
    struct Icon: Identifiable, Equatable {
        let id: String
        let title: String
        let source: String?
        let section: MenuBarSection
        let isMovable: Bool
        let frame: CGRect
    }

    @Published private(set) var icons: [Icon] = []
    @Published private(set) var isTrusted = false
    @Published private(set) var errorMessage: String?

    /// AppDelegate supplies the live Flux boundary after the status items exist.
    var boundaryXProvider: () -> CGFloat? = { nil }
    var beginProvider: () -> Void = {}
    var endProvider: () -> Void = {}

    private var elements: [String: AXUIElement] = [:]

    func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(options)
        if isTrusted { refresh() }
    }

    func beginIconManagement() {
        beginProvider()
        refresh()
    }

    func endIconManagement() {
        endProvider()
    }

    func refresh() {
        isTrusted = AXIsProcessTrusted()
        guard isTrusted else {
            icons = []
            elements.removeAll()
            errorMessage = "Allow Accessibility access to manage menu-bar icons."
            return
        }

        guard let systemUI = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.systemuiserver").first
            ?? NSWorkspace.shared.runningApplications.first(where: {
                $0.localizedName == "SystemUIServer"
            }) else {
            icons = []
            errorMessage = "Flux could not find the macOS menu bar."
            return
        }

        let app = AXUIElementCreateApplication(systemUI.processIdentifier)
        guard let menuBar = elementAttribute(app, kAXMenuBarAttribute) else {
            icons = []
            errorMessage = "Flux could not read the macOS menu bar."
            return
        }

        let boundary = boundaryXProvider()
        var next: [Icon] = []
        var nextElements: [String: AXUIElement] = [:]
        for (index, element) in children(of: menuBar).enumerated() {
            guard stringAttribute(element, kAXRoleAttribute) == (kAXMenuBarItemRole as String),
                  let frame = frame(of: element) else { continue }

            let identifier = stringAttribute(element, kAXIdentifierAttribute)
            let title = stringAttribute(element, kAXTitleAttribute)
                ?? stringAttribute(element, kAXDescriptionAttribute)
                ?? "Menu bar item \(index + 1)"
            let source = stringAttribute(element, kAXHelpAttribute)
            let id = identifier ?? "\(title)|\(source ?? "")|\(index)"
            guard !isFluxItem(identifier: identifier, title: title, source: source) else { continue }

            let section: MenuBarSection
            if let boundary, frame.midX < boundary {
                section = .hidden
            } else {
                section = .shown
            }
            let icon = Icon(id: id,
                            title: title,
                            source: source,
                            section: section,
                            isMovable: true,
                            frame: frame)
            next.append(icon)
            nextElements[id] = element
        }

        icons = next
        elements = nextElements
        errorMessage = nil
    }

    func setSection(_ section: MenuBarSection, for icon: Icon) {
        guard let element = elements[icon.id], let boundary = boundaryXProvider() else {
            refresh()
            return
        }

        let targetX = section == .hidden
            ? boundary - icon.frame.width - 12
            : boundary + 12
        var target = CGPoint(x: targetX, y: icon.frame.minY)
        let positionResult: AXError
        if let value = AXValueCreate(.cgPoint, &target) {
            positionResult = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        } else {
            positionResult = .failure
        }

        if positionResult != .success {
            drag(icon.frame, to: CGPoint(x: targetX + icon.frame.width / 2, y: icon.frame.midY))
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.refresh()
        }
    }

    private func drag(_ frame: CGRect, to target: CGPoint) {
        let start = CGPoint(x: frame.midX, y: frame.midY)
        guard let down = CGEvent(mouseEventSource: nil,
                                 mouseType: .leftMouseDown,
                                 mouseCursorPosition: start,
                                 mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil,
                               mouseType: .leftMouseUp,
                               mouseCursorPosition: target,
                               mouseButton: .left) else { return }
        down.flags = .maskCommand
        down.post(tap: .cghidEventTap)

        for step in 1...5 {
            let progress = CGFloat(step) / 5
            let point = CGPoint(x: start.x + (target.x - start.x) * progress,
                                y: start.y + (target.y - start.y) * progress)
            guard let move = CGEvent(mouseEventSource: nil,
                                     mouseType: .leftMouseDragged,
                                     mouseCursorPosition: point,
                                     mouseButton: .left) else { continue }
            move.flags = .maskCommand
            move.post(tap: .cghidEventTap)
        }
        up.flags = .maskCommand
        up.post(tap: .cghidEventTap)
    }

    private func isFluxItem(identifier: String?, title: String, source: String?) -> Bool {
        [identifier, source, title].compactMap { $0?.lowercased() }
            .contains { $0 == "flux" || $0.contains("flux.") }
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        guard let value = attribute(element, kAXChildrenAttribute) else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    private func elementAttribute(_ element: AXUIElement, _ key: String) -> AXUIElement? {
        guard let value = attribute(element, key) else { return nil }
        return value as! AXUIElement
    }

    private func stringAttribute(_ element: AXUIElement, _ key: String) -> String? {
        attribute(element, key) as? String
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute) as? AXValue,
              let size = attribute(element, kAXSizeAttribute) as? AXValue else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point),
              AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }
}
