import Darwin
import Foundation

public enum ShelfFileError: Error { case unsafeLocation, missingItem, unsupportedSource, changedManifest }

/// A lazy file store. It copies into UUID-owned folders, never moves or
/// deletes an original, and keeps unrelated or orphaned folders untouched.
public actor ShelfFiles {
    private let root: URL
    private var records: [ShelvedFile]?
    private var manifestData: Data?

    public init(root: URL) { self.root = root }

    public func load() throws -> [ShelvedFile] {
        if let records { return records }
        guard try directoryExists(root) else { records = []; return [] }
        let manifest = root.appendingPathComponent("manifest.json")
        guard let data = try readManifest(manifest) else { records = []; return [] }
        let saved = try ShelfArchive.decode(data)
        var found: [ShelvedFile] = []
        for record in saved {
            guard try directoryExists(record.directory(in: root)) else { continue }
            if FileManager.default.fileExists(atPath: record.url(in: root).path) { found.append(record) }
        }
        records = found
        manifestData = data
        return found
    }

    public func reload() throws -> [ShelvedFile] {
        records = nil
        manifestData = nil
        return try load()
    }

    public func addCopy(of source: URL, at date: Date = .now) throws -> ShelvedFile {
        guard source.isFileURL else { throw ShelfFileError.unsupportedSource }
        let previous = try load()
        let item = try ShelvedFile(fileName: source.lastPathComponent, addedAt: date)
        try prepareRoot()
        let destination = item.directory(in: root)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        var saved = false
        defer {
            if !saved { try? FileManager.default.removeItem(at: destination) }
        }
        try FileManager.default.copyItem(at: source, to: item.url(in: root))
        let next = ([item] + previous).sorted { $0.addedAt > $1.addedAt }
        try save(next)
        records = next
        saved = true
        return item
    }

    public func payload(for id: UUID) throws -> URL {
        guard let item = try load().first(where: { $0.id == id }),
              try directoryExists(root), try directoryExists(item.directory(in: root)),
              FileManager.default.fileExists(atPath: item.url(in: root).path) else { throw ShelfFileError.missingItem }
        return item.url(in: root)
    }

    public func remove(_ ids: Set<UUID>) throws {
        let previous = try load()
        let removed = previous.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        // Validate every folder before either a manifest write or a deletion.
        for item in removed { _ = try directoryExists(item.directory(in: root)) }
        let next = previous.filter { !ids.contains($0.id) }
        try save(next)
        records = next
        for item in removed {
            let directory = item.directory(in: root)
            if try directoryExists(directory) { try FileManager.default.removeItem(at: directory) }
        }
    }

    public func clear() throws { try remove(Set(load().map(\.id))) }

    public func expire(olderThan cutoff: Date) throws {
        try remove(Set(load().filter { $0.addedAt < cutoff }.map(\.id)))
    }

    private func save(_ items: [ShelvedFile]) throws {
        // Revalidate the current on-disk format before replacing it. A file
        // changed to an unknown schema while Flux ran must remain recoverable.
        let existing = try readManifest(root.appendingPathComponent("manifest.json"))
        if let data = existing {
            _ = try ShelfArchive.decode(data)
        }
        guard existing == manifestData else { throw ShelfFileError.changedManifest }
        try prepareRoot()
        let manifest = root.appendingPathComponent("manifest.json")
        let data = try ShelfArchive.encode(items)
        try data.write(to: manifest, options: .atomic)
        manifestData = data
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
    }

    private func prepareRoot() throws {
        if try !directoryExists(root) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }

    private func directoryExists(_ url: URL) throws -> Bool {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                throw ShelfFileError.unsafeLocation
            }
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return false }
    }

    private func readManifest(_ url: URL) throws -> Data? {
        guard try directoryExists(root) else { return nil }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                throw ShelfFileError.unsafeLocation
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65536, ShelfArchive.maximumBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= ShelfArchive.maximumBytes else { throw ArchiveError.tooLarge }
        }
        return data
    }
}
