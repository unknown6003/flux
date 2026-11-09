import Foundation
import Testing
@testable import FluxCore

private actor RecordingUsageTransport: UsageTransport {
    let received: AsyncStream<UsageRequest>
    private let continuation: AsyncStream<UsageRequest>.Continuation
    private var requests: [UsageRequest] = []
    private var response: UsageResponse

    init(response: UsageResponse = UsageResponse(status: 200)) {
        self.response = response
        (received, continuation) = AsyncStream<UsageRequest>.makeStream(bufferingPolicy: .bufferingNewest(16))
    }

    func send(_ request: UsageRequest) async throws -> UsageResponse {
        requests.append(request)
        continuation.yield(request)
        return response
    }

    func snapshot() -> [UsageRequest] { requests }
    func respondWith(_ value: UsageResponse) { response = value }
}

@Test(.timeLimit(.minutes(1))) func oneShotFlushResumesAfterAFlagReload() async throws {
    let flags = Data(#"{"flags":{"flux-welcome-layout":{"enabled":true,"variant":"compact","metadata":{"payload":"{\"hint_delay_ms\":1500}"}}}}"#.utf8)
    let transport = RecordingUsageTransport(response: UsageResponse(status: 200, body: flags))
    let client = try PostHogClient(projectToken: "phc_fixture", identity: UsageIdentity(), transport: transport, flushDelay: .milliseconds(10))
    await client.record(.launched)
    await client.reloadFlags()
    var iterator = await transport.received.makeAsyncIterator()
    let first = await iterator.next()
    let second = await iterator.next()
    #expect(first?.endpoint == .flags)
    #expect(second?.endpoint == .events)
    #expect(await client.payload(.welcomeLayout)?.hintDelayMilliseconds == 1500)
    await client.disable()
}

private actor BlockingUsageTransport: UsageTransport {
    let started: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var requests: [UsageRequest] = []
    private(set) var cancelled = false

    init() {
        (started, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func send(_ request: UsageRequest) async throws -> UsageResponse {
        requests.append(request)
        continuation.yield(())
        do { try await Task.sleep(for: .seconds(30)) }
        catch { cancelled = true; throw error }
        return UsageResponse(status: 200)
    }

    func snapshot() -> [UsageRequest] { requests }
}

@Test func emptyAndDisabledClientsMakeNoRequests() async throws {
    let transport = RecordingUsageTransport()
    let client = try PostHogClient(projectToken: "phc_fixture", identity: UsageIdentity(), transport: transport)
    await client.flush()
    #expect(await transport.snapshot().isEmpty)
    await client.record(.launched)
    await client.disable()
    await client.record(.opened(.settings))
    await client.log(.serviceStarted)
    await client.reloadFlags()
    await client.flush()
    #expect(await transport.snapshot().isEmpty)
}

@Test func eventQueueIsBoundedAndDoesNotSpoolToDisk() async throws {
    let transport = RecordingUsageTransport()
    let client = try PostHogClient(projectToken: "phc_fixture", identity: UsageIdentity(), transport: transport)
    for _ in 0..<1_000 { await client.record(.opened(.settings)) }
    for _ in 0..<5 { await client.flush() }
    let requests = await transport.snapshot()
    let batches = try requests.map { request -> [[String: Any]] in
        let object = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        return try #require(object["batch"] as? [[String: Any]])
    }
    #expect(batches.reduce(0) { $0 + $1.count } == PostHogClient.eventLimit)
    #expect(batches.allSatisfy { $0.count <= 20 })
    await client.disable()
}

@Test(.timeLimit(.minutes(1))) func optOutCancelsAnInflightSendAndDropsQueuedRecords() async throws {
    let transport = BlockingUsageTransport()
    let client = try PostHogClient(projectToken: "phc_fixture", identity: UsageIdentity(), transport: transport)
    await client.record(.launched)
    let flush = Task { await client.flush() }
    var iterator = await transport.started.makeAsyncIterator()
    _ = await iterator.next()
    await client.record(.opened(.shelf))
    await client.disable()
    await flush.value
    await client.flush()
    #expect(await transport.cancelled)
    #expect(await transport.snapshot().count == 1)
}

@Test func resetDiscardsOldPendingRecordsAndChangesTheNextID() async throws {
    let transport = RecordingUsageTransport()
    let original = UsageIdentity(), replacement = UsageIdentity()
    let client = try PostHogClient(projectToken: "phc_fixture", identity: original, transport: transport)
    await client.record(.opened(.clipboard))
    await client.resetIdentity(replacement)
    // A UI task created before Reset may reach the actor after Reset.
    await client.record(.opened(.calendar), expectedIdentity: original)
    await client.log(.serviceStarted, expectedIdentity: original)
    await client.record(.opened(.settings))
    await client.flush()
    let request = try #require(await transport.snapshot().first)
    let text = try #require(String(data: request.body, encoding: .utf8))
    #expect(!text.contains(original.value.uuidString.lowercased()))
    #expect(!text.contains("clipboard"))
    #expect(!text.contains("calendar"))
    #expect(text.contains(replacement.value.uuidString.lowercased()))
    await client.disable()
}

@Test func experimentExposureIsDeduplicatedAndConversionsCarryTheUsedVariant() async throws {
    let flags = Data(#"{"flags":{"flux-welcome-layout":{"enabled":true,"variant":"compact"}}}"#.utf8)
    let transport = RecordingUsageTransport(response: UsageResponse(status: 200, body: flags))
    let client = try PostHogClient(projectToken: "phc_fixture", identity: UsageIdentity(), transport: transport)
    #expect(await client.variant(.welcomeLayout) == .control)
    await client.reloadFlags()
    #expect(await client.variant(.welcomeLayout) == .compact)
    #expect(await client.variant(.welcomeLayout) == .compact)
    await client.record(.completed(.changeGroup, .succeeded))
    await client.flush()
    let requests = await transport.snapshot()
    #expect(requests.count == 2)
    #expect(requests[0].endpoint == .flags)
    let object = try #require(JSONSerialization.jsonObject(with: requests[1].body) as? [String: Any])
    let batch = try #require(object["batch"] as? [[String: Any]])
    #expect(batch.count == 2)
    #expect(batch[0]["event"] as? String == "$feature_flag_called")
    let properties = try #require(batch[1]["properties"] as? [String: Any])
    #expect(properties["$feature/flux-welcome-layout"] as? String == "compact")
    await client.disable()
}

@Test func aBackgroundReloadCannotReassignAnExperimentAlreadyUsedByTheInterface() async throws {
    let compact = Data(#"{"flags":{"flux-welcome-layout":{"enabled":true,"variant":"compact"}}}"#.utf8)
    let guided = Data(#"{"flags":{"flux-welcome-layout":{"enabled":true,"variant":"guided"}}}"#.utf8)
    let transport = RecordingUsageTransport(response: UsageResponse(status: 200, body: compact))
    let client = try PostHogClient(projectToken: "phc_fixture", identity: UsageIdentity(), transport: transport)
    await client.reloadFlags()
    #expect(await client.variant(.welcomeLayout) == .compact)
    await transport.respondWith(UsageResponse(status: 200, body: guided))
    await client.reloadFlags()
    #expect(await client.variant(.welcomeLayout) == .compact)
    await client.record(.completed(.changeGroup, .succeeded))
    await client.flush()
    let requests = await transport.snapshot()
    let object = try #require(JSONSerialization.jsonObject(with: requests.last!.body) as? [String: Any])
    let batch = try #require(object["batch"] as? [[String: Any]])
    #expect(batch.count == 2)
    let conversion = try #require(batch.last?["properties"] as? [String: Any])
    #expect(conversion["$feature/flux-welcome-layout"] as? String == "compact")
    await client.disable()
}

@Test func steadyEventsDoNotStarveStructuredLogs() async throws {
    let transport = RecordingUsageTransport()
    let client = try PostHogClient(projectToken: "phc_fixture", identity: UsageIdentity(), transport: transport)
    await client.log(.visibilityPaused, level: .warning)
    for _ in 0..<3 {
        for _ in 0..<20 { await client.record(.opened(.settings)) }
        await client.flush()
    }
    let requests = await transport.snapshot()
    #expect(requests.count == 3)
    #expect(requests[1].endpoint == .logs)
    await client.disable()
}

@Test func manualRatingUsesAnAcknowledgedSingleEventAndStableSubmissionID() async throws {
    let transport = RecordingUsageTransport(response: .init(status: 200, body: Data(#"{"status":1}"#.utf8)))
    let identity = UsageIdentity(), submission = UUID()
    let client = try PostHogClient(projectToken: "phc_fixture", identity: identity, transport: transport)
    #expect(await client.submitRating(.four, submission: submission, expectedIdentity: identity) == .accepted)
    let requests = await transport.snapshot()
    #expect(requests.count == 1)
    let request = try #require(requests.first)
    let body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    let batch = try #require(body["batch"] as? [[String: Any]])
    #expect(batch.count == 1)
    #expect(batch[0]["uuid"] as? String == submission.uuidString.lowercased())
    #expect(batch[0]["event"] as? String == "survey sent")
    let properties = try #require(batch[0]["properties"] as? [String: Any])
    #expect(properties["$survey_id"] as? String == FluxRatingSurvey.surveyID.uuidString.lowercased())
    #expect(properties["$survey_response_" + FluxRatingSurvey.questionID.uuidString.lowercased()] as? String == "4")
    #expect(properties["$process_person_profile"] as? Bool == false)
    #expect(properties["$geoip_disable"] as? Bool == true)
    await client.disable()
}

@Test func ratingDeliveryRequiresTheIngestionAckAndRejectsQuotaSuppression() {
    let cases: [(UsageResponse, UsageDeliveryResult)] = [
        (.init(status: 200, body: Data(#"{"status":1}"#.utf8)), .accepted),
        (.init(status: 200, body: Data(#"{"status":1,"quota_limited":[]}"#.utf8)), .accepted),
        (.init(status: 200, body: Data(#"{"status":1,"quota_limited":["events"]}"#.utf8)), .limited),
        (.init(status: 200, body: Data(#"{"status":1,"quota_limited":true}"#.utf8)), .failed),
        (.init(status: 200, body: Data(#"{"status":true}"#.utf8)), .failed),
        (.init(status: 200, body: Data(#"{"status":1.5}"#.utf8)), .failed),
        (.init(status: 200, body: Data(#"{"status":0}"#.utf8)), .failed),
        (.init(status: 200), .failed),
        (.init(status: 403, body: Data(#"{"status":1}"#.utf8)), .failed),
    ]
    for (response, expected) in cases { #expect(PostHogWire.ratingAcknowledgement(response) == expected) }
}

@Test(.timeLimit(.minutes(1))) func optingOutCancelsAnExplicitRatingAndCannotReturnAccepted() async throws {
    let transport = BlockingUsageTransport()
    let identity = UsageIdentity()
    let client = try PostHogClient(projectToken: "phc_fixture", identity: identity, transport: transport)
    let submission = Task { await client.submitRating(.three, submission: UUID(), expectedIdentity: identity) }
    var iterator = await transport.started.makeAsyncIterator()
    _ = await iterator.next()
    await client.disable()
    #expect(await submission.value == .cancelled)
    #expect(await transport.cancelled)
    #expect(await transport.snapshot().count == 1)
}

@Test(.timeLimit(.minutes(1))) func closingTheRatingRequestCancelsItsTransportWithoutOptingOut() async throws {
    let transport = BlockingUsageTransport()
    let identity = UsageIdentity()
    let client = try PostHogClient(projectToken: "phc_fixture", identity: identity, transport: transport)
    let submission = Task { await client.submitRating(.two, submission: UUID(), expectedIdentity: identity) }
    var iterator = await transport.started.makeAsyncIterator()
    _ = await iterator.next()
    submission.cancel()
    #expect(await submission.value == .cancelled)
    #expect(await transport.cancelled)
    #expect(await transport.snapshot().count == 1)
    await client.disable()
}

private actor RatingAcknowledgementGate: UsageTransport {
    let started: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var result: CheckedContinuation<UsageResponse, Never>?
    init() { (started, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1)) }
    func send(_ request: UsageRequest) async throws -> UsageResponse {
        continuation.yield(())
        return await withCheckedContinuation { result = $0 }
    }
    func release() {
        result?.resume(returning: .init(status: 200, body: Data(#"{"status":1}"#.utf8)))
        result = nil
    }
}

@Test(.timeLimit(.minutes(1))) func anOldRatingAckCannotCrossIdentityResetAndConcurrentSendsStayBounded() async throws {
    let transport = RatingAcknowledgementGate()
    let identity = UsageIdentity()
    let client = try PostHogClient(projectToken: "phc_fixture", identity: identity, transport: transport)
    let submission = Task { await client.submitRating(.three, submission: UUID(), expectedIdentity: identity) }
    var iterator = await transport.started.makeAsyncIterator()
    _ = await iterator.next()
    #expect(await client.submitRating(.five, submission: UUID(), expectedIdentity: identity) == .busy)
    await client.resetIdentity(UsageIdentity())
    await transport.release()
    #expect(await submission.value == .cancelled)
    #expect(await client.submitRating(.five, submission: UUID(), expectedIdentity: identity) == .cancelled)
    await client.disable()
}
