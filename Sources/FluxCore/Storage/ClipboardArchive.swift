import Foundation

public enum SavedClipboardKind: String, Codable, Sendable {
    case text, url, color
}

public struct SavedClipboardEntry: Codable, Equatable, Sendable {
    public let capturedAt: Date
    public let kind: SavedClipboardKind
    public let text: String

    public init(capturedAt: Date, kind: SavedClipboardKind, text: String) {
        self.capturedAt = capturedAt
        self.kind = kind
        self.text = text
    }
}

public enum ArchiveError: Error {
    case unsupportedVersion, tooLarge, invalidRecord
}

/// The old version-one format persists text only. Image and file payloads cannot enter it.
public enum ClipboardArchive {
    public static let maximumBytes = 1_000_000
    public static let maximumEntries = 50
    public static let maximumCharacters = 32_000
    public static let retention: TimeInterval = 30 * 24 * 60 * 60

    private struct Envelope: Codable {
        let version: Int
        let entries: [Record]
    }

    private struct Record: Codable {
        let capturedAt: Date
        let kind: String
        let text: String
    }

    public static func decode(_ data: Data, now: Date) throws -> [SavedClipboardEntry] {
        guard data.count <= maximumBytes else { throw ArchiveError.tooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(Envelope.self, from: data)
        guard envelope.version == 1 else { throw ArchiveError.unsupportedVersion }
        return envelope.entries.compactMap { record in
            guard let kind = SavedClipboardKind(rawValue: record.kind),
                  !record.text.isEmpty, record.text.count <= maximumCharacters,
                  record.capturedAt >= now.addingTimeInterval(-retention) else { return nil }
            return SavedClipboardEntry(capturedAt: record.capturedAt, kind: kind, text: record.text)
        }.sorted { $0.capturedAt > $1.capturedAt }.prefix(maximumEntries).map { $0 }
    }

    public static func encode(_ entries: [SavedClipboardEntry], now: Date) throws -> Data {
        let cutoff = now.addingTimeInterval(-retention)
        var records = entries.filter { $0.capturedAt >= cutoff && !$0.text.isEmpty }
            .sorted { $0.capturedAt > $1.capturedAt }.prefix(maximumEntries).compactMap { entry -> Record? in
                if entry.text.count > maximumCharacters {
                    guard entry.kind != .url else { return nil }
                    return Record(capturedAt: entry.capturedAt, kind: entry.kind.rawValue,
                                  text: String(entry.text.prefix(maximumCharacters - 1)) + "…")
                }
                return Record(capturedAt: entry.capturedAt, kind: entry.kind.rawValue, text: entry.text)
            }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        while true {
            let data = try encoder.encode(Envelope(version: 1, entries: records))
            if data.count <= maximumBytes { return data }
            guard !records.isEmpty else { throw ArchiveError.tooLarge }
            records.removeLast()
        }
    }
}
