import AppKit
import FluxCore
import SwiftUI
import Testing
@testable import FluxUI

/// The 0.21.35 notch state machine, ported with the native widget list and
/// activity queue item. These are the old `--selftest` notch rules.
@Suite(.serialized)
struct NotchStateTests {
    @MainActor private func model(_ widgets: [FluxCore.Widget] = [.nowPlaying, .shelf, .calendar])
        -> (NotchViewModel, Log) {
        let model = NotchViewModel()
        let log = Log()
        model.setWidgets(widgets)
        model.onPresent = { from, to in log.calls.append("present.\(from?.rawValue ?? "nil").\(to.rawValue)") }
        model.onDismiss = { log.calls.append("dismiss.\($0.rawValue)") }
        model.onCycleActivity = { log.calls.append("cycle") }
        model.onDismissActivity = { log.calls.append("dismissActivity") }
        model.onRestoreActivity = { log.calls.append("restore") }
        return (model, log)
    }

    @MainActor private final class Log { var calls: [String] = [] }

    private func item(_ kind: ActivityKind = .timer, text: String = "1:05") throws -> ActivityItem {
        try ActivityItem(kind: kind, leading: .symbol("timer"), trailing: .text(text), priority: 110, duration: nil)
    }

    @Test @MainActor func presentAndDismissPairExactlyOnceAcrossEveryInput() {
        let (model, log) = model()
        model.clicked()
        #expect(model.state == .expanded(.nowPlaying))
        model.swiped(.left)
        #expect(model.state == .expanded(.shelf))
        model.swiped(.right)
        #expect(model.state == .expanded(.nowPlaying))
        model.swiped(.right)
        #expect(model.state == .expanded(.calendar))
        model.hotkeyToggled()
        #expect(model.state == .collapsed)
        // Reopens where the user left off.
        model.clicked()
        #expect(model.state == .expanded(.calendar))
        model.forceCollapse()
        #expect(log.calls == ["present.nil.nowPlaying", "present.nowPlaying.shelf", "present.shelf.nowPlaying",
                              "present.nowPlaying.calendar", "dismiss.calendar", "present.nil.calendar",
                              "dismiss.calendar"])
    }

    @Test @MainActor func liveActivityPreemptsCollapsedButNeverAnOpenWidget() throws {
        let (model, _) = model()
        let timer = try item()
        model.setActivity(timer, artwork: nil)
        #expect(model.state == .activity(timer.id))
        model.expand(.shelf)
        #expect(model.state == .expanded(.shelf))
        let battery = try item(.battery, text: "9%")
        model.setActivity(battery, artwork: nil)
        #expect(model.state == .expanded(.shelf))
        // Collapsing surfaces the activity that is current now.
        model.collapse()
        #expect(model.state == .activity(battery.id))
        model.setActivity(nil, artwork: nil)
        #expect(model.state == .collapsed)
        #expect(!NotchViewModel.isShrink(from: .collapsed, to: .activity(timer.id)))
        #expect(NotchViewModel.isShrink(from: .expanded(.shelf), to: .activity(timer.id)))
        #expect(!NotchViewModel.isShrink(from: .expanded(.shelf), to: .expanded(.calendar)))
    }

    @Test @MainActor func swipesAndOptionClickReachTheQueue() throws {
        let (model, log) = model()
        model.swiped(.left)
        #expect(model.state == .collapsed)
        model.setActivity(try item(), artwork: nil)
        model.swiped(.left)
        model.swiped(.right)
        model.swiped(.up)
        model.clicked(optionDown: true)
        #expect(log.calls == ["cycle", "cycle", "dismissActivity", "restore"])
        model.swiped(.down)
        #expect(model.state == .expanded(.nowPlaying))
        model.swiped(.down)
        #expect(model.state == .expanded(.nowPlaying))
        model.swiped(.up)
        #expect(model.state != .expanded(.nowPlaying))
    }

    @Test @MainActor func activityTapCanBeClaimedOnlyWhileAWingShows() throws {
        let (model, _) = model()
        var taps: [ActivityKind] = []
        model.onActivityTap = { kind in taps.append(kind); return kind == .menuBarOverflow }
        let overflow = try item(.menuBarOverflow, text: "3")
        model.setActivity(overflow, artwork: nil)
        model.handleTap(optionDown: false)
        #expect(model.state == .activity(overflow.id))
        model.setActivity(try item(.timer), artwork: nil)
        model.handleTap(optionDown: false)
        #expect(model.state == .expanded(.nowPlaying))
        #expect(taps == [.menuBarOverflow, .timer])
    }

    @Test @MainActor func removingTheOpenWidgetMovesOnOrCloses() {
        let (model, log) = model([.mirror, .shelf])
        model.expand(.mirror)
        model.setWidgets([.shelf, .shelf])
        #expect(model.widgets == [.shelf])
        #expect(model.state == .expanded(.shelf))
        model.setWidgets([])
        #expect(model.state == .collapsed)
        #expect(log.calls == ["present.nil.mirror", "present.mirror.shelf", "dismiss.shelf"])
    }

    @Test @MainActor func onlyADragThatOpenedTheShelfClosesIt() {
        let (model, _) = model()
        model.dragEntered()
        #expect(model.state == .expanded(.shelf))
        model.dragExited()
        #expect(model.state == .collapsed)
        model.dragEntered()
        model.dragCompleted()
        model.dragExited()
        #expect(model.state == .expanded(.shelf))
        model.collapse()
        model.expand(.calendar)
        model.dragEntered()
        model.dragExited()
        #expect(model.state == .expanded(.calendar))
        let (noShelf, _) = self.model([.calendar])
        noShelf.dragEntered()
        #expect(noShelf.state == .collapsed)
    }

    @Test @MainActor func hoverOpensAtOnceAndClosesAfterTheDelay() async throws {
        let (model, _) = model()
        model.hoverCloseDelay = 0.05
        model.hoverChanged(inside: true)
        #expect(model.state == .expanded(.nowPlaying))
        model.hoverChanged(inside: false)
        #expect(model.state == .expanded(.nowPlaying))
        // Re-entry inside the delay keeps it open.
        model.hoverChanged(inside: true)
        try await Task.sleep(for: .milliseconds(120))
        #expect(model.state == .expanded(.nowPlaying))
        model.hoverChanged(inside: false)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.state != .collapsed, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.state == .collapsed)
        // Click mode: hover never opens.
        model.expansionTrigger = .click
        model.hoverChanged(inside: true)
        #expect(model.state == .collapsed)
        #expect(model.hoverHint)
    }

    @Test @MainActor func widgetControllersShareOneModelWithTheNotch() {
        _ = NSApplication.shared
        var actions: [NowPlayingWidgetAction] = []
        let controller = NowPlayingWidgetController(state: .init(status: .playing, title: "Example", elapsed: 10,
                                                                 duration: 100), onAction: { actions.append($0) })
        _ = controller.notchContent()
        controller.update(.init(status: .paused, title: "Example", elapsed: 20, duration: 100))
        #expect(controller.model.state.status == .paused)
        #expect(controller.model.elapsed(at: .distantFuture) == 20)
        controller.model.onAction(.togglePlayPause)
        #expect(actions == [.togglePlayPause])
        #expect(controller.view.frame.size == NotchWidgetHost.standaloneSize)
        weak var released: NowPlayingWidgetController?
        autoreleasepool {
            let temporary = NowPlayingWidgetController(state: .empty, onAction: { _ in })
            released = temporary
            _ = temporary.notchContent()
        }
        #expect(released == nil)
    }
}
