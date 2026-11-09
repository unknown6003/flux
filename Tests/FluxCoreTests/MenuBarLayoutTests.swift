import CoreGraphics
import Testing
@testable import FluxCore

private func app(_ name: String) -> ApplicationID { ApplicationID(rawValue: "org.fluxfixture.\(name)")! }
private func item(_ name: String, _ x: CGFloat, index: Int = 0, width: CGFloat = 24) -> MenuBarLayoutItem {
    MenuBarLayoutItem(id: MenuBarItemID(application: app(name), index: index),
                      frame: CGRect(x: x, y: 0, width: width, height: 24))
}
private func id(_ name: String, _ index: Int = 0) -> MenuBarItemID { MenuBarItemID(application: app(name), index: index) }

/// a(100) b(200) c(300) | hidden boundary at 400 | d(500) e(600)
private func positional(_ items: [MenuBarLayoutItem], always: Bool = false) -> MenuBarLayout {
    MenuBarLayout(items: items, grouping: .byPosition(hidden: CGRect(x: 400, y: 0, width: 8, height: 24),
                                                      always: always ? CGRect(x: 150, y: 0, width: 8, height: 24) : nil))
}

private func perApp(_ items: [MenuBarLayoutItem], hidden: [String] = [], always: [String] = [],
                    alwaysEnabled: Bool = true) throws -> MenuBarLayout {
    var policy = VisibilityPolicy()
    for name in hidden { try policy.assign(app(name), to: .hidden) }
    for name in always { try policy.assign(app(name), to: .alwaysHidden) }
    return MenuBarLayout(items: items, grouping: .perApplication(policy, alwaysHiddenEnabled: alwaysEnabled))
}

@Suite struct MenuBarLayoutTests {
    @Test func stripsFollowPhysicalOrderAndBoundaries() {
        let layout = positional([item("e", 600), item("a", 100), item("d", 500), item("c", 300), item("b", 200)], always: true)
        #expect(layout.strip(.shown).map(\.id) == [id("d"), id("e")])
        #expect(layout.strip(.hidden).map(\.id) == [id("b"), id("c")])
        #expect(layout.strip(.alwaysHidden).map(\.id) == [id("a")])
    }

    @Test func perApplicationGroupsFollowThePolicyAndFoldAlwaysHiddenWhenOff() throws {
        let items = [item("a", 100), item("b", 200), item("c", 300)]
        let on = try perApp(items, hidden: ["b"], always: ["c"])
        #expect(on.strip(.hidden).map(\.id) == [id("b")])
        #expect(on.strip(.alwaysHidden).map(\.id) == [id("c")])
        let off = try perApp(items, hidden: ["b"], always: ["c"], alwaysEnabled: false)
        #expect(off.strip(.hidden).map(\.id) == [id("b"), id("c")])
        #expect(off.strip(.alwaysHidden).isEmpty)
    }

    @Test func reorderPlansLeftOfTheRightNeighbourAndAlreadyPlacedIsNoWork() throws {
        let layout = positional([item("a", 100), item("b", 200), item("c", 300), item("d", 500), item("e", 600)])
        let move = MenuBarItemMove(item: id("e"), group: .shown, left: nil, right: id("d"))
        let plan = try #require(try MenuBarMovePlanner.plan(move, in: layout))
        #expect(plan.target == .leftOf(id("d")))
        let points = try #require(MenuBarMovePlanner.dragPoints(for: plan, in: layout, attempt: 0))
        #expect(points.from == CGPoint(x: 612, y: 12))
        #expect(points.to == CGPoint(x: 508, y: 12))
        let done = MenuBarItemMove(item: id("d"), group: .shown, left: nil, right: id("e"))
        #expect(try MenuBarMovePlanner.plan(done, in: layout) == nil)
    }

    @Test func endOfStripPlansRightOfTheLeftNeighbour() throws {
        let layout = positional([item("a", 100), item("b", 200), item("c", 300), item("d", 500), item("e", 600)])
        let plan = try #require(try MenuBarMovePlanner.plan(.init(item: id("d"), group: .shown, left: id("e"), right: nil), in: layout))
        #expect(plan.target == .rightOf(id("e")))
        #expect(MenuBarMovePlanner.dragPoints(for: plan, in: layout, attempt: 0)?.to == CGPoint(x: 616, y: 12))
    }

