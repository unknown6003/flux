import Foundation

/// Construct only when collection is enabled. All network work is explicit or
/// follows a queued record. An empty client has no task, timer or disk spool.
public actor PostHogClient {
    public static let eventLimit = 64
    public static let logLimit = 32
    private let projectToken: String
    private let transport: any UsageTransport
    private let flushDelay: Duration
    private let isVerification: Bool
    private var identity: UsageIdentity
    private var enabled = true
    private var generation = UUID()
    private var events: [UsageRecord] = []
    private var logs: [UsageLogRecord] = []
    private var assignments: [UsageFlag: UsageVariant] = [:]
    private var payloads: [UsageFlag: UsageFlagPayload] = [:]
    private var usedAssignments: [UsageFlag: UsageVariant] = [:]
    private var usedPayloads: [UsageFlag: UsageFlagPayload] = [:]
    private var exposures: Set<String> = []
    private var scheduled: Task<Void, Never>?
    private var request: Task<UsageResponse, any Error>?
    private var busy = false
    private var preferLogs = false
    private var rateWindow = ContinuousClock.now
    private var recordsInWindow = 0

    public init(
        projectToken: String, identity: UsageIdentity, transport: any UsageTransport,
        flushDelay: Duration = .seconds(30), isVerification: Bool = false
    ) throws {
        _ = try UsageBatchEncoder.encode([], identity: identity, projectToken: projectToken)
        self.projectToken = projectToken
        self.identity = identity
        self.transport = transport
        self.flushDelay = flushDelay
        self.isVerification = isVerification
    }

    deinit {
        scheduled?.cancel()
        request?.cancel()
    }

    public func record(_ event: UsageEvent, expectedIdentity: UsageIdentity? = nil) {
        if let expectedIdentity, expectedIdentity != identity { return }
        guard admitRecord() else { return }
        if events.count == Self.eventLimit { events.removeFirst() }
        events.append(UsageRecord(event: event, assignments: usedAssignments, isVerification: isVerification))
        schedule()
    }

    public func log(_ code: UsageLogCode, level: UsageLogLevel = .info, expectedIdentity: UsageIdentity? = nil) {
        if let expectedIdentity, expectedIdentity != identity { return }
        guard admitRecord() else { return }
        if logs.count == Self.logLimit { logs.removeFirst() }
        logs.append(UsageLogRecord(code: code, level: level))
        schedule()
    }

    /// An explicit rating waits for the ingestion acknowledgement, outside
    /// the UI actor. It never enters the best-effort queue or disk storage.
    public func submitRating(_ rating: UsageRating, submission: UUID,
                             expectedIdentity: UsageIdentity) async -> UsageDeliveryResult {
        guard enabled else { return .disabled }
        guard expectedIdentity == identity, !Task.isCancelled else { return .cancelled }
        guard !busy else { return .busy }
        guard admitRecord() else { return .limited }
        let record = UsageRecord(id: submission,
            event: .surveyAnswered(survey: FluxRatingSurvey.surveyID, question: FluxRatingSurvey.questionID,
                                   rating: rating, submission: submission),
            assignments: usedAssignments, isVerification: isVerification)
        guard let body = try? UsageBatchEncoder.encode([record], identity: identity, projectToken: projectToken)
        else { return .failed }
        scheduled?.cancel(); scheduled = nil
        let revision = generation
        busy = true
        let response = await perform(UsageRequest(endpoint: .events, body: body, projectToken: projectToken),
                                     observingCancellation: true)
        guard revision == generation, enabled, expectedIdentity == identity else { return .cancelled }
        request = nil
        busy = false
        schedule()
        guard !Task.isCancelled else { return .cancelled }
        guard let response else { return .failed }
        return PostHogWire.ratingAcknowledgement(response)
    }

    /// Cached presentation choice. A flag read never starts a request.
    public func variant(_ flag: UsageFlag) -> UsageVariant {
        guard enabled, let variant = usedAssignments[flag] ?? assignments[flag] else { return .control }
        if usedAssignments[flag] == nil {
            // Keep an experiment's displayed choice stable until ID reset or restart.
            usedAssignments[flag] = variant
            usedPayloads[flag] = payloads[flag]
        }
        let key = flag.rawValue + ":" + variant.rawValue
        if !exposures.contains(key), admitRecord() {
            exposures.insert(key)
            if events.count == Self.eventLimit { events.removeFirst() }
            events.append(UsageRecord(event: .exposure(flag, variant), assignments: usedAssignments, isVerification: isVerification))
            schedule()
        }
        return variant
    }

    public func payload(_ flag: UsageFlag) -> UsageFlagPayload? {
        guard enabled else { return nil }
        return usedAssignments[flag] == nil ? payloads[flag] : usedPayloads[flag]
    }

    /// Call from a noncritical action boundary. Never await from startup or native input.
    public func reloadFlags() async {
        guard enabled, !busy else { return }
        scheduled?.cancel()
        scheduled = nil
        let revision = generation
        guard let body = try? PostHogWire.flagsRequest(projectToken: projectToken, identity: identity) else { return }
        busy = true
        let result = await perform(UsageRequest(endpoint: .flags, body: body, projectToken: projectToken))
        guard generation == revision, enabled else { return }
        request = nil
        busy = false
        if let result, result.status == 200, let flags = try? PostHogWire.flagsResponse(result.body) {
            assignments = flags
            payloads = (try? PostHogWire.flagPayloads(result.body)) ?? [:]
        }
        schedule()
    }

    public func flush() async {
        guard enabled, !busy, !events.isEmpty || !logs.isEmpty else { return }
        scheduled?.cancel()
        scheduled = nil
        let revision = generation
        let payload: UsageRequest
        if !events.isEmpty && (logs.isEmpty || !preferLogs) {
            let batch = Array(events.prefix(20))
            events.removeFirst(batch.count)
            guard let data = try? UsageBatchEncoder.encode(batch, identity: identity, projectToken: projectToken) else { return }
            payload = UsageRequest(endpoint: .events, body: data, projectToken: projectToken)
            preferLogs = true
        } else {
            let batch = Array(logs.prefix(20))
            logs.removeFirst(batch.count)
            guard let data = try? PostHogWire.logs(batch, identity: identity, isVerification: isVerification) else { return }
            payload = UsageRequest(endpoint: .logs, body: data, projectToken: projectToken)
            preferLogs = false
        }
        busy = true
        _ = await perform(payload)
        guard generation == revision, enabled else { return }
        request = nil
        busy = false
        schedule()
    }

    /// Cancels outstanding work and drops all unsent records. A request that already
    /// reached the server cannot be recalled by changing a local setting.
    public func disable() {
        enabled = false
        invalidate()
    }

    public func resetIdentity(_ replacement: UsageIdentity) {
        invalidate()
        identity = replacement
    }

    private func invalidate() {
        generation = UUID()
        scheduled?.cancel()
        scheduled = nil
        request?.cancel()
        request = nil
        busy = false
        preferLogs = false
        events.removeAll(keepingCapacity: false)
        logs.removeAll(keepingCapacity: false)
        assignments.removeAll(keepingCapacity: false)
        payloads.removeAll(keepingCapacity: false)
        usedAssignments.removeAll(keepingCapacity: false)
        usedPayloads.removeAll(keepingCapacity: false)
        exposures.removeAll(keepingCapacity: false)
        rateWindow = .now
        recordsInWindow = 0
    }

    private func admitRecord() -> Bool {
        guard enabled else { return false }
        if rateWindow.duration(to: .now) >= .seconds(60) {
            rateWindow = .now
            recordsInWindow = 0
        }
        guard recordsInWindow < 120 else { return false }
        recordsInWindow += 1
        return true
    }

    private func schedule() {
        guard enabled, !busy, scheduled == nil, !events.isEmpty || !logs.isEmpty else { return }
        let delay = flushDelay
        scheduled = Task(priority: .utility) { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    private func perform(_ payload: UsageRequest, observingCancellation: Bool = false) async -> UsageResponse? {
        let transport = transport
        let task = Task(priority: .utility) {
            for attempt in 0..<3 {
                try Task.checkCancellation()
                do {
                    let response = try await transport.send(payload)
                    if response.status != 429 && response.status < 500 { return response }
                } catch is CancellationError { throw CancellationError() }
                catch { }
                if attempt < 2 { try await Task.sleep(for: .seconds(attempt == 0 ? 1 : 5)) }
            }
            throw PostHogWireError.invalidResponse
        }
        request = task
        if observingCancellation {
            return await withTaskCancellationHandler {
                try? await task.value
            } onCancel: { task.cancel() }
        }
        let result = try? await task.value
        // reset/disable can replace this task while the actor is suspended.
        return result
    }
}
