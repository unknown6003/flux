import Testing
@testable import FluxPlatform

struct StatusPreviewContentTests {
    private func image(width: Int, height: Int, background: [UInt8], glyph: [UInt8]? = nil,
                       glyphPixels: Int = 0) -> [UInt8] {
        var pixels: [UInt8] = []
        for index in 0..<(width * height) {
            pixels += index < glyphPixels ? (glyph ?? background) : background
        }
        return pixels
    }

    @Test func flatPatchesAreBlank() {
        #expect(StatusPreviewContent.isBlank(rgba: image(width: 40, height: 24, background: [0, 0, 0, 255])))
        #expect(StatusPreviewContent.isBlank(rgba: image(width: 40, height: 24, background: [30, 30, 32, 255])))
        #expect(StatusPreviewContent.isBlank(rgba: image(width: 40, height: 24, background: [0, 0, 0, 0])))
        #expect(StatusPreviewContent.isBlank(rgba: []))
        // A few stray edge pixels are still blank.
        #expect(StatusPreviewContent.isBlank(rgba: image(width: 40, height: 24, background: [0, 0, 0, 255],
                                                         glyph: [255, 255, 255, 255], glyphPixels: 10)))
    }

    @Test func aGlyphOnTheMenuBarIsNotBlank() {
        // A white glyph covering about 15% of a dark item.
        #expect(!StatusPreviewContent.isBlank(rgba: image(width: 40, height: 24, background: [20, 20, 22, 255],
                                                          glyph: [240, 240, 240, 255], glyphPixels: 144)))
        // A dark glyph on a light menu bar.
        #expect(!StatusPreviewContent.isBlank(rgba: image(width: 40, height: 24, background: [236, 236, 236, 255],
                                                          glyph: [30, 30, 30, 255], glyphPixels: 60)))
    }
}
