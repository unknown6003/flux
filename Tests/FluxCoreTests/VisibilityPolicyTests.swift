import Foundation
import Testing
@testable import FluxCore

@Test func legacyChoicesSurviveWithoutTurningVisibilityIntoIconOrder() throws {
    let first = try #require(ApplicationID(rawValue: "com.example.first"))
    let second = try #require(ApplicationID(rawValue: "com.example.second"))
    let unknown = try #require(ApplicationID(rawValue: "com.example.new"))
    let fixture: [String: Any] = [
        "hidden": [first.rawValue, second.rawValue],
        "alwaysHidden": [second.rawValue],
        "future": ["keep": true]
    ]
    let policy = try VisibilityPolicy(legacyPropertyList: fixture)
    #expect(policy.group(for: first) == .hidden)
    #expect(policy.group(for: second) == .alwaysHidden)
    #expect(policy.group(for: unknown) == .shown)
    let running: Set<ApplicationID> = [first, second, unknown]
    #expect(policy.concealedApplications(running: running, reveal: .collapsed, alwaysHiddenEnabled: true) == [first, second])
    #expect(policy.concealedApplications(running: running, reveal: .hidden, alwaysHiddenEnabled: true) == [second])
    #expect(policy.concealedApplications(running: running, reveal: .hidden, alwaysHiddenEnabled: false).isEmpty)
    #expect(policy.concealedApplications(running: running, reveal: .all, alwaysHiddenEnabled: true).isEmpty)
    let saved = policy.legacyPropertyList(updating: fixture)
    #expect(saved["future"] as? [String: Bool] == ["keep": true])
    #expect(Set(saved.keys) == ["hidden", "alwaysHidden", "future"])
}

@Test func changingAGroupKeepsLegacySubsetMeaningAndProtectsSystemItems() throws {
    let application = try #require(ApplicationID(rawValue: "com.example.App"))
    var policy = VisibilityPolicy()
    try policy.assign(application, to: .alwaysHidden)
    let stored = policy.legacyPropertyList()
    #expect(stored["hidden"] as? [String] == [application.rawValue])
    #expect(stored["alwaysHidden"] as? [String] == [application.rawValue])
    try policy.assign(application, to: .hidden)
    #expect(policy.group(for: application) == .hidden)
    try policy.assign(application, to: .shown)
    #expect(policy.group(for: application) == .shown)
    for raw in ["com.apple.controlcenter", "com.flux.menubar"] {
        let protected = try #require(ApplicationID(rawValue: raw))
        #expect(throws: VisibilityPolicyError.self) { try policy.assign(protected, to: .hidden) }
    }
}

@Test func malformedStoredLayoutFailsWithoutRewritingIt() throws {
    let malformed: [String: Any] = ["hidden": ["not a bundle identifier"], "alwaysHidden": []]
    #expect(throws: VisibilityPolicyError.self) { try VisibilityPolicy(legacyPropertyList: malformed) }
    #expect(malformed["hidden"] as? [String] == ["not a bundle identifier"])
    for raw in ["", "com..example", "../file", "name@example.com", ".com.example", "com.example."] {
        #expect(ApplicationID(rawValue: raw) == nil)
    }
}
