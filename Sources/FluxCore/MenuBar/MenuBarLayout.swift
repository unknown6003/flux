import CoreGraphics

/// One status item: its owner app and its place in the owner's own item list.
public struct MenuBarItemID: Hashable, Sendable {
    public let application: ApplicationID
    public let index: Int

    public init(application: ApplicationID, index: Int) {
        self.application = application
        self.index = index
    }

    /// A compact string for drag pasteboards. Bundle IDs never contain "#".
    public var token: String { "\(application.rawValue)#\(index)" }

    public init?(token: String) {
        let parts = token.split(separator: "#", omittingEmptySubsequences: false)
        guard parts.count == 2, let application = ApplicationID(rawValue: String(parts[0])),
              let index = Int(parts[1]), index >= 0 else { return nil }
        self.init(application: application, index: index)
    }
}

/// An item as the Accessibility read found it. Frames use Quartz points.
public struct MenuBarLayoutItem: Equatable, Sendable {
    public let id: MenuBarItemID
    public let frame: CGRect
    /// System and Flux items can be neighbours, but Flux never drags them.
    public let isMovable: Bool

    public init(id: MenuBarItemID, frame: CGRect, isMovable: Bool? = nil) {
        self.id = id
        self.frame = frame
        self.isMovable = isMovable ?? !id.application.isManagedBySystem
    }
}

/// How an item's group is decided.
public enum MenuBarGrouping: Equatable, Sendable {
    /// macOS 27: MenuBarAgent hides whole apps, so the saved policy decides.
    /// With Always Hidden off, its apps count as Hidden.
    case perApplication(VisibilityPolicy, alwaysHiddenEnabled: Bool)
    /// macOS 14 to 26: Flux's boundary items decide. Nil `always` means the
    /// Always Hidden group is off.
    case byPosition(hidden: CGRect, always: CGRect?)
    /// Hiding is not active. Every item counts as visible.
    case none
}

/// The physical menu bar, left to right, with a group for each item.
public struct MenuBarLayout: Equatable, Sendable {
    public let items: [MenuBarLayoutItem]
    public let grouping: MenuBarGrouping
    public let chevronBoundary: CGRect?

    public init(items: [MenuBarLayoutItem], grouping: MenuBarGrouping, chevronBoundary: CGRect? = nil) {
        self.items = items.sorted { ($0.frame.minX, $0.id.index) < ($1.frame.minX, $1.id.index) }
        self.grouping = grouping
        self.chevronBoundary = chevronBoundary
    }

    public func item(_ id: MenuBarItemID) -> MenuBarLayoutItem? { items.first { $0.id == id } }

    public func group(of item: MenuBarLayoutItem) -> MenuBarGroup {
        switch grouping {
        case .perApplication(let policy, let alwaysHiddenEnabled):
            let group = policy.group(for: item.id.application)
            return group == .alwaysHidden && !alwaysHiddenEnabled ? .hidden : group
        case .none: return .shown
        case .byPosition(let hidden, let always):
            if item.frame.midX >= hidden.midX { return .shown }
            if let always, item.frame.midX < always.midX { return .alwaysHidden }
            return .hidden
        }
    }

    /// Items of one group, left to right.
    public func strip(_ group: MenuBarGroup) -> [MenuBarLayoutItem] {
        items.filter { self.group(of: $0) == group }
    }
}

/// A request from the layout editor: put `item` in `group`, between `left`
/// and `right`. Nil neighbours mean the strip end, or an empty strip.
public struct MenuBarItemMove: Equatable, Sendable {
    public let item: MenuBarItemID
    public let group: MenuBarGroup
    public let left: MenuBarItemID?
    public let right: MenuBarItemID?

    public init(item: MenuBarItemID, group: MenuBarGroup, left: MenuBarItemID?, right: MenuBarItemID?) {
        self.item = item
        self.group = group
        self.left = left
        self.right = right
    }
}

/// Why one move stopped. The UI maps each case to one short sentence.
public enum MenuBarMoveFailure: Error, Equatable, Sendable {
    case accessibilityRequired
    case itemGone
    case itemLocked
    case neighbourGone
    case alwaysHiddenOff
    case hidingUnavailable
    case inputBusy
    case boundaryUnavailable
    case eventsUnavailable
    case groupNotSaved(code: String)
    case notAccepted
}

/// Where the Cmd-drag must put the item.
public enum MenuBarMoveTarget: Equatable, Sendable {
    case leftOf(MenuBarItemID)
    case rightOf(MenuBarItemID)
    /// An empty strip in by-position mode: next to Flux's boundary item.
    case boundary(MenuBarGroup)
    /// A policy-only layout without a physical anchor.
    case none
}

public struct MenuBarMovePlan: Equatable, Sendable {
    public let move: MenuBarItemMove
    public let target: MenuBarMoveTarget
}

