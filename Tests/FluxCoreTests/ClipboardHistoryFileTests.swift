import Foundation
import Testing
@testable import FluxCore

@Test(.timeLimit(.minutes(1))) func clipboardDiskServiceIsLazyAndHonorsThePersistenceSwitch() async throws {
    let manager = FileManager.default
    let directory = manager.temporaryDirectory.appendingPathComponent("flux-history-" + UUID().uuidString)
    defer { try? manager.removeItem(at: directory) }
    let url = directory.appendingPathComponent("clipboard-history.json")
    let service = ClipboardHistoryFile(url: url)
    let now = Date(timeIntervalSince1970: 1_794_159_000)
    let entry = SavedClipboardEntry(capturedAt: now, kind: .text, text: "Fixture text")
    #expect(try await service.load(now: now).isEmpty)
    try await service.save([entry], now: now)
    #expect(!manager.fileExists(atPath: directory.path))
    try await service.setPersistenceEnabled(true)
    try await service.save([entry], now: now)
    #expect(try await service.load(now: now) == [entry])
    let fileAttributes = try manager.attributesOfItem(atPath: url.path)
    let directoryAttributes = try manager.attributesOfItem(atPath: directory.path)
    #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    try await service.setPersistenceEnabled(false)
    #expect(!manager.fileExists(atPath: url.path))
    try await service.save([entry], now: now)
    #expect(!manager.fileExists(atPath: url.path))
}

@Test(.timeLimit(.minutes(1))) func unreadableClipboardArchivesRemainAvailableForRecovery() async throws {
    let manager = FileManager.default
    let directory = manager.temporaryDirectory.appendingPathComponent("flux-history-" + UUID().uuidString)
    try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: directory) }
    let url = directory.appendingPathComponent("clipboard-history.json")
    let future = Data(#"{"version":2,"entries":[]}"#.utf8)
    try future.write(to: url)
    let service = ClipboardHistoryFile(url: url)
    try await service.setPersistenceEnabled(true)
    await #expect(throws: ArchiveError.self) { try await service.load(now: Date()) }
    await #expect(throws: ArchiveError.self) { try await service.save([], now: Date()) }
    #expect(try Data(contentsOf: url) == future)
    let damaged = Data("incomplete JSON".utf8)
    try damaged.write(to: url)
    await #expect(throws: (any Error).self) { try await service.save([], now: Date()) }
    #expect(try Data(contentsOf: url) == damaged)
    try manager.removeItem(at: url)
    let unrelated = directory.appendingPathComponent("unrelated.txt")
    try Data("keep".utf8).write(to: unrelated)
    try manager.createSymbolicLink(at: url, withDestinationURL: unrelated)
    await #expect(throws: HistoryFileError.self) { try await service.clear() }
    #expect(try Data(contentsOf: unrelated) == Data("keep".utf8))
}
