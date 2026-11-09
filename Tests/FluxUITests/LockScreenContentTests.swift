import AppKit
import Testing
@testable import FluxUI

@Suite(.serialized)
struct LockScreenContentTests {
    @Test @MainActor func emptyAndSilhouetteViewsHaveNoHitOrAccessibilityTarget() {
        _ = NSApplication.shared
        let silhouette = LockScreenSilhouetteView(notchSize: .init(width: 180, height: 33))
        #expect(silhouette.hitTest(.init(x: 30, y: 15)) == nil)
        #expect(!silhouette.isAccessibilityElement())
        let card = LockScreenContentController(state: .empty) { _ in Issue.record("Unexpected transport") }
        #expect(!card.showsMedia && !card.showsActivity)
        _ = card.view
        #expect(card.preferredSize == .zero)
        #expect(card.view.hitTest(.zero) == nil)
        #expect(card.view.accessibilityChildren()?.isEmpty == true)
        card.update(.init(media: .init(status: .playing, title: "Example", elapsed: 65, duration: 240),
                          activity: .init(symbolName: "timer", text: "1:05")))
        #expect(card.preferredSize == .init(width: 348, height: 210))
        #expect(card.showsMedia && card.showsActivity)
        card.update(.init(activity: .init(text: "1:05")))
        #expect(card.preferredSize == .init(width: 240, height: 38))
        #expect(!card.showsMedia && card.showsActivity)
        card.update(.empty)
        #expect(card.isEmpty && !card.showsActivity && !card.showsMedia)
        #expect(card.view.hitTest(.zero) == nil)
        #expect(card.view.accessibilityChildren()?.isEmpty == true)
    }
}
