import AppKit
import Testing
@testable import FluxUI

@Suite(.serialized)
struct LockScreenContentTests {
    @Test @MainActor func emptyAndSilhouetteAndBackdropViewsHaveNoHitOrAccessibilityTarget() {
        _ = NSApplication.shared
        let silhouette = LockScreenSilhouetteView(notchSize: .init(width: 180, height: 33))
        #expect(silhouette.hitTest(.init(x: 30, y: 15)) == nil)
        #expect(!silhouette.isAccessibilityElement())

        let backdrop = LockScreenBackdropController(state: .empty)
        _ = backdrop.view
        #expect(backdrop.view.hitTest(.init(x: 100, y: 100)) == nil)
        #expect(!backdrop.view.isAccessibilityElement())
        #expect(backdrop.view.accessibilityChildren()?.isEmpty == true)

        let card = LockScreenContentController(state: .empty) { _ in Issue.record("Unexpected transport") }
        #expect(!card.showsMedia && !card.showsActivity)
        _ = card.view
        #expect(card.preferredSize == .zero)
        #expect(card.view.hitTest(.zero) == nil)
        #expect(card.view.accessibilityChildren()?.isEmpty == true)

        card.update(.init(media: .init(status: .playing, title: "Example", elapsed: 65, duration: 240),
                          activity: .init(symbolName: "timer", text: "1:05")))
        #expect(card.preferredSize == .init(width: 408, height: 236))
        #expect(card.showsMedia && card.showsActivity)

        card.update(.init(media: .init(status: .playing, title: "Example", elapsed: 65, duration: 240)))
        #expect(card.preferredSize == .init(width: 408, height: 182))
        #expect(card.showsMedia && !card.showsActivity)

        card.update(.init(activity: .init(text: "1:05")))
        #expect(card.preferredSize == .init(width: 256, height: 42))
        #expect(!card.showsMedia && card.showsActivity)

        card.update(.empty)
        #expect(card.isEmpty && !card.showsActivity && !card.showsMedia)
        #expect(card.view.hitTest(.zero) == nil)
        #expect(card.view.accessibilityChildren()?.isEmpty == true)
    }

    @Test func clockGlyphShapeGeneratesCenteredVectorPath() {
        let shape = ClockGlyphShape(text: "10:08", fontSize: 180)
        let path = shape.path(in: CGRect(x: 0, y: 0, width: 520, height: 160))
        #expect(!path.isEmpty)
        let bounds = path.boundingRect
        #expect(bounds.width > 180)
        #expect(bounds.height > 80)
        #expect(abs(bounds.midX - 260) < 2.0)
        #expect(abs(bounds.midY - 80) < 2.0)
    }

    @Test func metalLiquidGlassRendererProducesRefractedCardAndClockImages() throws {
        guard LiquidGlassRenderer.shared.isAvailable else { return }
        let w = 640
        let h = 420
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let split = x > w / 2
                pixels[i] = split ? 240 : 28
                pixels[i + 1] = split ? 185 : 52
                pixels[i + 2] = split ? 115 : 88
                pixels[i + 3] = 255
            }
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = try #require(CGContext(
            data: &pixels, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let backdrop = try #require(ctx.makeImage())

        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let cardFrame = CGRect(x: 552, y: 126, width: 408, height: 182)
        let cardImg = try #require(LiquidGlassRenderer.shared.renderCardGlass(
            backdrop: backdrop,
            screenFrame: screen,
            cardFrame: cardFrame,
            cornerRadius: 32,
            scale: 2.0
        ))
        #expect(cardImg.width == 816)
        #expect(cardImg.height == 364)

        let clockRect = CGRect(x: 444, y: 128, width: 624, height: 161)
        let clockImg = try #require(LiquidGlassRenderer.shared.renderClockGlass(
            sourceKey: "test.gradient",
            backdrop: backdrop,
            canvasSizePt: screen.size,
            clockRectTopLeftPt: clockRect,
            timeText: "10:08",
            fontSize: 201,
            scale: 2.0
        ))
        #expect(clockImg.width == 1248)
        #expect(clockImg.height == 322)
    }
}
