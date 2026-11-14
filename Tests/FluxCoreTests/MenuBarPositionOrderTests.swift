import Foundation
import Testing
@testable import FluxCore

@Suite struct MenuBarPositionOrderTests {
    @Test func savedOrderRejectsMissingChangedAndNonfiniteBounds() {
        #expect(MenuBarPositionOrder.isPlaced(item: "B", left: "A", right: "C", positions: ["A": 30, "B": 20, "C": 10]))
        #expect(!MenuBarPositionOrder.isPlaced(item: "B", left: "A", right: "C", positions: ["A": 15, "B": 20, "C": 10]))
        #expect(!MenuBarPositionOrder.isPlaced(item: "B", left: "A", right: "C", positions: ["A": 30, "B": 20]))
        #expect(!MenuBarPositionOrder.isPlaced(item: "B", left: "A", right: nil, positions: ["A": .infinity, "B": 20]))
    }

    @Test func insertsBetweenNamedPeersWithoutRewritingOtherWeights() throws {
        let positions = ["source": 120.0, "left": 100.5, "right": 60.5, "unknown": 999.25]
        #expect(try MenuBarPositionOrder.weight(item: "source", left: "left", right: "right", positions: positions) == 80.5)
        #expect(positions["unknown"] == 999.25)
    }

    @Test func stripEndsRespectUnlistedNativeItems() throws {
        let positions = ["source": 250.0, "peer": 100.0, "unknownLeft": 102.0, "unknownRight": 98.0]
        #expect(try MenuBarPositionOrder.weight(item: "source", left: nil, right: "peer", positions: positions) == 101)
        #expect(try MenuBarPositionOrder.weight(item: "source", left: "peer", right: nil, positions: positions) == 99)
        #expect(throws: MenuBarMoveFailure.neighbourGone) {
            try MenuBarPositionOrder.weight(item: "source", left: "missing", right: nil, positions: positions)
        }
    }

    @Test func refusesInvalidBoundsRatherThanRenumberingTheBar() {
        #expect(throws: MenuBarMoveFailure.notAccepted) {
            try MenuBarPositionOrder.weight(item: "source", left: "left", right: "right",
                positions: ["source": 400, "left": 100, "right": 101])
        }
        #expect(throws: MenuBarMoveFailure.notAccepted) {
            try MenuBarPositionOrder.weight(item: "source", left: "left", right: "right",
                positions: ["source": 400, "left": 100.nextUp, "right": 100])
        }
    }

    @Test func resolvesExecutableNamespaceWithAStableIdentifier() throws {
        let app = ApplicationID(rawValue: "org.fluxfixture.positions")!
        let first = MenuBarItemID(application: app, index: 0)
        let second = MenuBarItemID(application: app, index: 1)
        let items = [MenuBarPositionIdentity(item: first, owners: ["probe"], identifier: "FluxOrderA", siblingCount: 2),
                     MenuBarPositionIdentity(item: second, owners: ["probe"], identifier: "FluxOrderB", siblingCount: 2)]
        let keys: Set<String> = ["status:probe::FluxOrderB", "status:probe::FluxOrderA", "status:unknown::Item-0"]
        #expect(try MenuBarPositionIdentity.key(for: first, in: items, keys: keys) == "status:probe::FluxOrderA")
        #expect(try MenuBarPositionIdentity.key(for: second, in: items, keys: keys) == "status:probe::FluxOrderB")
    }

    @Test func refusesSharedExecutableAndAmbiguousSiblingKeys() {
        let app = ApplicationID(rawValue: "org.fluxfixture.positions")!
        let other = ApplicationID(rawValue: "org.fluxfixture.other")!
        let item = MenuBarItemID(application: app, index: 0)
        let keys: Set<String> = ["status:probe::A", "status:probe::B"]
        #expect(throws: MenuBarMoveFailure.positionIdentityUnavailable) {
            try MenuBarPositionIdentity.key(for: item, in: [.init(item: item, owners: ["probe"], identifier: nil, siblingCount: 2)], keys: keys)
        }
        #expect(throws: MenuBarMoveFailure.positionIdentityUnavailable) {
            try MenuBarPositionIdentity.key(for: item, in: [
                .init(item: item, owners: ["probe"], identifier: "A", siblingCount: 1),
                .init(item: .init(application: other, index: 0), owners: ["probe"], identifier: "B", siblingCount: 1)], keys: keys)
        }
    }

    @Test func uniqueBundleKeyDoesNotDependOnTheExecutableAlias() throws {
        let app = ApplicationID(rawValue: "org.fluxfixture.positions")!
        let item = MenuBarItemID(application: app, index: 0)
        let key = "status:org.fluxfixture.positions::Item-0"
        #expect(try MenuBarPositionIdentity.key(for: item, in: [.init(item: item, owners: ["probe"], identifier: nil, siblingCount: 1)],
            keys: [key, "status:probe::unrelated"]) == key)
    }

    @Test func legacyAutosaveNameIdentifiesAnItemWithoutAnExistingNativeKey() throws {
        let app = ApplicationID(rawValue: "org.fluxfixture.legacy")!
        let item = MenuBarItemID(application: app, index: 0)
        let identity = MenuBarPositionIdentity(item: item, owners: [], identifier: nil, siblingCount: 1,
            legacyPositions: ["rocket_status_item": 485])
        #expect(try MenuBarPositionIdentity.key(for: item, in: [identity], keys: [])
            == "status:org.fluxfixture.legacy::rocket_status_item")
        let ambiguous = MenuBarPositionIdentity(item: item, owners: [], identifier: nil, siblingCount: 2,
            legacyPositions: ["first": 485, "second": 300])
        #expect(throws: MenuBarMoveFailure.positionIdentityUnavailable) {
            try MenuBarPositionIdentity.key(for: item, in: [ambiguous], keys: [])
        }
    }
}
