import Foundation
import Testing
@testable import FluxCore

@Test @MainActor func configuredEUProjectBuildsNothingBeforeStart() {
    let suite = "flux-production-project-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    // No start(): a test must never reach the real project.
    let collection = UsageCollection(defaults: defaults)
    collection.record(.opened(.settings))
    collection.flush()
    #expect(!collection.enabled)
    #expect(defaults.object(forKey: UsageCollection.identityKey) == nil)
    #expect(FluxUsageProject.region.host.absoluteString == "https://eu.i.posthog.com")
}

@Test func syntheticVerificationDataHasAnExplicitFilterMarker() throws {
    let data = try UsageBatchEncoder.encode([UsageRecord(event: .opened(.settings), isVerification: true)],
                                            identity: UsageIdentity(), projectToken: FluxUsageProject.token)
    let envelope = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let batch = try #require(envelope["batch"] as? [[String: Any]])
    let properties = try #require(batch[0]["properties"] as? [String: Any])
    #expect(properties["flux_validation"] as? Bool == true)
    #expect(properties["$process_person_profile"] as? Bool == false)
    #expect(properties["$geoip_disable"] as? Bool == true)
    let logs = try PostHogWire.logs([UsageLogRecord(code: .serviceStarted, level: .info)],
                                   identity: UsageIdentity(), isVerification: true)
    let decoded = try #require(JSONSerialization.jsonObject(with: logs) as? [String: Any])
    let resources = try #require(decoded["resourceLogs"] as? [[String: Any]])
    let resource = try #require(resources[0]["resource"] as? [String: Any])
    let attributes = try #require(resource["attributes"] as? [[String: Any]])
    #expect(attributes.contains { $0["key"] as? String == "flux_validation" })
}
