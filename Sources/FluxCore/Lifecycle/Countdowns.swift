import Foundation

public struct Countdown: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let duration: TimeInterval
    public let label: String
    public private(set) var deadline: Date?
    private var pausedRemaining: TimeInterval

    public init(id: UUID = UUID(), duration: TimeInterval, label: String, at now: Date) throws {
        guard duration.isFinite, duration > 0, duration <= 7 * 24 * 60 * 60,
              now.timeIntervalSinceReferenceDate.isFinite else { throw CountdownError.invalidDuration }
        self.id = id
        self.duration = duration
        self.label = label
        deadline = now.addingTimeInterval(duration)
        pausedRemaining = duration
    }

    public var isPaused: Bool { deadline == nil }
    public func remaining(at now: Date) -> TimeInterval {
        max(0, deadline?.timeIntervalSince(now) ?? pausedRemaining)
    }

    mutating func pause(at now: Date) {
        guard deadline != nil else { return }
        pausedRemaining = remaining(at: now)
        deadline = nil
    }

    mutating func resume(at now: Date) {
        guard deadline == nil else { return }
        deadline = now.addingTimeInterval(pausedRemaining)
    }
}

public enum CountdownError: Error { case invalidDuration, tooManyTimers }

/// One deadline task for all active timers. No empty-service or one-second
/// polling. The app calls reconcile on wake and system-clock changes.
@MainActor public final class Countdowns {
    public private(set) var timers: [Countdown] = []
    public var onChange: (() -> Void)?
    public var onCompletion: ((Countdown) -> Void)?
    private let now: @MainActor () -> Date
    private var boundary: Task<Void, Never>?
    private var generation: UInt64 = 0

    public init(now: @escaping @MainActor () -> Date = { Date() }) { self.now = now }
    deinit { boundary?.cancel() }

    @discardableResult
    public func start(duration: TimeInterval, label: String) throws -> UUID {
        reconcile()
        guard timers.count < 64 else { throw CountdownError.tooManyTimers }
        let timer = try Countdown(duration: duration, label: label, at: now())
        timers.append(timer)
        changed()
        return timer.id
    }

    public func pause(_ id: UUID) {
        reconcile()
        guard let index = timers.firstIndex(where: { $0.id == id }), !timers[index].isPaused else { return }
        timers[index].pause(at: now())
        changed()
    }

    public func resume(_ id: UUID) {
        reconcile()
        guard let index = timers.firstIndex(where: { $0.id == id }), timers[index].isPaused else { return }
        timers[index].resume(at: now())
        changed()
    }

    public func cancel(_ id: UUID) {
        reconcile()
        let count = timers.count
        timers.removeAll { $0.id == id }
        if timers.count != count { changed() }
    }

    public func cancelAll() {
        timers.removeAll()
        changed()
    }

    public func reconcile() {
        let instant = now()
        let completed = timers.filter { !$0.isPaused && $0.remaining(at: instant) <= 0 }
        let ids = Set(completed.map(\.id))
        timers.removeAll { ids.contains($0.id) }
        armBoundary()
        if !completed.isEmpty { onChange?() }
        for timer in completed { onCompletion?(timer) }
    }

    private func changed() {
        armBoundary()
        onChange?()
    }

    private func armBoundary() {
        generation &+= 1
        boundary?.cancel()
        boundary = nil
        guard let deadline = timers.compactMap(\.deadline).min() else { return }
        let token = generation
        let delay = max(0, deadline.timeIntervalSince(now()))
        boundary = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard let self, self.generation == token else { return }
            self.reconcile()
        }
    }
}
