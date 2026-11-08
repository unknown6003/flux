import Foundation
import Testing
@testable import FluxCore

private func shelfTemporary() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return url
}

@Test func shelfCopiesDuplicateNamesAndFoldersWithoutTouchingOriginals() async throws {
    let temporary = try shelfTemporary()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let source = temporary.appendingPathComponent("source\nfolder")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    try Data("owned original".utf8).write(to: source.appendingPathComponent("file.txt"))
    let root = temporary.appendingPathComponent("Shelf")
    let store = ShelfFiles(root: root)
    let first = try await store.addCopy(of: source)
    let second = try await store.addCopy(of: source)
    #expect(first.id != second.id)
    #expect(try await store.load().count == 2)
    let copied = try await store.payload(for: first.id)
    #expect(try Data(contentsOf: copied.appendingPathComponent("file.txt")) == Data("owned original".utf8))
    let reloaded = ShelfFiles(root: root)
    #expect(try await reloaded.load().count == 2)
    try await store.clear()
    #expect(try await store.load().isEmpty)
    #expect(try Data(contentsOf: source.appendingPathComponent("file.txt")) == Data("owned original".utf8))
}

@Test func malformedShelfManifestAndSymlinkFoldersArePreserved() async throws {
    let temporary = try shelfTemporary()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let root = temporary.appendingPathComponent("Shelf")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let manifest = root.appendingPathComponent("manifest.json")
    let corrupt = Data("not a manifest".utf8)
    try corrupt.write(to: manifest)
    let source = temporary.appendingPathComponent("source.txt")
    try Data("original".utf8).write(to: source)
    let store = ShelfFiles(root: root)
    await #expect(throws: (any Error).self) { try await store.addCopy(of: source) }
    #expect(try Data(contentsOf: manifest) == corrupt)
    let item = try ShelvedFile(fileName: source.lastPathComponent, addedAt: .now)
    try ShelfArchive.encode([item]).write(to: manifest)
    try FileManager.default.createSymbolicLink(at: item.directory(in: root), withDestinationURL: temporary)
    let unsafe = ShelfFiles(root: root)
    await #expect(throws: ShelfFileError.self) { try await unsafe.clear() }
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(try ShelfArchive.decode(Data(contentsOf: manifest)) == [item])
}

@Test func shelfExpiryDeletesOnlyManifestOwnedPayloads() async throws {
    let temporary = try shelfTemporary()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let root = temporary.appendingPathComponent("Shelf")
    let store = ShelfFiles(root: root)
    let source = temporary.appendingPathComponent("source.txt")
    try Data("keep original".utf8).write(to: source)
    let old = try await store.addCopy(of: source, at: Date(timeIntervalSince1970: 100))
    let recent = try await store.addCopy(of: source, at: Date(timeIntervalSince1970: 300))
    let orphan = root.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: false)
    try await store.expire(olderThan: Date(timeIntervalSince1970: 200))
    #expect(try await store.load().map(\.id) == [recent.id])
    #expect(!FileManager.default.fileExists(atPath: old.directory(in: root).path))
    #expect(FileManager.default.fileExists(atPath: orphan.path))
    #expect(FileManager.default.fileExists(atPath: source.path))
}

@Test func shelfRefusesAStaleManifestAfterAnotherWriterAddsAFile() async throws {
    let temporary = try shelfTemporary()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let root = temporary.appendingPathComponent("Shelf")
    let source = temporary.appendingPathComponent("source.txt")
    try Data("original".utf8).write(to: source)
    let first = ShelfFiles(root: root)
    _ = try await first.addCopy(of: source)
    let second = ShelfFiles(root: root)
    let added = try await second.addCopy(of: source)
    let manifest = root.appendingPathComponent("manifest.json")
    let before = try Data(contentsOf: manifest)
    await #expect(throws: ShelfFileError.self) { try await first.addCopy(of: source) }
    #expect(try Data(contentsOf: manifest) == before)
    #expect(try await first.reload().contains(where: { $0.id == added.id }))
}
