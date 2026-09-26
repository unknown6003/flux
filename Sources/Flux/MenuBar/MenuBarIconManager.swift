import AppKit
import ApplicationServices
import Combine

/// Reads real menu-bar items and lets Settings assign their section and order.
@MainActor
final class MenuBarIconManager: ObservableObject {
    typealias Boundaries = (hidden: CGFloat?, alwaysHidden: CGFloat?)

    enum MoveDirection {
        case towardDrawer
        case towardClock
    }

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

    /// AppDelegate supplies the live boundaries after the status items exist.
    var boundaryProvider: () -> Boundaries = { (nil, nil) }
    var beginProvider: () -> Void = {}
    var endProvider: () -> Void = {}

    private var elements: [String: AXUIElement] = [:]

    /// Called only by the explicit Access button. Normal refreshes never prompt.
    func requestAccess() {
        guard !AXIsProcessTrusted() else {
            refresh()
            return
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(options)
        if isTrusted { refresh() }
    }

    func beginIconManagement() {
        beginProvider()
        refresh()
        refreshAfterLayout(settles: true)
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

        let boundaries = boundaryProvider()
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

            next.append(Icon(id: id,
                             title: title,
                             source: source,
                             section: Self.section(for: frame, boundaries: boundaries),
                             isMovable: true,
                             frame: frame))
            nextElements[id] = element
        }

        icons = next.sorted { $0.frame.minX < $1.frame.minX }
        elements = nextElements
        errorMessage = nil
    }

    func move(_ icon: Icon, to section: MenuBarSection) {
        guard icon.isMovable,
              let targetX = Self.insertionX(for: section,
                                             iconWidth: icon.frame.width,
                                             boundaries: boundaryProvider()) else {
            return
        }
        move(icon, toX: targetX, expectedSection: section)
    }

    func canMove(_ icon: Icon, toward direction: MoveDirection) -> Bool {
        guard icon.isMovable else { return false }
        let siblings = icons
            .filter { $0.section == icon.section }
            .sorted { $0.frame.minX < $1.frame.minX }
        guard let index = siblings.firstIndex(where: { $0.id == icon.id }) else { return false }
        switch direction {
        case .towardDrawer:
            return index > siblings.startIndex
        case .towardClock:
            return index < siblings.index(before: siblings.endIndex)
        }
    }

    /// Moves an icon one place within its current section. The drawer UI owns
    /// order, so the user never has to Cmd-drag a crowded menu bar.
    func move(_ icon: Icon, toward direction: MoveDirection) {
        guard canMove(icon, toward: direction) else { return }
        let siblings = icons
            .filter { $0.section == icon.section }
            .sorted { $0.frame.minX < $1.frame.minX }
        guard let index = siblings.firstIndex(where: { $0.id == icon.id }) else { return }
        let neighbor: Icon
        switch direction {
        case .towardDrawer:
            neighbor = siblings[siblings.index(before: index)]
            move(icon, toX: neighbor.frame.minX - icon.frame.width - 4, expectedSection: icon.section)
        case .towardClock:
            neighbor = siblings[siblings.index(after: index)]
            move(icon, toX: neighbor.frame.maxX + 4, expectedSection: icon.section)
        }
    }

    // Kept for callers from older settings views during an update.
    func setSection(_ section: MenuBarSection, for icon: Icon) {
        move(icon, to: section)
    }

    static func section(for frame: CGRect, boundaries: Boundaries) -> MenuBarSection {
        if let alwaysHidden = boundaries.alwaysHidden, frame.midX < alwaysHidden {
            return .alwaysHidden
        }
        if let hidden = boundaries.hidden, frame.midX < hidden {
            return .hidden
        }
        return .shown
    }

    static func insertionX(for section: MenuBarSection,
                           iconWidth: CGFloat,
                           boundaries: Boundaries,
                           gap: CGFloat = 12) -> CGFloat? {
        switch section {
        case .shown:
            return boundaries.hidden.map { $0 + gap }
        case .hidden:
            if let alwaysHidden = boundaries.alwaysHidden { return alwaysHidden + gap }
            return boundaries.hidden.map { $0 - iconWidth - gap }
        case .alwaysHidden:
            return boundaries.alwaysHidden.map { $0 - iconWidth - gap }
        }
    }

    private func move(_ icon: Icon, toX targetX: CGFloat, expectedSection: MenuBarSection) {
        guard let element = elements[icon.id] else {
            refresh()
            return
        }

        let target = CGPoint(x: targetX, y: icon.frame.minY)
        let usedAccessibility = setPosition(target, on: element)
        if !usedAccessibility {
            drag(icon.frame, to: CGPoint(x: targetX + icon.frame.width / 2,
                                          y: icon.frame.midY))
        }
        verifyMove(icon: icon,
                   expectedSection: expectedSection,
                   target: target,
                   retryWithDrag: usedAccessibility)
    }

    private func setPosition(_ point: CGPoint, on element: AXUIElement) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }

    private func verifyMove(icon: Icon,
                            expectedSection: MenuBarSection,
                            target: CGPoint,
                            retryWithDrag: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self else { return }
            self.refresh()
            guard let current = self.icons.first(where: { $0.id == icon.id }) else { return }
            guard current.section != expectedSection else { return }
            guard retryWithDrag else {
                self.errorMessage = "macOS did not move \(icon.title). Try again."
                return
            }
            self.drag(icon.frame, to: CGPoint(x: target.x + icon.frame.width / 2,
                                               y: icon.frame.midY))
            self.verifyMove(icon: icon,
                            expectedSection: expectedSection,
                            target: target,
                            retryWithDrag: false)
        }
    }

    private func refreshAfterLayout(settles: Bool) {
        let delays: [TimeInterval] = settles ? [0.15, 0.5] : [0]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refresh()
            }
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
        guard let positionValue = attribute(element, kAXPositionAttribute),
              let sizeValue = attribute(element, kAXSizeAttribute) else { return nil }
        let position = positionValue as! AXValue
        let size = sizeValue as! AXValue
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
