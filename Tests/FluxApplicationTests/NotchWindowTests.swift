import AppKit
import Testing
import FluxCore
import FluxUI
@testable import FluxApplication

@Suite(.serialized)
struct NotchWindowTests {
    @MainActor private func drainAppearanceChanges(until released: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !released(), Date() < deadline {
            autoreleasepool { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        }
    }

    @Test @MainActor func actualPanelStopsWidgetBeforeItReleasesTheController() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.screens.first)
        var calls: [String] = []
        weak var child: NSViewController?
        let owner = NotchWindowCoordinator(callbacks: .init(
            willShowWidget: { _, widget in calls.append("demand.\(widget.rawValue)") },
            makeWidget: { widget in
                calls.append("make.\(widget.rawValue)")
                let controller = NSViewController()
                controller.view = NSView()
                controller.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
                child = controller
                return controller
            }, willDismissWidget: { _ in
                #expect(child != nil)
                calls.append("stop")
            }, compactAction: { _ in Issue.record("No compact action was requested") }))
        defer { owner.stop() }
        owner.start(screen: screen, widgets: [.mirror, .shelf])
        #expect(owner.presentation == .compact)
        autoreleasepool { owner.expand(.mirror, focus: false) }
        #expect(calls == ["demand.mirror", "make.mirror"])
        #expect(owner.presentation == .expanded(.mirror))
        autoreleasepool { owner.collapse() }
        #expect(calls == ["demand.mirror", "make.mirror", "stop"])
        drainAppearanceChanges { child == nil }
        #expect(child == nil)
        #expect(owner.presentation == .compact)
        autoreleasepool { owner.expand(.shelf, focus: false) }
        autoreleasepool { owner.setSessionLocked(true) }
        #expect(calls.suffix(3) == ["demand.shelf", "make.shelf", "stop"])
        drainAppearanceChanges { child == nil }
        #expect(child == nil)
        #expect(owner.presentation == .hidden)
        owner.expand(.mirror, focus: true)
        #expect(owner.presentation == .hidden)
        owner.setSessionLocked(false)
        #expect(owner.presentation == .compact)
        #expect(child == nil)
    }
}
