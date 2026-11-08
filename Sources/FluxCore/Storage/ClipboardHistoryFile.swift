import Darwin
import Foundation

public enum HistoryFileError: Error {
    case unsafeLocation
}

/// Disk access stays on this actor. Construction and disabled reads do no file work.
public actor ClipboardHistoryFile {
    private let url: URL
    private var enabled = false

    public init(url: URL) { self.url = url }

    public func setPersistenceEnabled(_ enabled: Bool) throws {
        self.enabled = enabled
        if !enabled { try clear() }
    }

    public func load(now: Date) throws -> [SavedClipboardEntry] {
        guard enabled else { return [] }
        guard let data = try read() else { return [] }
        return try ClipboardArchive.decode(data, now: now)
    }

    public func save(_ entries: [SavedClipboardEntry], now: Date) throws {
        guard enabled else { return }
        // Never replace a corrupt or future-format file with an empty history after a failed load.
        if let existing = try read() { _ = try ClipboardArchive.decode(existing, now: now) }
        let data = try ClipboardArchive.encode(entries, now: now)
        try prepareDirectory()
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func clear() throws {
        guard try inspectFile() else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func read() throws -> Data? {
        guard try inspectFile() else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(64 * 1024, ClipboardArchive.maximumBytes + 1 - data.count)),
              !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= ClipboardArchive.maximumBytes else { throw ArchiveError.tooLarge }
        }
        return data
    }

    private func inspectFile() throws -> Bool {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        guard try inspectDirectory(directory) else { return false }
        do {
            let attributes = try manager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
            else { throw HistoryFileError.unsafeLocation }
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return false }
    }

    private func inspectDirectory(_ directory: URL) throws -> Bool {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
            else { throw HistoryFileError.unsafeLocation }
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return false }
    }

    private func prepareDirectory() throws {
        let directory = url.deletingLastPathComponent()
        if try inspectDirectory(directory) == false {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
}
