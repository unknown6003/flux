import Foundation
import FluxCore

/// A single finite copy batch. Removing a pending row skips it. Removing a
/// running row removes its new shelf copy as soon as that copy finishes.
@MainActor
final class ShelfCopyBatch {
    struct Request {
        let id = UUID()
        let source: URL
    }
    typealias Copy = @Sendable (URL) async throws -> ShelvedFile
    typealias Remove = @Sendable (UUID) async throws -> Void
    private let requests: [Request]
    private var cancelled: Set<UUID> = []
    private let copy: Copy
    private let remove: Remove
    private let progress: (UUID) -> Void
    private let finished: (Int, Int) -> Void
    private var task: Task<Void, Never>?

    init(requests: [Request], copy: @escaping Copy, remove: @escaping Remove,
         progress: @escaping (UUID) -> Void, finished: @escaping (Int, Int) -> Void) {
        self.requests = requests
        self.copy = copy
        self.remove = remove
        self.progress = progress
        self.finished = finished
    }

    func cancel(_ id: UUID) { cancelled.insert(id) }
    func cancelAll() { cancelled.formUnion(requests.map(\.id)) }

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor [self] in
            var added = 0
            var failed = 0
            for request in requests {
                if !cancelled.contains(request.id) {
                    do {
                        let item = try await copy(request.source)
                        if cancelled.contains(request.id) { try await remove(item.id) }
                        else { added += 1 }
                    } catch { failed += 1 }
                }
                progress(request.id)
            }
            task = nil
            finished(added, failed)
        }
    }
}
