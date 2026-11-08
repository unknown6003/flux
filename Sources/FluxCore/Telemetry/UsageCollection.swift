import Foundation

/// The app owns this small controller. A disabled profile never constructs a
/// transport, analytics actor, queue or identifier during startup.
@MainActor
public final class UsageCollection {
    public static let enabledKey = "flux.analytics.enabled.v1"
    public static let identityKey = "flux.analytics.randomID.v1"
    private let defaults: UserDefaults
    private let factory: @MainActor (UsageIdentity) throws -> PostHogClient
    private var client: PostHogClient?
    public private(set) var enabled = false

    public init(
        defaults: UserDefaults,
        factory: @escaping @MainActor (UsageIdentity) throws -> PostHogClient
    ) {
        self.defaults = defaults
        self.factory = factory
    }

    /// Restore only a saved opt-in. Missing keys do not silently enable a new collector.
    public func start() {
        guard !enabled, defaults.object(forKey: Self.enabledKey) as? Bool == true else { return }
        enable()
    }

    public func setEnabled(_ value: Bool) async {
        defaults.set(value, forKey: Self.enabledKey)
        if value {
            if !enabled { enable() }
        } else {
            enabled = false
            let previous = client
            client = nil
            await previous?.disable()
        }
    }

    public func resetIdentity() async {
        let replacement = UsageIdentity()
        defaults.set(replacement.value.uuidString.lowercased(), forKey: Self.identityKey)
        await client?.resetIdentity(replacement)
    }

    /// Fire after an action settles. The caller never awaits networking or encoding.
    public func record(_ event: UsageEvent) {
        guard let client else { return }
        Task(priority: .utility) { await client.record(event) }
    }

    public func log(_ code: UsageLogCode, level: UsageLogLevel = .info) {
        guard let client else { return }
        Task(priority: .utility) { await client.log(code, level: level) }
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
        } catch {
            client = nil
            enabled = false
        }
    }
}
