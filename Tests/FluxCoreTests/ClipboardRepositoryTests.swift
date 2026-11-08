import Foundation
import Testing
@testable import FluxCore

@Test func disabledClipboardPersistenceDoesNotCreateFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = ClipboardRepository(historyURL: root.appendingPathComponent("clipboard-history.json"))
    try await repository.prepare(persistenceEnabled: false)
    try await repository.capture(.text("local only", .text))
    #expect(await repository.snapshot().count == 1)
    #expect(!FileManager.default.fileExists(atPath: root.path))
}

@Test func clipboardRepositorySavesOnlyTextAndDeletesDiskDataOnExplicitOptOut() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("clipboard-history.json")
    let repository = ClipboardRepository(historyURL: file)
    try await repository.prepare(persistenceEnabled: true)
    try await repository.capture(.text("saved text", .text))
    try await repository.capture(.files([URL(fileURLWithPath: "/tmp/private file")]))
    #expect(try ClipboardArchive.decode(Data(contentsOf: file), now: .now).map(\.text) == ["saved text"])
    let reloaded = ClipboardRepository(historyURL: file)
    try await reloaded.prepare(persistenceEnabled: true)
    #expect(await reloaded.snapshot().count == 1)
    try await repository.setPersistenceEnabled(false)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(await repository.snapshot().count == 2)
    try await repository.capture(.text("not saved", .text))
    #expect(!FileManager.default.fileExists(atPath: file.path))
}
