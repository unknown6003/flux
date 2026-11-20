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
        #expect(card.preferredSize == .init(width: 348, height: 194))
        #expect(card.showsMedia && card.showsActivity)

        card.update(.init(media: .init(status: .playing, title: "Example", elapsed: 65, duration: 240)))
        #expect(card.preferredSize == .init(width: 348, height: 148))
        #expect(card.showsMedia && !card.showsActivity)

        card.update(.init(activity: .init(text: "1:05")))
        #expect(card.preferredSize == .init(width: 240, height: 38))
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
}
