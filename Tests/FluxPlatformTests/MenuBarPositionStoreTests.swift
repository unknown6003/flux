import Foundation
import Testing
import FluxCore
@testable import FluxPlatform

@Suite struct MenuBarPositionStoreTests {
    @Test func groupMovesCrossTheChevronAndReapplyKeepsTheNativeOrder() async throws {
        let fixture = try ChevronPositionFixture()
        defer { fixture.close() }
        let source = fixture.sourceKey
        let store = fixture.store
        for group in MenuBarGroup.allCases {
            fixture.save([source: group == .shown ? 800.0 : 100.0, "chevron": 500.0,
                          "nativeOther": 300.0, "hiddenOther": 700.0, "opaque": Data([9])])
            let move = MenuBarItemMove(item: fixture.item, group: group, left: nil, right: nil, intent: .group)
            _ = try await store.place(move, identities: fixture.identities)
            let value = try #require(try fixture.read()[source] as? Double)
            #expect(group == .shown ? value < 500 : value > 500)
            #expect(try await store.isPlaced(move, identities: fixture.identities))
            #expect(try fixture.read()["chevron"] as? Double == 500)
            #expect(try fixture.read()["opaque"] as? Data == Data([9]))
            _ = try await store.place(move, identities: fixture.identities)
            #expect(try fixture.read()[source] as? Double == value)
            let stale = MenuBarItemID(application: ApplicationID(rawValue: "org.fluxfixture.gonePeer")!, index: 0)
            let reapply = MenuBarItemMove(item: fixture.item, group: group, left: stale, right: nil, intent: .group)
            _ = try await store.place(reapply, identities: fixture.identities)
            #expect(try fixture.read()[source] as? Double == value)
            var changed = try fixture.read()
            changed["chevron"] = group == .shown ? value - 1 : value + 1
            fixture.save(changed)
            #expect(try await !store.isPlaced(move, identities: fixture.identities))
        }
    }

