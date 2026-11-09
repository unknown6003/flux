import AppKit
import Testing
import FluxCore
import FluxUI
@testable import FluxApplication

@Suite(.serialized)
struct NotchWindowTests {
    @Test @MainActor func actualMediaAndDuoWidgetsKeepAVisibleViewport() async throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.screens.first)
        var primary: NSView?
        let owner = NotchWindowCoordinator(callbacks: .init(willShowWidget: { _, _ in },
            makeWidget: { widget in
                if widget == .calendar {
                    return CalendarWidgetController(state: .events(today: [
                        .init(id: "example", title: "Example meeting", location: "Example room",
                              start: Date(), end: Date().addingTimeInterval(1800), isAllDay: false)
                    ], tomorrow: []), onAction: { _ in })
                }
                let controller = NowPlayingWidgetController(state: .init(status: .playing,
                    title: "Example song", artist: "Example artist", elapsed: 65, duration: 240), onAction: { _ in })
                primary = controller.view
                return controller
            }, willDismissWidget: { _ in }, compactAction: { _ in }))
        defer { owner.stop() }
        owner.start(screen: screen, widgets: [.nowPlaying, .calendar])
        owner.expand(.nowPlaying, focus: false)
        // Inspect the real window through its bound child, not an isolated
        // widget whose fixture gives it an unrelated fixed height.
        let window = try #require(primary?.window)
        let panel = try #require(window.contentViewController as? NotchPanelController)
        try await Task.sleep(for: .milliseconds(50))
        panel.view.layoutSubtreeIfNeeded()
        #expect(panel.contentViewportHeight > 60)
        #expect(abs(panel.contentViewportHeight - panel.contentDocumentHeight) <= 1)
        #expect(panel.contentDocumentHeight >= (primary?.fittingSize.height ?? 0) - 1)
        owner.setDuo(true)
        try await Task.sleep(for: .milliseconds(50))
        panel.view.layoutSubtreeIfNeeded()
        #expect(panel.companion == .calendar)
        #expect(panel.contentViewportHeight > 60)
        #expect(abs(panel.contentViewportHeight - panel.contentDocumentHeight) <= 1)
        #expect(panel.contentDocumentHeight >= (primary?.fittingSize.height ?? 0) - 1)
        #expect(window.frame.height <= screen.frame.height * 0.8 + 1)
    }

    @MainActor private func drainAppearanceChanges(until released: @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !released(), clock.now < deadline {
            // AppKit appearance tasks must get the main actor back. A nested
            // synchronous run loop cannot run queued main-actor tasks.
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test @MainActor func lateContentRefitsTheRealWindowAndCannotReopenACollapsedPanel() async throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.screens.first)
        var content: NSView?
        var height: NSLayoutConstraint?
        let owner = NotchWindowCoordinator(callbacks: .init(willShowWidget: { _, _ in },
            makeWidget: { _ in
                let controller = NSViewController()
                controller.view = NSView()
                content = controller.view
                let constraint = controller.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)
                constraint.isActive = true
                height = constraint
                return controller
            }, willDismissWidget: { _ in }, compactAction: { _ in }))
        defer { owner.stop() }
        owner.start(screen: screen, widgets: [.calendar])
        owner.expand(.calendar, focus: false)
        let window = try #require(content?.window)
        let initialHeight = window.frame.height
        height?.constant = 600
        owner.contentDidChange(.calendar)
        owner.contentDidChange(.calendar)
        try await drainAppearanceChanges { window.frame.height > initialHeight }
        #expect(window.frame.height > initialHeight)
        #expect(window.frame.height <= screen.frame.height * 0.8 + 1)
        let panel = try #require(window.contentViewController as? NotchPanelController)
        #expect(panel.contentDocumentHeight >= 600)
        #expect(panel.contentDocumentHeight > panel.contentViewportHeight)
        let scroll = try #require(panel.view.subviews.compactMap { $0 as? NSScrollView }.first)
        let document = try #require(scroll.documentView)
        scroll.contentView.scroll(to: .init(x: 0, y: document.frame.height - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(scroll.documentVisibleRect.maxY >= document.bounds.maxY - 1)
        owner.contentDidChange(.calendar)
        owner.collapse()
        try await Task.sleep(for: .milliseconds(30))
        #expect(owner.presentation == .compact)
        #expect(content?.window == nil)
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
