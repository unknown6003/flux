import Foundation

/// A lock-session command keeps this permission across its actor hop. The
/// final process launch and revocation use the same small critical section.
public final class MediaCommandAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = true
    public init() {}
    public func revoke() { lock.lock(); allowed = false; lock.unlock() }
    func perform(_ action: () throws -> Void) rethrows -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard allowed else { return false }
        try action()
        return true
    }
}
