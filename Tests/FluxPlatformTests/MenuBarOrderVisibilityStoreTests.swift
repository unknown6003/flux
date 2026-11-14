import Foundation
import Testing
import FluxCore
@testable import FluxPlatform

@Suite struct MenuBarOrderVisibilityStoreTests {
    @Test func leaseRestoresOnlyItsFlagsAndKeepsConcurrentChanges() async throws {
        let fixture = try VisibilityStoreFixture()
        defer { fixture.close() }
        try fixture.save(fixture.initial)
        let store = MenuBarOrderVisibilityStore(domain: fixture.domain, container: fixture.folder, journalDomain: fixture.journalDomain)
        let edit = try #require(try await store.begin([fixture.app]))
        var rows = try fixture.read()
        #expect(rows[1]["isAllowed"] as? Bool == true)
        #expect(rows[0]["future"] as? Data == Data([1, 9]))
        rows[1]["futureOwnerField"] = "kept"
        rows[2]["isAllowed"] = false
        try fixture.save(rows)
        try await store.finish(edit)
        rows = try fixture.read()
        #expect(rows[1]["isAllowed"] as? Bool == false)
        #expect(rows[1]["futureOwnerField"] as? String == "kept")
        #expect(rows[2]["isAllowed"] as? Bool == false)
        let second = try #require(try await store.begin([fixture.app]))
        rows = try fixture.read(); rows[1]["isAllowed"] = false
        try fixture.save(rows)
        try await store.finish(second)
        #expect(try fixture.read()[1]["isAllowed"] as? Bool == false)
    }

    @Test func aNewStoreRecoversAnInterruptedLease() async throws {
        let fixture = try VisibilityStoreFixture()
        defer { fixture.close() }
        try fixture.save(fixture.initial)
        let first = MenuBarOrderVisibilityStore(domain: fixture.domain, container: fixture.folder, journalDomain: fixture.journalDomain)
        _ = try await first.begin([fixture.app])
        #expect(try fixture.read()[1]["isAllowed"] as? Bool == true)
        let reopened = MenuBarOrderVisibilityStore(domain: fixture.domain, container: fixture.folder, journalDomain: fixture.journalDomain)
        try await reopened.recover()
        #expect(try fixture.read()[1]["isAllowed"] as? Bool == false)
        #expect(UserDefaults(suiteName: fixture.journalDomain)?.object(forKey: "flux.menuBar.orderVisibilityLease.v1") == nil)
    }
}

private struct VisibilityStoreFixture {
    let domain = "org.fluxfixture.visibility." + UUID().uuidString
    let journalDomain = "org.fluxfixture.visibility-journal." + UUID().uuidString
    let folder: URL
    let app = ApplicationID(rawValue: "org.fluxfixture.first")!
    let preferences: MenuBarContainerPreferences
    var initial: [[String: Any]] {
        [["future": Data([1, 9])],
         ["location": ["bundle": ["_0": app.rawValue]], "isAllowed": false],
         ["location": ["bundle": ["_0": "org.fluxfixture.second"]], "isAllowed": true]]
    }
    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("flux-visibility-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Library/Preferences"), withIntermediateDirectories: true)
        preferences = MenuBarContainerPreferences(domain: domain, key: "trackedApplications", container: folder)
    }
    func save(_ rows: [[String: Any]]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: rows, format: .binary, options: 0)
        #expect(preferences.write(data as CFData))
    }
    func read() throws -> [[String: Any]] {
        let data = try #require(preferences.read() as? Data)
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]])
    }
    func close() {
        _ = preferences.write(nil)
        UserDefaults(suiteName: journalDomain)?.removePersistentDomain(forName: journalDomain)
        try? FileManager.default.removeItem(at: folder)
    }
}
