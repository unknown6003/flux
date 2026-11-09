import Foundation
import Testing
@testable import FluxCore

private actor NoNetworkUsageTransport: UsageTransport {
    func send(_ request: UsageRequest) async throws -> UsageResponse {
        Issue.record("Disabled collection must never reach a transport")
        return UsageResponse(status: 400)
    }
}

@Test @MainActor func disabledStartupDoesNotConstructAnalyticsOrWriteAnID() async throws {
    let suite = "flux-tests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var constructions = 0
    let collection = UsageCollection(defaults: defaults) { identity in
        constructions += 1
        return try PostHogClient(projectToken: "phc_fixture", identity: identity, transport: NoNetworkUsageTransport())
    }
    collection.start()
    collection.record(.launched)
    collection.log(.serviceStarted)
    collection.flush()
    #expect(collection.makeRatingSubmission(.four) == nil)
    #expect(!collection.enabled)
    #expect(constructions == 0)
    #expect(defaults.object(forKey: UsageCollection.identityKey) == nil)

    await collection.setEnabled(true)
    #expect(collection.enabled)
    #expect(constructions == 1)
    let oldID = try #require(defaults.string(forKey: UsageCollection.identityKey))
    await collection.resetIdentity()
    #expect(defaults.string(forKey: UsageCollection.identityKey) != oldID)
    await collection.setEnabled(false)
    collection.record(.launched)
    collection.flush()
    #expect(!collection.enabled)
    #expect(constructions == 1)
}

@Test @MainActor func ratingRetryTokensCannotLinkAcrossAnIdentityReset() async throws {
    let suite = "flux-tests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let collection = UsageCollection(defaults: defaults) { identity in
        try PostHogClient(projectToken: "phc_fixture", identity: identity, transport: NoNetworkUsageTransport())
    }
    await collection.setEnabled(true)
    let old = try #require(collection.makeRatingSubmission(.four))
    await collection.resetIdentity()
    #expect(await collection.submitRating(old) == .cancelled)
    await collection.setEnabled(false)
    #expect(await collection.submitRating(old) == .disabled)
    #expect(collection.makeRatingSubmission(.four) == nil)
}
