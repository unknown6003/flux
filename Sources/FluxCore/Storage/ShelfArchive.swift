import Foundation

public struct ShelvedFile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let fileName: String
    public let addedAt: Date

    public init(id: UUID = UUID(), fileName: String, addedAt: Date) throws {
        guard Self.validName(fileName) else { throw ArchiveError.invalidRecord }
        self.id = id
        self.fileName = fileName
        self.addedAt = addedAt
    }

    public func directory(in root: URL) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func url(in root: URL) -> URL { directory(in: root).appendingPathComponent(fileName) }

    private static func validName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\0")
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: container.decode(UUID.self, forKey: .id),
                      fileName: container.decode(String.self, forKey: .fileName),
                      addedAt: container.decode(Date.self, forKey: .addedAt))
    }
}

public enum ShelfArchive {
    public static let maximumBytes = 8 * 1024 * 1024

    /// Read without moving, pruning or renaming any payload. Dates retain the old reference epoch.
    public static func decode(_ data: Data) throws -> [ShelvedFile] {
        guard data.count <= maximumBytes else { throw ArchiveError.tooLarge }
        let records = try JSONDecoder().decode([ShelvedFile].self, from: data)
        guard Set(records.map(\.id)).count == records.count else { throw ArchiveError.invalidRecord }
        return records.sorted { $0.addedAt > $1.addedAt }
    }

    public static func encode(_ records: [ShelvedFile]) throws -> Data {
        guard Set(records.map(\.id)).count == records.count else { throw ArchiveError.invalidRecord }
        let data = try JSONEncoder().encode(records)
        guard data.count <= maximumBytes else { throw ArchiveError.tooLarge }
        return data
    }
}
