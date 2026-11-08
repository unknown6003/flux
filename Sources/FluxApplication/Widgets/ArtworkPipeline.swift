import Foundation

/// ImageIO is synchronous and cannot interrupt a decode. Keep one decode and
/// one replaceable latest request, including while the panel is closed.
@MainActor
final class ArtworkPipeline {
    typealias Decode = @Sendable (Data) async -> ArtworkImage?
    private struct Request {
        let id: UUID
        let bytes: Data
        let generation: UInt64
    }
    private let decode: Decode
    private let receive: (UUID, ArtworkImage?) -> Void
    private var generation: UInt64 = 0
    private var pending: Request?
    private var running: Task<Void, Never>?

    init(decode: @escaping Decode = { bytes in
        await Task.detached(priority: .utility) { ArtworkThumbnail.make(bytes) }.value
    }, receive: @escaping (UUID, ArtworkImage?) -> Void) {
        self.decode = decode
        self.receive = receive
    }

    func submit(id: UUID, bytes: Data) {
        generation &+= 1
        pending = Request(id: id, bytes: bytes, generation: generation)
        drain()
    }

    func clear() {
        generation &+= 1
        pending = nil
    }

    private func drain() {
        guard running == nil, let request = pending else { return }
        pending = nil
        let decode = decode
        running = Task { @MainActor [weak self] in
            let image = await decode(request.bytes)
            guard let self else { return }
            self.running = nil
            if self.generation == request.generation { self.receive(request.id, image) }
            self.drain()
        }
    }
}