/// Pure planning and checking for one move. No AppKit, no events.
public enum MenuBarMovePlanner {
    /// The plan for a move, or nil when the item is already in place.
    public static func plan(_ move: MenuBarItemMove, in layout: MenuBarLayout) throws(MenuBarMoveFailure) -> MenuBarMovePlan? {
        guard let item = layout.item(move.item) else { throw .itemGone }
        guard item.isMovable else { throw .itemLocked }
        for neighbour in [move.left, move.right].compactMap({ $0 }) {
            guard neighbour != move.item, layout.item(neighbour) != nil else { throw .neighbourGone }
        }
        switch layout.grouping {
        case .none:
            guard move.group == .shown else { throw .hidingUnavailable }
        case .byPosition(_, let always):
            if move.group == .alwaysHidden, always == nil { throw .alwaysHiddenOff }
        case .perApplication(_, let alwaysHiddenEnabled):
            if move.group == .alwaysHidden, !alwaysHiddenEnabled { throw .alwaysHiddenOff }
        }
        if isPlaced(move, in: layout) { return nil }
        let target: MenuBarMoveTarget
        if let right = move.right, anchorIsOnRequestedSide(right, move: move, layout: layout) { target = .leftOf(right) }
        else if let left = move.left, anchorIsOnRequestedSide(left, move: move, layout: layout) { target = .rightOf(left) }
        else if case .perApplication = layout.grouping, layout.chevronBoundary != nil { target = .boundary(move.group) }
        else if case .byPosition = layout.grouping { target = .boundary(move.group) }
        else { target = .none }
        return MenuBarMovePlan(move: move, target: target)
    }

    /// True when the item is in the requested group and its strip neighbours
    /// are the requested ones. Other items of the same app are skipped unless
    /// they are the named neighbours, because per-app groups move them too.
    public static func isPlaced(_ move: MenuBarItemMove, in layout: MenuBarLayout) -> Bool {
        guard let item = layout.item(move.item), layout.group(of: item) == move.group else { return false }
        if case .perApplication = layout.grouping, let boundary = layout.chevronBoundary,
           !isOnSide(item.frame, of: boundary, group: move.group) { return false }
        let named: Set<MenuBarItemID> = Set([move.left, move.right].compactMap { $0 })
        let strip = layout.strip(move.group).filter {
            $0.id == move.item || $0.id.application != move.item.application || named.contains($0.id)
        }
        guard let index = strip.firstIndex(where: { $0.id == move.item }) else { return false }
        let left = index > strip.startIndex ? strip[index - 1].id : nil
        let right = index + 1 < strip.endIndex ? strip[index + 1].id : nil
        // An empty-strip request is met once the item is in the group.
        if move.left == nil, move.right == nil, case .perApplication = layout.grouping { return true }
        return left == move.left && right == move.right
    }

    private static func isOnSide(_ frame: CGRect, of boundary: CGRect, group: MenuBarGroup) -> Bool {
        guard !boundary.isNull, !boundary.isInfinite, boundary.width > 0, boundary.height > 0 else { return false }
        // Adjacent owner AX rectangles can overlap the Flux button. Require
        // the item's centre to clear the button, rather than its whole frame.
        return group == .shown ? frame.midX >= boundary.maxX : frame.midX <= boundary.minX
    }

    private static func anchorIsOnRequestedSide(_ id: MenuBarItemID, move: MenuBarItemMove,
                                               layout: MenuBarLayout) -> Bool {
        guard case .perApplication = layout.grouping, let boundary = layout.chevronBoundary else { return true }
        guard let anchor = layout.item(id) else { return false }
        return isOnSide(anchor.frame, of: boundary, group: move.group)
    }

    /// Start and end points of the Cmd-drag, in Quartz points. Attempts use
    /// different drop points, so a retry does not repeat a refused gesture.
    public static func dragPoints(for plan: MenuBarMovePlan, in layout: MenuBarLayout,
                                  attempt: Int) -> (from: CGPoint, to: CGPoint)? {
        guard let item = layout.item(plan.move.item) else { return nil }
        let anchor: CGRect
        let leftSide: Bool
        switch plan.target {
        case .none: return nil
        case .leftOf(let id):
            guard let frame = layout.item(id)?.frame else { return nil }
            anchor = frame; leftSide = true
        case .rightOf(let id):
            guard let frame = layout.item(id)?.frame else { return nil }
            anchor = frame; leftSide = false
        case .boundary(let group):
            switch layout.grouping {
            case .byPosition(let hidden, let always):
                switch group {
                case .shown: anchor = hidden; leftSide = false
                case .hidden: anchor = hidden; leftSide = true
                case .alwaysHidden:
                    guard let always else { return nil }
                    anchor = always; leftSide = true
                }
            case .perApplication:
                guard let boundary = layout.chevronBoundary else { return nil }
                anchor = boundary; leftSide = group != .shown
            case .none: return nil
            }
        }
        let offsets: [CGFloat] = [4, anchor.width * 0.35, 1]
        let offset = min(offsets[min(max(attempt, 0), offsets.count - 1)], anchor.width / 2)
        let x = leftSide ? anchor.midX - offset : anchor.midX + offset
        return (CGPoint(x: item.frame.midX, y: item.frame.midY), CGPoint(x: x, y: anchor.midY))
    }
}
