import AppKit
import ApplicationServices
import FluxCore

public struct RunningApplication: Sendable {
    public let id: ApplicationID
    public let processID: pid_t
    public let name: String
    public let bundleURL: URL?

    @MainActor public static func snapshot() -> [RunningApplication] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated, let raw = app.bundleIdentifier,
                  let id = ApplicationID(rawValue: raw) else { return nil }
            return RunningApplication(id: id, processID: app.processIdentifier,
                                      name: app.localizedName ?? raw, bundleURL: app.bundleURL)
        }
    }
}

/// Owner-reported geometry is useful for a guided arrange result. It is not
/// proof that an item is currently visible, hit-testable or unobstructed.
public struct StatusItemGeometry: Sendable {
    public let frame: CGRect?
}

public struct StatusApplication: Sendable {
    public let application: RunningApplication
    public let items: [StatusItemGeometry]
}

public struct StatusInventorySnapshot: Sendable {
    public let applications: [StatusApplication]
    public let accessibilityAllowed: Bool
    public let complete: Bool
}

public struct StatusPreviewDisplayBounds: Sendable {
    public let id: CGDirectDisplayID
    public let frame: CGRect
    public init(id: CGDirectDisplayID, frame: CGRect) { self.id = id; self.frame = frame }
}

/// AX calls run on this actor, never on the main actor. Each object gets an
/// IPC timeout. Each scan also has a wall-clock and element budget. It reads
/// no titles, values, menus, windows, actions or user content.
public actor StatusInventory {
    public init() {}

    /// One item's capture region, on exactly one display's menu bar band.
    public static func previewRegion(frame: CGRect, displays: [StatusPreviewDisplayBounds]) -> StatusPreviewRegion? {
        guard frame.size.width > 0, frame.size.width <= 256, frame.size.height > 0, frame.size.height <= 64,
              [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height].allSatisfy(\.isFinite) else { return nil }
        let matches = displays.filter { display in
            display.frame.size.width > 0 && display.frame.size.height > 0
                && display.frame.contains(frame) && frame.maxY <= display.frame.minY + 64
        }
        guard matches.count == 1, let display = matches.first else { return nil }
        return .init(id: UUID(), displayID: display.id, frame: frame)
    }

    public func read(_ running: [RunningApplication]) -> StatusInventorySnapshot {
        guard AXIsProcessTrusted() else {
            return .init(applications: [], accessibilityAllowed: false, complete: false)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var results: [StatusApplication] = []
        var complete = running.count <= 128
        var visited = 0
        for application in running.prefix(128) {
            guard !Task.isCancelled, ContinuousClock.now < deadline, visited < 512 else {
                complete = false
                break
            }
            let owner = AXUIElementCreateApplication(application.processID)
            var items: [AXUIElement] = []
            var ownerComplete = true
            for attribute in [kAXExtrasMenuBarAttribute, kAXMenuBarAttribute] {
                guard let bar = element(owner, attribute, deadline: deadline, complete: &ownerComplete) else { continue }
                let descendants = children(bar, deadline: deadline, complete: &ownerComplete)
                for child in descendants.prefix(128) {
                    guard ContinuousClock.now < deadline, visited < 512 else {
                        ownerComplete = false
                        break
                    }
                    visited += 1
                    let role = value(child, kAXRoleAttribute, deadline: deadline, complete: &ownerComplete) as? String
                    let subrole = value(child, kAXSubroleAttribute, deadline: deadline, complete: &ownerComplete) as? String
                    guard role == kAXMenuBarItemRole, subrole == "AXMenuExtra" else { continue }
                    if !items.contains(where: { CFEqual($0, child) }) { items.append(child) }
                }
                if descendants.count > 128 { ownerComplete = false }
            }
            if !items.isEmpty {
                let frames = items.map { item in
                    StatusItemGeometry(frame: frame(item, deadline: deadline, complete: &ownerComplete))
                }
                results.append(.init(application: application, items: frames))
            }
            complete = complete && ownerComplete
        }
        return .init(applications: results, accessibilityAllowed: true, complete: complete)
    }

    private func value(_ element: AXUIElement, _ attribute: String,
                       deadline: ContinuousClock.Instant, complete: inout Bool) -> CFTypeRef? {
        guard !Task.isCancelled, ContinuousClock.now < deadline else {
            complete = false
            return nil
        }
        // Apple defines this timeout per AX object, not per equivalent element.
        guard AXUIElementSetMessagingTimeout(element, 0.08) == .success else {
            complete = false
            return nil
        }
        var output: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &output)
        if error == .cannotComplete || error == .invalidUIElement { complete = false }
        return error == .success ? output : nil
    }

    private func element(_ owner: AXUIElement, _ attribute: String,
                         deadline: ContinuousClock.Instant, complete: inout Bool) -> AXUIElement? {
        guard let raw = value(owner, attribute, deadline: deadline, complete: &complete),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }

    private func children(_ owner: AXUIElement, deadline: ContinuousClock.Instant,
                          complete: inout Bool) -> [AXUIElement] {
        guard !Task.isCancelled, ContinuousClock.now < deadline else {
            complete = false
            return []
        }
        guard AXUIElementSetMessagingTimeout(owner, 0.08) == .success else {
            complete = false
            return []
        }
        var count: CFIndex = 0
        let countResult = AXUIElementGetAttributeValueCount(owner, kAXChildrenAttribute as CFString, &count)
        guard countResult == .success else {
            if countResult == .cannotComplete { complete = false }
            return []
        }
        guard count > 0 else { return [] }
        if count > 128 { complete = false }
        var output: CFArray?
        let error = AXUIElementCopyAttributeValues(owner, kAXChildrenAttribute as CFString,
                                                  0, min(count, 128), &output)
        guard error == .success, let output else {
            complete = false
            return []
        }
        return (output as [AnyObject]).compactMap { child in
            guard CFGetTypeID(child) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(child, to: AXUIElement.self)
        }
    }

    private func frame(_ item: AXUIElement, deadline: ContinuousClock.Instant,
                       complete: inout Bool) -> CGRect? {
        guard let position = value(item, kAXPositionAttribute, deadline: deadline, complete: &complete),
              let size = value(item, kAXSizeAttribute, deadline: deadline, complete: &complete),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        let positionValue = unsafeBitCast(position, to: AXValue.self)
        let sizeValue = unsafeBitCast(size, to: AXValue.self)
        guard AXValueGetType(positionValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point), AXValueGetValue(sizeValue, .cgSize, &extent),
              point.x.isFinite, point.y.isFinite, extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0 else { return nil }
        return CGRect(origin: point, size: extent)
    }
}
