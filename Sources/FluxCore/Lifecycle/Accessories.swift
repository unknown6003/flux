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
