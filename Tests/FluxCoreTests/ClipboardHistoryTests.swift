import Foundation
import Testing
@testable import FluxCore

@Test func clipboardKeepsExactTextAndSeparateNewlineFilePaths() throws {
    var history = ClipboardHistory()
    let text = "  indentation\ntrailing newline\n"
    history.capture(.text(text, .text), at: .now)
    #expect(history.records.first?.payload == .text(text, .text))
    let files = [URL(fileURLWithPath: "/tmp/one\nfile"), URL(fileURLWithPath: "/tmp/two")]
    history.capture(.files(files), at: .now)
    #expect(history.records.first?.payload == .files(files))
    #expect(history.savedEntries.count == 1)
    #expect(history.savedEntries.first?.text == text)
    history.capture(.text("javascript://host/path", .url), at: .now)
    #expect(history.records.first?.browserURL == nil)
    history.capture(.text(" https://example.com/path ", .url), at: .now)
    #expect(history.records.first?.browserURL?.scheme == "https")
}

@Test func clipboardBoundsImagesAndKeepsThumbnailsWhenOldPayloadsExpire() throws {
    var history = ClipboardHistory()
    let thumbnail = Data([1, 2, 3])
    for index in 0..<8 {
        let bytes = Data(repeating: UInt8(index), count: ClipboardHistory.maximumImageBytes)
        history.capture(.image(bytes: bytes, thumbnail: thumbnail, width: 2000, height: 1000), at: .now)
    }
    let fullImages = history.records.compactMap { record -> Data? in
        if case .image(let bytes, _, _, _) = record.payload { return bytes }
        return nil
    }
    #expect(fullImages.count == 6)
    #expect(fullImages.reduce(0) { $0 + $1.count } == ClipboardHistory.imageByteBudget)
    let oldest = try #require(history.records.last)
    #expect(!oldest.canCopy)
    if case .image(let bytes, let savedThumbnail, _, _) = oldest.payload {
        #expect(bytes == nil)
        #expect(savedThumbnail == thumbnail)
    } else { Issue.record("Expected an image record") }
    #expect(history.savedEntries.isEmpty)
}

@Test func clipboardCapsItemsDeduplicatesConsecutiveCopiesAndClassifiesOnlyMarkedHex() {
    var history = ClipboardHistory()
    for index in 0..<60 { history.capture(.text("\(index)", .text), at: .now) }
    #expect(history.records.count == 50)
    let latest = history.records.first?.id
    history.capture(.text("59", .text), at: .now)
    #expect(history.records.first?.id == latest)
    #expect(ClipboardHistory.classify("#AbC8") == .color)
    #expect(ClipboardHistory.classify("beefed") == .text)
    #expect(ClipboardHistory.classify("#12xy") == .text)
    #expect(ClipboardColor.parse("#0000")?.alpha == 0)
    history.clear()
    #expect(history.records.isEmpty)
}
