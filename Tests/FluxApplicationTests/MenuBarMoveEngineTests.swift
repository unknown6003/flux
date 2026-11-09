import CoreGraphics
import Testing
import FluxCore
@testable import FluxApplication

private func id(_ name: String) -> MenuBarItemID {
    MenuBarItemID(application: ApplicationID(rawValue: "org.fluxfixture.\(name)")!, index: 0)
}

/// A fake menu bar. A Cmd-drag drops the item where the pointer stops,
/// ordered by the other items' centres, like macOS. It can refuse drags
/// or land them one place off, as MenuBarAgent does with fast input.
@MainActor private final class SimulatedMenuBar {
    var order: [MenuBarItemID]
    var refusals = 0
    var overshoots = 0
    var accessible = true
    var quiet = true
    var drags: [(CGPoint, CGPoint)] = []
    let grouping: MenuBarGrouping

    init(_ names: [String], grouping: MenuBarGrouping = .none) {
        order = names.map(id)
        self.grouping = grouping
    }

    var layout: MenuBarLayout {
        MenuBarLayout(items: order.enumerated().map { index, item in
            MenuBarLayoutItem(id: item, frame: CGRect(x: 100 + CGFloat(index) * 30, y: 0, width: 24, height: 24))
        }, grouping: grouping)
    }

    func drag(_ from: CGPoint, _ to: CGPoint) {
        drags.append((from, to))
        if refusals > 0 { refusals -= 1; return }
        guard let moved = layout.items.first(where: { $0.frame.contains(from) })?.id else { return }
        var rest = layout.items.filter { $0.id != moved }
        var slot = rest.firstIndex(where: { $0.frame.midX > to.x }) ?? rest.count
        if overshoots > 0 { overshoots -= 1; slot = min(slot + 1, rest.count) }
        rest.insert(MenuBarLayoutItem(id: moved, frame: .zero), at: slot)
        order = rest.map(\.id)
    }

    var engine: MenuBarMoveEngine {
        MenuBarMoveEngine(read: { [unowned self] in self.accessible ? self.layout : nil },
                          drag: { [unowned self] in self.drag($0, $1) },
                          inputIsQuiet: { [unowned self] in self.quiet }, sleep: { _ in })
    }
}

@Suite struct MenuBarMoveEngineTests {
    @Test @MainActor func aReorderLandsBetweenTheNewNeighboursInOneTry() async throws {
        let bar = SimulatedMenuBar(["a", "b", "c", "d"])
        var attempts: [Int] = []
        try await bar.engine.run(.init(item: id("d"), group: .shown, left: id("a"), right: id("b"))) { attempts.append($0) }
        #expect(bar.order == ["a", "d", "b", "c"].map(id))
        #expect(attempts == [1])
        // Moving right works the same way.
        try await bar.engine.run(.init(item: id("a"), group: .shown, left: id("c"), right: nil)) { _ in }
        #expect(bar.order == ["d", "b", "c", "a"].map(id))
    }

    @Test @MainActor func aRefusedDragIsRetriedFromAFreshRead() async throws {
        let bar = SimulatedMenuBar(["a", "b", "c"])
        bar.refusals = 2
        var attempts: [Int] = []
        try await bar.engine.run(.init(item: id("c"), group: .shown, left: nil, right: id("a"))) { attempts.append($0) }
        #expect(bar.order == ["c", "a", "b"].map(id))
        #expect(attempts == [1, 2, 3])
        #expect(Set(bar.drags.map(\.1.x)).count == 3)
    }

    @Test @MainActor func anOvershootIsCorrectedByTheNextTry() async throws {
        let bar = SimulatedMenuBar(["a", "b", "c", "d"])
        bar.overshoots = 1
        try await bar.engine.run(.init(item: id("d"), group: .shown, left: id("a"), right: id("b"))) { _ in }
        #expect(bar.order == ["a", "d", "b", "c"].map(id))
        #expect(bar.drags.count == 2)
    }

    @Test @MainActor func threeRefusalsEndWithAClearFailure() async throws {
        let bar = SimulatedMenuBar(["a", "b", "c"])
        bar.refusals = 99
        await #expect(throws: MenuBarMoveFailure.notAccepted) {
            try await bar.engine.run(.init(item: id("c"), group: .shown, left: nil, right: id("a"))) { _ in }
        }
        #expect(bar.drags.count == MenuBarMoveEngine.attempts)
        #expect(bar.order == ["a", "b", "c"].map(id))
    }

    @Test @MainActor func busyInputLostAccessAndVanishedItemsNeverDrag() async throws {
        let busy = SimulatedMenuBar(["a", "b"])
        busy.quiet = false
        await #expect(throws: MenuBarMoveFailure.inputBusy) {
            try await busy.engine.run(.init(item: id("b"), group: .shown, left: nil, right: id("a"))) { _ in }
        }
        let locked = SimulatedMenuBar(["a", "b"])
        locked.accessible = false
        await #expect(throws: MenuBarMoveFailure.accessibilityRequired) {
            try await locked.engine.run(.init(item: id("b"), group: .shown, left: nil, right: id("a"))) { _ in }
        }
        let gone = SimulatedMenuBar(["a", "b"])
        await #expect(throws: MenuBarMoveFailure.neighbourGone) {
            try await gone.engine.run(.init(item: id("b"), group: .shown, left: nil, right: id("x"))) { _ in }
        }
        #expect(busy.drags.isEmpty && locked.drags.isEmpty && gone.drags.isEmpty)
    }

    @Test @MainActor func aPerAppGroupChangeIntoAnEmptyStripNeedsNoDrag() async throws {
        var policy = VisibilityPolicy()
        try policy.assign(ApplicationID(rawValue: "org.fluxfixture.b")!, to: .hidden)
        let bar = SimulatedMenuBar(["a", "b"], grouping: .perApplication(policy, alwaysHiddenEnabled: true))
        try await bar.engine.run(.init(item: id("b"), group: .hidden, left: nil, right: nil)) { _ in }
        #expect(bar.drags.isEmpty)
    }
}
