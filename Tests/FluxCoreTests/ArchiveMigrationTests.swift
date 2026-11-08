import Foundation
import Testing
@testable import FluxCore

@Test func oldShelfManifestKeepsIDsNamesFoldersAndDateEpoch() throws {
    let data = Data(#"[{"id":"A1D4DA9F-3B22-4A69-98E8-93DD7D5E0BBD","fileName":"Screenshot.png","addedAt":1000},{"id":"37CA35DD-02BD-4744-9DEA-D40E68896066","fileName":"Screenshot.png","addedAt":2000},{"id":"411D4073-3168-46DF-AD1A-1625D8AF7D08","fileName":"Folder with spaces","addedAt":3000}]"#.utf8)
    let items = try ShelfArchive.decode(data)
    #expect(items.map(\.fileName) == ["Folder with spaces", "Screenshot.png", "Screenshot.png"])
    #expect(items[0].addedAt == Date(timeIntervalSinceReferenceDate: 3000))
    let root = URL(fileURLWithPath: "/Users/fixture/Library/Application Support/Flux/Shelf")
    #expect(items[2].url(in: root).path == root.path + "/A1D4DA9F-3B22-4A69-98E8-93DD7D5E0BBD/Screenshot.png")
    #expect(try ShelfArchive.decode(ShelfArchive.encode(items)) == items)
    let traversal = Data(#"[{"id":"A1D4DA9F-3B22-4A69-98E8-93DD7D5E0BBD","fileName":"../../outside","addedAt":1000}]"#.utf8)
    #expect(throws: ArchiveError.self) { try ShelfArchive.decode(traversal) }
    #expect(throws: ArchiveError.self) { try ShelfArchive.encode([items[0], items[0]]) }
}

@Test func oldClipboardHistoryRetainsTextAndExcludesExpiredAndNonTextPayloads() throws {
    let data = Data(##"{"version":1,"entries":[{"capturedAt":"2026-11-08T17:00:00Z","kind":"text","text":"A saved note"},{"capturedAt":"2026-11-08T17:01:00Z","kind":"url","text":"https://example.com/note"},{"capturedAt":"2026-11-08T17:02:00Z","kind":"color","text":"#FF8800"},{"capturedAt":"2026-01-01T00:00:00Z","kind":"text","text":"Expired"},{"capturedAt":"2026-11-08T17:03:00Z","kind":"image","text":"not allowed"}]}"##.utf8)
    let now = try #require(ISO8601DateFormatter().date(from: "2026-11-08T18:00:00Z"))
    let entries = try ClipboardArchive.decode(data, now: now)
    #expect(entries.map(\.kind) == [.color, .url, .text])
    #expect(entries.map(\.text) == ["#FF8800", "https://example.com/note", "A saved note"])
    #expect(try ClipboardArchive.decode(ClipboardArchive.encode(entries, now: now), now: now) == entries)
    #expect(throws: ArchiveError.self) {
        try ClipboardArchive.decode(Data(##"{"version":2,"entries":[]}"##.utf8), now: now)
    }
}

@Test func savedClipboardBudgetKeepsNewestEntriesAndNeverTruncatesURLs() throws {
    let now = Date(timeIntervalSince1970: 1_794_159_000)
    let long = String(repeating: "a", count: 33_000)
    let url = SavedClipboardEntry(capturedAt: now, kind: .url, text: "https://example.com/" + long)
    let text = SavedClipboardEntry(capturedAt: now, kind: .text, text: long)
    let fifty = (0..<50).map {
        SavedClipboardEntry(capturedAt: now.addingTimeInterval(Double(-$0 - 1)), kind: .text,
                            text: String(repeating: "界", count: 32_000))
    }
    let encoded = try ClipboardArchive.encode([url, text] + fifty, now: now)
    let decoded = try ClipboardArchive.decode(encoded, now: now)
    #expect(encoded.count <= 1_000_000)
    #expect(decoded.count <= 50)
    #expect(decoded.first?.text.count == 32_000)
    #expect(decoded.first?.text.hasSuffix("…") == true)
    #expect(!decoded.contains { $0.kind == .url })
    #expect(decoded.count < 50)
}
