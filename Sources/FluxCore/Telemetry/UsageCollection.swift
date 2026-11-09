import Foundation

/// The app owns this small controller. Anonymous usage collection is always
/// on: `start()` builds the client for every profile. Nothing is built or
/// sent before `start()`.
@MainActor
public final class UsageCollection {
    /// The old opt-in switch. Collection ignores it, so a saved `false` from
    /// an earlier version does not stop events.
    public static let legacyEnabledKey = "flux.analytics.enabled.v1"
    public static let identityKey = "flux.analytics.randomID.v1"
    private let defaults: UserDefaults
    private let factory: @MainActor (UsageIdentity) throws -> PostHogClient
    private var client: PostHogClient?
    private var activeIdentity: UsageIdentity?
    private var rateWindow = ContinuousClock.now
    private var recordsInWindow = 0
    public private(set) var enabled = false

    public init(
        defaults: UserDefaults,
        factory: @escaping @MainActor (UsageIdentity) throws -> PostHogClient
    ) {
        self.defaults = defaults
        self.factory = factory
    }

    /// Starts collection. A saved `legacyEnabledKey` value is ignored.
    public func start() {
        guard !enabled else { return }
        enable()
    }

    /// Fire after an action settles. The caller never awaits networking or encoding.
    public func record(_ event: UsageEvent) {
        guard let client, let identity = admitRecord() else { return }
        Task(priority: .utility) { await client.record(event, expectedIdentity: identity) }
    }

    public func log(_ code: UsageLogCode, level: UsageLogLevel = .info) {
        guard let client, let identity = admitRecord() else { return }
        Task(priority: .utility) { await client.log(code, level: level, expectedIdentity: identity) }
    }

    public func makeRatingSubmission(_ rating: UsageRating) -> UsageRatingSubmission? {
        guard enabled, let activeIdentity else { return nil }
        return UsageRatingSubmission(rating: rating, identity: activeIdentity)
    }

    public func submitRating(_ submission: UsageRatingSubmission) async -> UsageDeliveryResult {
        guard enabled, let client else { return .disabled }
        guard submission.identity == activeIdentity else { return .cancelled }
        guard let identity = admitRecord() else { return .limited }
        let result = await client.submitRating(submission)
        guard enabled, activeIdentity == identity else { return .cancelled }
        return result
    }

    /// Best effort. App termination must never wait for analytics delivery.
    public func flush() {
        guard let client else { return }
        Task(priority: .utility) { await client.flush() }
    }

    private func enable() {
        let identity: UsageIdentity
        if let raw = defaults.string(forKey: Self.identityKey), let id = UUID(uuidString: raw) {
            identity = UsageIdentity(value: id)
        } else {
            identity = UsageIdentity()
        }
        do {
            client = try factory(identity)
            defaults.set(identity.value.uuidString.lowercased(), forKey: Self.identityKey)
            enabled = true
            activeIdentity = identity
            recordsInWindow = 0
            rateWindow = .now
        } catch {
            client = nil
            enabled = false
            activeIdentity = nil
        }
    }

    private func admitRecord() -> UsageIdentity? {
        guard enabled, let activeIdentity else { return nil }
        if rateWindow.duration(to: .now) >= .seconds(60) {
            rateWindow = .now
            recordsInWindow = 0
        }
        // Drop excess calls before allocating an asynchronous task.
        guard recordsInWindow < 120 else { return nil }
        recordsInWindow += 1
        return activeIdentity
    }
}
