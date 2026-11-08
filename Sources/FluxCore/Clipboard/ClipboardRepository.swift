import Foundation

/// The history outlives a visible widget and a lock pause. Its listeners are
/// separate service handles. It has no poll, hardware session or analytics.
public actor ClipboardRepository {
    private var history = ClipboardHistory()
    private let file: ClipboardHistoryFile
    private var persistence = false
    private var prepared = false
    private var subscribers: [UUID: AsyncStream<[ClipboardRecord]>.Continuation] = [:]

    public init(historyURL: URL) { file = ClipboardHistoryFile(url: historyURL) }

    public func prepare(persistenceEnabled: Bool, now: Date = .now) async throws {
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
        history.capture(payload, at: date)
        publish()
        if persistence { try await file.save(history.savedEntries, now: date) }
    }

    public func remove(_ id: UUID, now: Date = .now) async throws {
        history.remove(id)
        publish()
        if persistence { try await file.save(history.savedEntries, now: now) }
    }

    public func clear() async throws {
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
    private func publish() {
        for subscriber in subscribers.values { subscriber.yield(history.records) }
    }
}