    @Test func emptyStripUsesTheBoundaryByPositionAndNothingPerApp() throws {
        let layout = positional([item("a", 300), item("d", 500)])
        let plan = try #require(try MenuBarMovePlanner.plan(.init(item: id("d"), group: .hidden, left: nil, right: nil),
                                                            in: positional([item("d", 500)])))
        #expect(plan.target == .boundary(.hidden))
        #expect(MenuBarMovePlanner.dragPoints(for: plan, in: layout, attempt: 0)?.to.x == 400)
        let apps = try perApp([item("a", 300), item("d", 500)])
        let group = try #require(try MenuBarMovePlanner.plan(.init(item: id("d"), group: .hidden, left: nil, right: nil), in: apps))
        #expect(group.target == .none)
        #expect(MenuBarMovePlanner.dragPoints(for: group, in: apps, attempt: 0) == nil)
    }

    @Test func retriesUseDifferentDropPoints() throws {
        let layout = positional([item("d", 500, width: 40), item("e", 600)])
        let plan = try #require(try MenuBarMovePlanner.plan(.init(item: id("e"), group: .shown, left: nil, right: id("d")), in: layout))
        let xs = (0..<3).compactMap { MenuBarMovePlanner.dragPoints(for: plan, in: layout, attempt: $0)?.to.x }
        #expect(Set(xs).count == 3)
        #expect(xs.allSatisfy { $0 < 520 && $0 >= 500 })
    }

    @Test func plannerRefusesWhatItCannotDo() throws {
        let system = MenuBarLayoutItem(id: MenuBarItemID(application: ApplicationID(rawValue: "com.apple.controlcenter")!, index: 0),
                                       frame: CGRect(x: 700, y: 0, width: 24, height: 24))
        let layout = positional([item("a", 100), item("d", 500), system])
        #expect(throws: MenuBarMoveFailure.itemGone) { try MenuBarMovePlanner.plan(.init(item: id("x"), group: .shown, left: nil, right: nil), in: layout) }
        #expect(throws: MenuBarMoveFailure.itemLocked) { try MenuBarMovePlanner.plan(.init(item: system.id, group: .shown, left: nil, right: nil), in: layout) }
        #expect(throws: MenuBarMoveFailure.neighbourGone) { try MenuBarMovePlanner.plan(.init(item: id("a"), group: .shown, left: id("x"), right: nil), in: layout) }
        #expect(throws: MenuBarMoveFailure.alwaysHiddenOff) { try MenuBarMovePlanner.plan(.init(item: id("a"), group: .alwaysHidden, left: nil, right: nil), in: layout) }
        let none = MenuBarLayout(items: [item("a", 100)], grouping: .none)
        #expect(throws: MenuBarMoveFailure.hidingUnavailable) { try MenuBarMovePlanner.plan(.init(item: id("a"), group: .hidden, left: nil, right: nil), in: none) }
        let apps = try perApp([item("a", 100)], alwaysEnabled: false)
        #expect(throws: MenuBarMoveFailure.alwaysHiddenOff) { try MenuBarMovePlanner.plan(.init(item: id("a"), group: .alwaysHidden, left: nil, right: nil), in: apps) }
    }

    @Test func verificationChecksTheNewNeighboursNotJustTheGroup() throws {
        let move = MenuBarItemMove(item: id("a"), group: .hidden, left: id("b"), right: id("c"))
        // In the group, but on the wrong side of b.
        #expect(!MenuBarMovePlanner.isPlaced(move, in: positional([item("a", 100), item("b", 200), item("c", 300)])))
        // Between b and c, as asked.
        #expect(MenuBarMovePlanner.isPlaced(move, in: positional([item("b", 200), item("a", 250), item("c", 300)])))
        // Between them physically, but in the wrong group.
        #expect(!MenuBarMovePlanner.isPlaced(.init(item: id("a"), group: .shown, left: id("b"), right: id("c")),
                                            in: positional([item("b", 200), item("a", 250), item("c", 300)])))
    }

    @Test func perAppVerificationSkipsSiblingsAndOtherGroups() throws {
        // a1 and a2 share an app. x is visible and sits between hidden items.
        let items = [item("b", 100), item("a", 200, index: 1), item("x", 250), item("a", 300), item("c", 400)]
        let layout = try perApp(items, hidden: ["a", "b", "c"])
        #expect(MenuBarMovePlanner.isPlaced(.init(item: id("a"), group: .hidden, left: id("b"), right: id("c")), in: layout))
        // A named sibling neighbour still counts.
        #expect(MenuBarMovePlanner.isPlaced(.init(item: id("a"), group: .hidden, left: id("a", 1), right: id("c")), in: layout))
        #expect(!MenuBarMovePlanner.isPlaced(.init(item: id("a"), group: .hidden, left: nil, right: id("b")), in: layout))
    }

    @Test func itemTokensRoundTripAndRejectJunk() {
        let original = id("calendar", 3)
        #expect(MenuBarItemID(token: original.token) == original)
        #expect(MenuBarItemID(token: "org.fluxfixture.calendar") == nil)
        #expect(MenuBarItemID(token: "org.fluxfixture.calendar#-1") == nil)
        #expect(MenuBarItemID(token: "bad id#1") == nil)
    }
}
