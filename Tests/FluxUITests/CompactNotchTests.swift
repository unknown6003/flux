import AppKit
import Testing
import FluxCore
@testable import FluxUI

struct CompactNotchTests {
    @Test @MainActor func compactCameraGapAndActionsUseRealQueueState() throws {
        _ = NSApplication.shared
        let geometry = NotchGeometry(screenFrame: .init(x: 0, y: 0, width: 1728, height: 1117),
                                     cameraWidth: 180, topInset: 33)
        let item = try ActivityItem(kind: .timer, leading: .symbol("timer"), trailing: .text("1:05"),
                                    priority: 1, duration: nil)
        var actions: [CompactNotchAction] = []
        let controller = CompactNotchController(state: .init(geometry: geometry), onAction: { actions.append($0) })
        #expect(controller.preferredSize == NSSize(width: 180, height: 33))
        let root = controller.view
        let button = try #require(root.subviews.compactMap { $0 as? CompactNotchButton }.first)
        button.onKey?(.dismissActivity)
        button.onKey?(.restoreActivity)
        button.onKey?(.cycle)
        #expect(actions.isEmpty)
        controller.update(.init(geometry: geometry, currentActivity: item, queueCount: 2, restorableCount: 1))
        #expect(controller.preferredSize == NSSize(width: 260, height: 33))
        #expect(actions.isEmpty)
        button.onKey?(.dismissActivity)
        button.onKey?(.restoreActivity)
        button.onKey?(.cycle)
        #expect(actions == [.dismissActivity, .restoreActivity, .cycle])
        controller.update(.init(geometry: geometry))
        button.onKey?(.expand)
        #expect(actions.last == .expand)
    }

    @Test @MainActor func phasedScrollFiresOnceAndNewGestureResets() {
        var scroll = ScrollAccumulator()
        #expect(scroll.feed(dx: -20, dy: 0, phased: true) == nil)
        #expect(scroll.feed(dx: -11, dy: 0, phased: true) == .dismissActivity)
        #expect(scroll.feed(dx: 100, dy: 100, phased: true) == nil)
        scroll.reset()
        #expect(scroll.feed(dx: 31, dy: 0, phased: true) == .restoreActivity)
        scroll.reset()
        #expect(scroll.feed(dx: 0, dy: 31, phased: false) == .cycle)
        #expect(scroll.feed(dx: 0, dy: 31, phased: false) == .cycle)
    }
}
