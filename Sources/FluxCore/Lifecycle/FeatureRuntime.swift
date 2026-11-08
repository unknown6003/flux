/// A live listener or hardware session. Stop must revoke its callbacks and
/// pending start work before it returns. A stopped handle is never reused.
@MainActor public protocol FeatureServiceHandle: AnyObject {
    func stop()
}

/// Constructs only requested services. The app supplies real platform owners,
/// so this module has no dependency on AppKit, devices or permission prompts.
@MainActor public final class FeatureRuntime {
    public typealias Factory = @MainActor (FeatureService) throws -> any FeatureServiceHandle
    private let factory: Factory
    private var handles: [FeatureService: any FeatureServiceHandle] = [:]

    public init(factory: @escaping Factory) {
        self.factory = factory
    }

    public var active: Set<FeatureService> { Set(handles.keys) }

    /// A failed service remains absent and can be retried on the next state
    /// change. It does not stop independent features from starting.
    @discardableResult
    public func apply(_ demand: FeatureDemand) -> Set<FeatureService> {
        let changes = ServiceChanges(active: active, requested: demand.services)
        for service in changes.stop {
            handles.removeValue(forKey: service)?.stop()
        }
        var failed: Set<FeatureService> = []
        for service in changes.start {
            do { handles[service] = try factory(service) }
            catch { failed.insert(service) }
        }
        return failed
    }

    /// Called before application shutdown. This also releases all handles.
    public func stop() {
        for service in FeatureService.allCases {
            handles.removeValue(forKey: service)?.stop()
        }
    }
}
