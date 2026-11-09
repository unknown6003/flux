import Foundation
import Testing
@testable import FluxCore

private actor NoNetworkUsageTransport: UsageTransport {
    func send(_ request: UsageRequest) async throws -> UsageResponse {
        Issue.record("Collection must not send before start")
        return UsageResponse(status: 400)
    }
}

/// Accepts every request and hands each one to the test.
private actor RecordingUsageTransport: UsageTransport {
    let received: AsyncStream<UsageRequest>
    private let continuation: AsyncStream<UsageRequest>.Continuation

    init() {
        (received, continuation) = AsyncStream.makeStream()
    }

    func send(_ request: UsageRequest) async throws -> UsageResponse {
        continuation.yield(request)
        return UsageResponse(status: 200, body: Data(#"{"status":"Ok"}"#.utf8))
    }
}

@Test @MainActor func nothingIsBuiltOrWrittenBeforeStart() async throws {
    let suite = "flux-tests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var constructions = 0
    let collection = UsageCollection(defaults: defaults) { identity in
        constructions += 1
        return try PostHogClient(projectToken: "phc_fixture", identity: identity, transport: NoNetworkUsageTransport())
    }
    collection.record(.launched)
    collection.log(.serviceStarted)
    collection.flush()
    #expect(collection.makeRatingSubmission(.four) == nil)
    #expect(!collection.enabled)
    #expect(constructions == 0)
    #expect(defaults.object(forKey: UsageCollection.identityKey) == nil)
}

@Test @MainActor func startCollectsOnANewProfileAndKeepsOneIdentity() async throws {
    let suite = "flux-tests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var constructions = 0
    let collection = UsageCollection(defaults: defaults) { identity in
        constructions += 1
        return try PostHogClient(projectToken: "phc_fixture", identity: identity, transport: RecordingUsageTransport())
    }
    collection.start()
    collection.start()
    #expect(collection.enabled)
    #expect(constructions == 1)
    let id = try #require(defaults.string(forKey: UsageCollection.identityKey))
    #expect(UUID(uuidString: id) != nil)
    #expect(collection.makeRatingSubmission(.four) != nil)
}

@Test(.timeLimit(.minutes(1))) @MainActor func eventsSendEvenWhenTheOldOptInWasSavedAsFalse() async throws {
    let suite = "flux-tests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: "flux.analytics.enabled.v1")
    #expect(UsageCollection.legacyEnabledKey == "flux.analytics.enabled.v1")
    let transport = RecordingUsageTransport()
    let collection = UsageCollection(defaults: defaults) { identity in
        try PostHogClient(projectToken: "phc_fixture", identity: identity, transport: transport,
                          flushDelay: .milliseconds(1))
    }
    collection.start()
    #expect(collection.enabled)
    collection.record(.launched)
    collection.flush()
    var requests = transport.received.makeAsyncIterator()
    let request = try #require(await requests.next())
    #expect(request.endpoint == .events)
    let payload = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    let batch = try #require(payload["batch"] as? [[String: Any]])
    #expect(batch.first?["event"] as? String == "flux_launched")
    let properties = try #require(batch.first?["properties"] as? [String: Any])
    #expect(properties["$process_person_profile"] as? Bool == false)
    #expect(properties["$geoip_disable"] as? Bool == true)
    #expect(defaults.object(forKey: "flux.analytics.enabled.v1") as? Bool == false)
}
