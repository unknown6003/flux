import Foundation

/// A stable AX identifier, plus the publishing app's possible preference owners.
public struct MenuBarPositionIdentity: Sendable {
    public let item: MenuBarItemID
    public let owners: [String]
    public let identifier: String?
    public let siblingCount: Int
    public let legacyPositions: [String: Double]

    public init(item: MenuBarItemID, owners: [String], identifier: String?, siblingCount: Int,
                legacyPositions: [String: Double] = [:]) {
        self.item = item; self.owners = owners; self.identifier = identifier; self.siblingCount = siblingCount
        self.legacyPositions = legacyPositions
    }

    public static func key(for item: MenuBarItemID, in items: [Self], keys: Set<String>) throws(MenuBarMoveFailure) -> String {
        guard let identity = items.first(where: { $0.item == item }) else { throw .itemGone }
        if item.application.rawValue == "com.apple.MenuBarAgent" {
            if identity.identifier == "com.apple.menuextra.clock", keys.contains("module:Clock") { return "module:Clock" }
            if identity.identifier == "com.apple.menuextra.controlcenter" {
                let bento = keys.filter { $0.hasPrefix("module:BentoBox-") }
                if bento.count == 1, let key = bento.first { return key }
            }
        }
        let primary = "status:\(item.application.rawValue)::"
        var candidates = keys.filter { $0.hasPrefix(primary) }
        if candidates.isEmpty {
            let owners = Set(identity.owners).filter { owner in
                !owner.isEmpty && !owner.contains("::") && Set(items.filter {
                    $0.owners.contains(owner)
                }.map { $0.item.application }).count == 1
            }
            candidates = keys.filter { key in owners.contains { key.hasPrefix("status:\($0)::") } }
        }
        if let identifier = identity.identifier, !identifier.isEmpty {
            let exact = candidates.filter { $0.hasSuffix("::" + identifier) }
            if exact.count == 1, let key = exact.first { return key }
        }
        let legacy = identity.legacyPositions.filter {
            !$0.key.isEmpty && $0.key.utf8.count <= 256 && !$0.key.contains("::")
                && $0.value.isFinite && $0.value >= 0
        }
        let names = identity.identifier.flatMap { legacy[$0] != nil ? [$0] : nil }
            ?? (identity.siblingCount == 1 && legacy.count == 1 ? Array(legacy.keys) : [])
        if names.count == 1, let name = names.first {
            let exact = candidates.filter { $0.hasSuffix("::" + name) }
            if exact.count == 1, let key = exact.first { return key }
            if exact.isEmpty { return primary + name }
        }
        guard identity.siblingCount == 1, candidates.count == 1, let key = candidates.first else { throw .positionIdentityUnavailable }
        return key
    }
}

/// macOS stores distance from the right edge, so larger values sort left.
public enum MenuBarPositionOrder {
    public static func isPlaced<Item: Hashable>(item: Item, left: Item?, right: Item?, positions: [Item: Double]) -> Bool {
        guard let value = positions[item], value.isFinite, value >= 0,
              left != item, right != item, left == nil || left != right else { return false }
        if let left { guard let bound = positions[left], bound.isFinite, bound > value else { return false } }
        if let right { guard let bound = positions[right], bound.isFinite, bound >= 0, bound < value else { return false } }
        return true
    }

    public static func weight(item: String, left: String?, right: String?, positions: [String: Double]) throws(MenuBarMoveFailure) -> Double {
        guard let current = positions[item], current.isFinite, current >= 0 else { throw .positionIdentityUnavailable }
        guard left != item, right != item, left == nil || left != right else { throw .neighbourGone }
        func value(_ key: String?) throws(MenuBarMoveFailure) -> Double? {
            guard let key else { return nil }
            guard let value = positions[key], value.isFinite, value >= 0 else { throw .neighbourGone }
            return value
        }
        let l = try value(left), r = try value(right)
        let other = positions.filter { $0.key != item }.values.filter { $0.isFinite && $0 >= 0 }
        let upper: Double
        let lower: Double
        switch (l, r) {
        case let (l?, r?): upper = l; lower = r
        case let (l?, nil): upper = l; lower = other.filter { $0 < l }.max() ?? 0
        case let (nil, r?): lower = r; upper = other.filter { $0 > r }.min() ?? (r + 64)
        case (nil, nil): return current
        }
        let next = lower + (upper - lower) / 2
        guard next.isFinite, next > lower, next < upper else { throw .notAccepted }
        return next
    }
}
