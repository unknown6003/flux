import Foundation

public enum ClipboardRepositoryError: Error { case busy }

/// The history outlives a visible widget and a lock pause. Its listeners are
/// separate service handles. It has no poll, hardware session or analytics.
public actor ClipboardRepository {
    private var history = ClipboardHistory()
    private let file: ClipboardHistoryFile
    private var persistence = false
    private var prepared = false
    private var subscribers: [UUID: AsyncStream<[ClipboardRecord]>.Continuation] = [:]
    private var working = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init(historyURL: URL) { file = ClipboardHistoryFile(url: historyURL) }

    public func prepare(persistenceEnabled: Bool, now: Date = .now) async throws {
        try await acquire()
        defer { release() }
        guard !prepared else { return }
        if persistenceEnabled {
            try await file.setPersistenceEnabled(true)
            history.restore(try await file.load(now: now))
            persistence = true
            publish()
        }
        prepared = true
    }

    public func setPersistenceEnabled(_ enabled: Bool, now: Date = .now) async throws {
        try await acquire()
        defer { release() }
        persistence = false
        try await file.setPersistenceEnabled(enabled)
        if enabled {
            history.restore(try await file.load(now: now))
            persistence = true
            try await file.save(history.savedEntries, now: now)
        }
        prepared = true
        publish()
    }

    public func snapshot() -> [ClipboardRecord] { history.records }
    public func record(for id: UUID) -> ClipboardRecord? { history.records.first { $0.id == id } }

    public func capture(_ payload: ClipboardPayload, at date: Date = .now) async throws {
        try await acquire()
        defer { release() }
        history.capture(payload, at: date)
        publish()
        if persistence { try await file.save(history.savedEntries, now: date) }
    }

    public func remove(_ id: UUID, now: Date = .now) async throws {
        try await acquire()
        defer { release() }
        history.remove(id)
        publish()
        if persistence { try await file.save(history.savedEntries, now: now) }
    }

    public func clear() async throws {
        try await acquire()
        defer { release() }
        history.clear()
        publish()
        try await file.clear()
    }

    public func updates() -> AsyncStream<[ClipboardRecord]> {
        let channel = AsyncStream<[ClipboardRecord]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        guard subscribers.count < 2 else { channel.continuation.finish(); return channel.stream }
        let id = UUID()
        subscribers[id] = channel.continuation
        channel.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        channel.continuation.yield(history.records)
        return channel.stream
    }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }
    // Serialize complete history/file transactions across actor suspension.
    // Contention is bounded so a slow disk cannot retain an unbounded copy queue.
    private func acquire() async throws {
        guard working else { working = true; return }
        guard waiting.count < 8 else { throw ClipboardRepositoryError.busy }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty { working = false }
        else { waiting.removeFirst().resume() }
    }
    private func publish() {
        for subscriber in subscribers.values { subscriber.yield(history.records) }
    }
}
