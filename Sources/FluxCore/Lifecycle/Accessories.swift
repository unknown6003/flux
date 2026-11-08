import Foundation

public enum AccessoryKind: Sendable { case audio, keyboard, mouse, controller, other }

/// A session-local display identity. This is not a hardware address or a
/// stable analytics identifier. Multiple OS sources can report one name.
public struct Accessory: Equatable, Sendable {
    public let key: String
    public let name: String
    public let kind: AccessoryKind
    public let percent: Int?

    public init(name: String, kind: AccessoryKind, percent: Int?) {
        self.name = String(name.prefix(200))
        key = self.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        self.kind = kind
        self.percent = percent.map { min(max($0, 0), 100) }
    }

    public var symbol: String {
        switch kind {
        case .audio: return name.lowercased().contains("airpods") ? "airpodspro" : "headphones"
        case .keyboard: return "keyboard"
        case .mouse: return "computermouse"
        case .controller: return "gamecontroller"
        case .other: return "cable.connector"
        }
    }
}

public enum AccessoryConnection: Equatable, Sendable {
    case connected(Accessory), disconnected(Accessory)
}

/// Unknown and empty inventories are different states. Neither OS source can
/// establish a complete baseline on behalf of the other source.
public struct AccessoryInventory: Sendable {
    public enum Source: Hashable, Sendable { case registry, audio }
    private var sources: [Source: [Accessory]] = [:]
    public init() {}

    @discardableResult public mutating func accept(_ snapshot: [Accessory]?, from source: Source) -> [Accessory]? {
        if let snapshot, snapshot.count <= 256 { sources[source] = snapshot }
        return current
    }

    public var current: [Accessory]? {
        guard let audio = sources[.audio], let registry = sources[.registry] else { return nil }
        var merged: [String: Accessory] = [:]
        for accessory in audio + registry where !accessory.key.isEmpty {
            if merged[accessory.key]?.percent != nil { continue }
            merged[accessory.key] = accessory
        }
        guard merged.count <= 256 else { return nil }
        return merged.values.sorted { $0.key < $1.key }
    }
}

/// First known inventory is a baseline, not a connection burst. A failed read
/// preserves the prior inventory. Alias removal cannot disconnect an accessory
/// still present through another OS source.
public struct AccessoryPresence: Sendable {
    private var known: [String: Accessory]?
    public init() {}

    public mutating func accept(_ snapshot: [Accessory]?) -> [AccessoryConnection] {
        guard let snapshot else { return [] }
        var next: [String: Accessory] = [:]
        for accessory in snapshot.prefix(256) where !accessory.key.isEmpty {
            if let current = next[accessory.key], current.percent != nil { continue }
            next[accessory.key] = accessory
        }
        defer { known = next }
        guard let known else { return [] }
        let removed = known.keys.filter { next[$0] == nil }.sorted().compactMap { known[$0] }.map(AccessoryConnection.disconnected)
        let added = next.keys.filter { known[$0] == nil }.sorted().compactMap { next[$0] }.map(AccessoryConnection.connected)
        return removed + added
    }
}
