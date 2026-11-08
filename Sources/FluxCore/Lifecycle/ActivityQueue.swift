import Foundation

public enum ActivityKind: CaseIterable, Sendable {
    case battery, bluetoothDevice, timer, shelfDrop, menuBarOverflow, nowPlaying, calendarEvent, soundHUD
}
public enum ActivityTint: Sendable { case normal, warning }
public enum ActivityWing: Equatable, Sendable {
    case none, artwork
    case symbol(String), text(String), symbolText(symbol: String, text: String)
    case gauge(value: Double, symbol: String), soundGauge(value: Double, symbol: String)

    fileprivate var bounded: Self {
        switch self {
        case .none, .artwork: return self
        case .symbol(let name): return .symbol(String(name.prefix(80)))
        case .text(let text): return .text(String(text.prefix(120)))
        case .symbolText(let symbol, let text): return .symbolText(symbol: String(symbol.prefix(80)), text: String(text.prefix(120)))
        case .gauge(let value, let symbol): return .gauge(value: value.isFinite ? min(max(value, 0), 1) : 0, symbol: String(symbol.prefix(80)))
        case .soundGauge(let value, let symbol): return .soundGauge(value: value.isFinite ? min(max(value, 0), 1) : 0, symbol: String(symbol.prefix(80)))
        }
    }
}

public struct ActivityItem: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: ActivityKind
    public let leading: ActivityWing
    public let trailing: ActivityWing
    public let priority: Int
    public let tint: ActivityTint
    public let duration: TimeInterval?

    public init(id: UUID = UUID(), kind: ActivityKind, leading: ActivityWing, trailing: ActivityWing,
                priority: Int, tint: ActivityTint = .normal, duration: TimeInterval?) throws {
        if let duration, !duration.isFinite || duration < 0 || duration > 7 * 86400 { throw ActivityError.invalidDuration }
        self.id = id
        self.kind = kind
        self.leading = leading.bounded
        self.trailing = trailing.bounded
        self.priority = priority
        self.tint = tint
        self.duration = duration
    }

    fileprivate func retaining(_ id: UUID) -> Self {
        Self(copy: self, id: id)
    }

    private init(copy: Self, id: UUID) {
        self.id = id; kind = copy.kind; leading = copy.leading; trailing = copy.trailing
        priority = copy.priority; tint = copy.tint; duration = copy.duration
    }
}

public enum ActivityError: Error { case invalidDuration }

/// At most one item per kind, five dismissed items, and one deadline task.
/// There is no repeating tick. The app reconciles on wake and clock changes.
@MainActor public final class ActivityQueue {
    private struct Entry { var item: ActivityItem; var deadline: Date? }
    public private(set) var current: ActivityItem?
    public var onChange: (() -> Void)?
    public var count: Int { entries.count }
    public var restorableCount: Int { dismissed.count }
    private var entries: [Entry] = []
    private var dismissed: [Entry] = []
    private var cursor: UUID?
    private let now: @MainActor () -> Date
    private var boundary: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var armedDeadline: Date?
    private var publishedCount = 0
    private var publishedRestorableCount = 0

    public init(now: @escaping @MainActor () -> Date = { .now }) { self.now = now }
    deinit { boundary?.cancel() }

    public func post(_ item: ActivityItem) {
        if item.duration == 0 { remove(item.kind); return }
        reconcile()
        dismissed.removeAll { $0.item.kind == item.kind }
        let deadline = item.duration.map { now().addingTimeInterval($0) }
        if let index = entries.firstIndex(where: { $0.item.kind == item.kind }) {
            entries[index] = Entry(item: item.retaining(entries[index].item.id), deadline: deadline)
        } else { entries.append(Entry(item: item, deadline: deadline)) }
        publish()
    }

    public func remove(_ kind: ActivityKind) {
        entries.removeAll { $0.item.kind == kind }
        dismissed.removeAll { $0.item.kind == kind }
        publish()
    }

    public func cycle() {
        reconcile()
        guard entries.count > 1 else { return }
        let index = entries.firstIndex { $0.item.id == current?.id } ?? 0
        cursor = entries[(index + 1) % entries.count].item.id
        publish()
    }

    public func dismissCurrent() {
        reconcile()
        guard let id = current?.id, let index = entries.firstIndex(where: { $0.item.id == id }) else { return }
        dismissed.append(entries.remove(at: index))
        dismissed = Array(dismissed.suffix(5))
        publish()
    }

    public func restoreLastDismissed() {
        reconcile()
        while let entry = dismissed.popLast() {
            guard entry.deadline.map({ $0 > now() }) ?? true,
                  !entries.contains(where: { $0.item.kind == entry.item.kind }) else { continue }
            entries.append(entry)
            cursor = entry.item.id
            break
        }
        publish()
    }

    public func reconcile() {
        let date = now()
        let before = entries.count
        entries.removeAll { $0.deadline.map { $0 <= date } ?? false }
        if entries.count != before { publish() } else { armBoundary() }
    }

    public func clear() {
        entries = []; dismissed = []; cursor = nil
        publish()
    }

    private func publish() {
        let previous = current
        if let cursor, let entry = entries.first(where: { $0.item.id == cursor }) { current = entry.item }
        else {
            cursor = nil
            current = entries.max { $0.item.priority < $1.item.priority }?.item
        }
        armBoundary()
        let changed = previous != current || publishedCount != entries.count || publishedRestorableCount != dismissed.count
        publishedCount = entries.count
        publishedRestorableCount = dismissed.count
        if changed { onChange?() }
    }

    private func armBoundary() {
        let deadline = entries.compactMap(\.deadline).min()
        if deadline == armedDeadline, boundary != nil { return }
        generation &+= 1
        boundary?.cancel(); boundary = nil
        armedDeadline = deadline
        guard let deadline else { return }
        let token = generation
        let delay = max(0, deadline.timeIntervalSince(now()))
        boundary = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.generation == token else { return }
            self.boundary = nil
            self.armedDeadline = nil
            self.reconcile()
        }
    }
}
