import AppKit
import Testing
import FluxCore
import FluxUI
@testable import FluxApplication

@Suite(.serialized)
struct NotchWindowTests {
    @MainActor private func drainAppearanceChanges(until released: @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !released(), clock.now < deadline {
            // AppKit appearance tasks must get the main actor back. A nested
            // synchronous run loop cannot run queued main-actor tasks.
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test @MainActor func actualPanelStopsWidgetBeforeItReleasesTheController() async throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.screens.first)
        var calls: [String] = []
        weak var child: NSViewController?
        var presentations: [NotchWindowCoordinator.Presentation] = []
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
        owner.onPresentationChange = { presentations.append($0) }
        owner.start(screen: screen, widgets: [.mirror, .shelf])
        #expect(owner.presentation == .compact)
        autoreleasepool { owner.expand(.mirror, focus: false) }
        #expect(calls == ["demand.mirror", "make.mirror"])
        #expect(owner.presentation == .expanded(.mirror))
        // Reapplying configuration on the same screen must stop a disabled
        // Mirror just as changing the widget list directly would.
        autoreleasepool { owner.start(screen: screen, widgets: [.shelf]) }
        #expect(owner.presentation == .expanded(.shelf))
        #expect(calls.suffix(2) == ["demand.shelf", "make.shelf"])
        autoreleasepool { owner.collapse() }
        #expect(calls.last == "stop")
        try await drainAppearanceChanges { child == nil }
        #expect(child == nil)
        #expect(owner.presentation == .compact)
        autoreleasepool { owner.expand(.shelf, focus: false) }
        autoreleasepool { owner.setSessionLocked(true) }
        #expect(calls.suffix(3) == ["demand.shelf", "make.shelf", "stop"])
        try await drainAppearanceChanges { child == nil }
        #expect(child == nil)
        #expect(owner.presentation == .hidden)
        owner.expand(.mirror, focus: true)
        #expect(owner.presentation == .hidden)
        owner.setSessionLocked(false)
        #expect(owner.presentation == .compact)
        #expect(child == nil)
        #expect(presentations == [.compact, .expanded(.mirror), .expanded(.shelf), .hidden, .compact,
                                   .expanded(.shelf), .hidden, .compact])
    }
}