    @Test func visibleSlotsCannotFollowPeersAcrossTheChevron() async throws {
        let fixture = try ChevronPositionFixture()
        defer { fixture.close() }
        let peer = MenuBarItemID(application: ApplicationID(rawValue: "org.fluxfixture.boundaryPeer")!, index: 0)
        let peerKey = "status:org.fluxfixture.boundaryPeer::Item-0"
        let identities = fixture.identities + [MenuBarPositionIdentity(item: peer, owners: [], identifier: nil, siblingCount: 1)]
        fixture.save([fixture.sourceKey: 800.0, peerKey: 700.0, "chevron": 500.0, "clock": 0.0])
        let move = MenuBarItemMove(item: fixture.item, group: .shown, left: peer, right: nil)
        _ = try await fixture.store.place(move, identities: identities)
        #expect(try fixture.read()[fixture.sourceKey] as? Double == 250)
        #expect(try fixture.read()[peerKey] as? Double == 700)
        #expect(try await fixture.store.isPlaced(move, identities: identities))
        fixture.save([fixture.sourceKey: 800.0, peerKey: 700.0])
        do {
            _ = try await fixture.store.place(move, identities: identities)
            Issue.record("A missing owned chevron must refuse placement")
        } catch { #expect(error as? MenuBarMoveFailure == .positionIdentityUnavailable) }
        #expect(try fixture.read()[fixture.sourceKey] as? Double == 800)
    }

    @Test func editsOneWeightAndRestoresOnlyWhileItStillOwnsThatValue() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("flux-order-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Library/Preferences"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let domain = "org.fluxfixture.order." + UUID().uuidString
        typealias Copy = @convention(c) (CFString, CFString, CFString, CFString, CFString) -> Unmanaged<CFTypeRef>?
        typealias SetValue = @convention(c) (CFString, CFTypeRef?, CFString, CFString, CFString, CFString) -> Void
        typealias Sync = @convention(c) (CFString, CFString, CFString, CFString) -> Bool
        let library = try #require(dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_NOW))
        let copy = unsafeBitCast(try #require(dlsym(library, "_CFPreferencesCopyValueWithContainer")), to: Copy.self)
        let set = unsafeBitCast(try #require(dlsym(library, "_CFPreferencesSetValueWithContainer")), to: SetValue.self)
        let sync = unsafeBitCast(try #require(dlsym(library, "_CFPreferencesSynchronizeWithContainer")), to: Sync.self)
        let key = "TrailingItemPreferredPositions" as CFString
        func save(_ value: [String: Any]?) {
            set(key, value as CFDictionary?, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost, folder.path as CFString)
            _ = sync(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost, folder.path as CFString)
        }
        func read() throws -> [String: Any] {
            try #require(copy(key, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost, folder.path as CFString)?.takeRetainedValue() as? [String: Any])
        }
        defer { save(nil) }
        let app = ApplicationID(rawValue: "org.fluxfixture.first")!
        let other = ApplicationID(rawValue: "org.fluxfixture.second")!
        let a = MenuBarItemID(application: app, index: 0)
        let b = MenuBarItemID(application: other, index: 0)
        let source = "status:org.fluxfixture.first::Item-0"
        let peer = "status:org.fluxfixture.second::Item-0"
        let opaque = Data([3, 7, 9])
        save([source: 40.5, peer: 100.5, "unknown": 200.5, "futureField": opaque])
        let store = MenuBarPositionStore(domain: domain, container: folder)
        let identities = [MenuBarPositionIdentity(item: a, owners: [], identifier: nil, siblingCount: 1),
                          MenuBarPositionIdentity(item: b, owners: [], identifier: nil, siblingCount: 1)]
        let move = MenuBarItemMove(item: a, group: .shown, left: nil, right: b)
        let edit = try await store.place(move, identities: identities)
        var changed = try read()
        #expect(changed[source] as? Double == 150.5)
        #expect(changed["futureField"] as? Data == opaque)
        changed["unknown"] = 300.5
        save(changed)
        try await store.restore(edit)
        changed = try read()
        #expect(changed[source] as? Double == 40.5)
        #expect(changed["unknown"] as? Double == 300.5)
        let second = try await store.place(move, identities: identities)
        changed = try read()
        changed[source] = 175.5
        save(changed)
        try await store.restore(second)
        changed = try read()
        #expect(changed[source] as? Double == 175.5)
        #expect(changed["futureField"] as? Data == opaque)
        let legacyKey = "status:org.fluxfixture.first::legacy_item"
        save([peer: 100.5, "futureField": opaque])
        let legacy = MenuBarPositionIdentity(item: a, owners: [], identifier: nil, siblingCount: 1,
            legacyPositions: ["legacy_item": 40.5])
        let created = try await store.place(move, identities: [legacy, identities[1]])
        #expect(created.before == nil)
        #expect(try read()[legacyKey] as? Double == 132.5)
        try await store.restore(created)
        #expect(try read()[legacyKey] == nil)
        #expect(try read()["futureField"] as? Data == opaque)
    }
}

private final class ChevronPositionFixture {
    let folder: URL
    let preferences: MenuBarContainerPreferences
    let store: MenuBarPositionStore
    let item = MenuBarItemID(application: ApplicationID(rawValue: "org.fluxfixture.boundarySource")!, index: 0)
    let sourceKey = "status:org.fluxfixture.boundarySource::Item-0"
    var identities: [MenuBarPositionIdentity] { [.init(item: item, owners: [], identifier: nil, siblingCount: 1)] }

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("flux-chevron-order-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Library/Preferences"), withIntermediateDirectories: true)
        let domain = "org.fluxfixture.chevron." + UUID().uuidString
        preferences = MenuBarContainerPreferences(domain: domain, key: "TrailingItemPreferredPositions", container: folder)
        store = MenuBarPositionStore(domain: domain, container: folder, chevronKey: "chevron")
    }
    func save(_ value: [String: Any]) { #expect(preferences.write(value as CFDictionary)) }
    func read() throws -> [String: Any] { try #require(preferences.read() as? [String: Any]) }
    func close() {
        _ = preferences.write(nil)
        try? FileManager.default.removeItem(at: folder)
    }
}
