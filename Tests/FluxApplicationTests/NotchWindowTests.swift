import AppKit
import Testing
import FluxCore
import FluxUI
@testable import FluxApplication

/// A 180 x 32 pt notch at the top center of the first screen, so the window
/// tests run the same way on a Mac with or without a physical notch.
@MainActor func fixtureNotch() -> (screen: NSScreen, notch: CGRect)? {
    guard let screen = NSScreen.screens.first else { return nil }
    return (screen, CGRect(x: screen.frame.midX - 90, y: screen.frame.maxY - 32, width: 180, height: 32))
}

@MainActor func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
}

@Suite(.serialized)
struct NotchWindowTests {
    @Test @MainActor func widgetsAreMadeAndStoppedInTheOldTransitionOrder() async throws {
        _ = NSApplication.shared
        var calls: [String] = []
        weak var child: NSViewController?
        var presentations: [NotchWindowCoordinator.Presentation] = []
        let owner = NotchWindowCoordinator(callbacks: .init(
            willShowWidget: { from, widget in calls.append("demand.\(from?.rawValue ?? "nil").\(widget.rawValue)") },
            makeWidget: { widget in
                calls.append("make.\(widget.rawValue)")
                let controller = NSViewController()
                controller.view = NSView()
                child = controller
                return controller
            }, willDismissWidget: { widget in
                #expect(child != nil)
                calls.append("stop.\(widget?.rawValue ?? "nil")")
            }, compactAction: { _ in Issue.record("No queue action was requested") }),
            resolveNotch: fixtureNotch)
        defer { owner.stop() }
        owner.onPresentationChange = { presentations.append($0) }
        owner.start(widgets: [.mirror, .shelf])
        #expect(owner.presentation == .compact)
        autoreleasepool { owner.expand(.mirror) }
        #expect(calls == ["demand.nil.mirror", "make.mirror"])
        #expect(owner.presentation == .expanded(.mirror))
        // Disabling the open widget moves to the next one, as 0.21.35 did.
        autoreleasepool { owner.start(widgets: [.shelf]) }
        #expect(owner.presentation == .expanded(.shelf))
        #expect(calls.suffix(2) == ["demand.mirror.shelf", "make.shelf"])
        autoreleasepool { owner.collapse() }
        #expect(calls.last == "stop.shelf")
        try await waitUntil { child == nil }
        #expect(child == nil)
        #expect(owner.presentation == .compact)
        // The shortcut reopens the last widget.
        autoreleasepool { owner.toggle() }
        #expect(owner.presentation == .expanded(.shelf))
        autoreleasepool { owner.setSessionLocked(true) }
        #expect(calls.suffix(3) == ["demand.nil.shelf", "make.shelf", "stop.shelf"])
        try await waitUntil { child == nil }
        #expect(child == nil)
        #expect(owner.presentation == .hidden)
        owner.expand(.mirror)
        owner.toggle()
        #expect(owner.presentation == .hidden)
        owner.setSessionLocked(false)
        #expect(owner.presentation == .compact)
        #expect(presentations == [.compact, .expanded(.mirror), .expanded(.shelf), .compact,
                                  .expanded(.shelf), .hidden, .compact])
    }

    @Test @MainActor func duoCalendarPaneFollowsNowPlaying() throws {
        _ = NSApplication.shared
        var calls: [String] = []
        let owner = NotchWindowCoordinator(callbacks: .init(
            willShowWidget: { _, widget in calls.append("show.\(widget.rawValue)") },
            makeWidget: { widget in
                calls.append("make.\(widget.rawValue)")
                if widget == .calendar { return CalendarWidgetController(state: .loading, onAction: { _ in }) }
                return NowPlayingWidgetController(state: .empty, onAction: { _ in })
            }, willDismissWidget: { widget in calls.append("stop.\(widget?.rawValue ?? "nil")") },
            compactAction: { _ in },
            companionChanged: { calls.append("companion.\($0?.rawValue ?? "nil")") }),
            resolveNotch: fixtureNotch)
        defer { owner.stop() }
        owner.start(widgets: [.nowPlaying, .calendar, .shelf])
        owner.expand(.nowPlaying)
        owner.setDuo(true)
        #expect(owner.companion == .calendar)
        #expect(owner.viewModel.duoActive)
        owner.setDuo(true)
        owner.viewModel.swiped(.left)
        #expect(owner.presentation == .expanded(.calendar))
        #expect(owner.companion == nil)
        owner.viewModel.swiped(.right)
        #expect(owner.companion == .calendar)
        owner.collapse()
        #expect(owner.companion == nil)
        #expect(calls == ["show.nowPlaying", "make.nowPlaying", "companion.calendar", "make.calendar",
                          "companion.nil", "show.calendar", "make.calendar",
                          "show.nowPlaying", "make.nowPlaying", "companion.calendar", "make.calendar",
                          "stop.nowPlaying", "companion.nil"])
    }

    @Test @MainActor func fixedPanelSitsOnThePhysicalNotchAndPassesClicksThroughWhileClosed() throws {
        _ = NSApplication.shared
        let (screen, notch) = try #require(fixtureNotch())
        let previous = Set(NSApp.windows.map(ObjectIdentifier.init))
        let owner = NotchWindowCoordinator(callbacks: .init(willShowWidget: { _, _ in },
            makeWidget: { _ in NSViewController(nibName: nil, bundle: nil) }, willDismissWidget: { _ in },
            compactAction: { _ in }), resolveNotch: fixtureNotch)
        defer { owner.stop() }
        owner.setShowInFullscreen(false)
        owner.start(widgets: [.calendar])
        let windows = NSApp.windows.filter { !previous.contains(ObjectIdentifier($0)) }
        let panel = try #require(windows.compactMap { $0 as? NotchWindow }.first)
        let bounds = NotchMetrics.panelBounds(for: notch.width)
        #expect(panel.frame == CGRect(x: notch.midX - bounds.width / 2, y: screen.frame.maxY - bounds.height,
                                      width: bounds.width, height: bounds.height))
        #expect(panel.ignoresMouseEvents)
        #expect(!panel.canBecomeKey)
        #expect(panel.level == .statusBar)
        let trigger = try #require(windows.compactMap { $0 as? NotchHoverPanel }.first)
        #expect(trigger.frame == notch)
        #expect(trigger.isVisible)
        #expect(!panel.collectionBehavior.contains(.fullScreenAuxiliary))
        owner.setShowInFullscreen(true)
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(trigger.collectionBehavior.contains(.fullScreenAuxiliary))
        owner.expand(.calendar)
        #expect(!trigger.isVisible)
        owner.collapse()
        #expect(trigger.isVisible)
    }

    @Test @MainActor func withoutANotchedDisplayNothingShowsOrOpens() {
        _ = NSApplication.shared
        var made = 0
        let owner = NotchWindowCoordinator(callbacks: .init(willShowWidget: { _, _ in },
            makeWidget: { _ in made += 1; return NSViewController(nibName: nil, bundle: nil) },
            willDismissWidget: { _ in }, compactAction: { _ in }), resolveNotch: { nil })
        defer { owner.stop() }
        owner.start(widgets: [.calendar])
        owner.toggle()
        owner.expand(.calendar)
        #expect(owner.presentation == .hidden)
        #expect(made == 0)
    }

    @Test @MainActor func oldHoverClickAndDragRulesAreKept() {
        let notch = CGRect(x: 666, y: 950, width: 180, height: 32)
        #expect(NotchWindowCoordinator.collapsedHoverRect(notchRect: notch) == CGRect(x: 642, y: 930, width: 228, height: 52))
        #expect(NotchWindowCoordinator.collapsedClickRect(notchRect: notch) == CGRect(x: 650, y: 950, width: 212, height: 32))
        #expect(NotchWindowCoordinator.collapsedHoverPanelRect(notchRect: notch) == notch)
        #expect(NotchWindowCoordinator.collapsedHoverRect(notchRect: .zero).isNull)
        #expect(NotchWindowCoordinator.openHoverRect(interactiveRect: CGRect(x: 10, y: 0, width: 100, height: 50))
                == CGRect(x: 6, y: -4, width: 108, height: 58))
        #expect(NotchWindowCoordinator.shouldIgnoreMouseEvents(state: .collapsed, pointInsideVisibleShape: true))
        #expect(!NotchWindowCoordinator.shouldIgnoreMouseEvents(state: .expanded(.shelf), pointInsideVisibleShape: true))
        #expect(NotchWindowCoordinator.shouldIgnoreMouseEvents(state: .expanded(.shelf), pointInsideVisibleShape: false))
        #expect(NotchWindowCoordinator.shouldAcceptDrag(state: .collapsed, pointInNotch: true, shelfEnabled: true))
        #expect(!NotchWindowCoordinator.shouldAcceptDrag(state: .collapsed, pointInNotch: true, shelfEnabled: false))
        #expect(NotchWindowCoordinator.shouldAcceptDrag(state: .expanded(.shelf), pointInNotch: true, shelfEnabled: true))
        #expect(!NotchWindowCoordinator.shouldAcceptDrag(state: .expanded(.calendar), pointInNotch: true, shelfEnabled: true))
        #expect(!NotchWindowCoordinator.shouldAcceptDrag(state: .activity(UUID()), pointInNotch: true, shelfEnabled: true))
        #expect(NotchWindowCoordinator.shouldAcceptMonitoredInput(isPresenting: true, mainWindowVisible: true,
            triggerWindowVisible: false, showInFullscreen: true, mainWindowOnActiveSpace: false, triggerWindowOnActiveSpace: false))
        #expect(!NotchWindowCoordinator.shouldAcceptMonitoredInput(isPresenting: true, mainWindowVisible: true,
            triggerWindowVisible: false, showInFullscreen: false, mainWindowOnActiveSpace: false, triggerWindowOnActiveSpace: false))
        #expect(NotchWindowCoordinator.dragSlop == 20)
        #expect(NotchScreenGeometry.notchRect(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32,
            menuBarThickness: 37, leftArea: CGRect(x: 0, y: 950, width: 663, height: 32),
            rightArea: CGRect(x: 849, y: 950, width: 663, height: 32), backingScaleFactor: 2)
                == CGRect(x: 664, y: 950, width: 184, height: 32))
    }
}
