import Foundation
import Testing
import FluxCore
@testable import FluxApplication

private actor DecodeGate {
    private var continuation: CheckedContinuation<ArtworkImage?, Never>?
    private(set) var inputs: [Data] = []
    func decode(_ data: Data) async -> ArtworkImage? {
        inputs.append(data)
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(returning: nil); continuation = nil }
}

private actor CopyGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    func wait() async {
        calls += 1
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

struct WidgetWorkTests {
    private enum Deadline: Error { case exceeded }
    @MainActor private func waitFor(_ condition: @MainActor () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !(await condition()) {
            guard clock.now < deadline else { throw Deadline.exceeded }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test @MainActor func artworkCoalescesWhileDecodeRunsAndDropsWorkOnDismiss() async throws {
        let gate = DecodeGate()
        var delivered: [UUID] = []
        let pipeline = ArtworkPipeline(decode: { await gate.decode($0) }, receive: { id, _ in delivered.append(id) })
        pipeline.submit(id: UUID(), bytes: Data([0]))
        try await waitFor { await gate.inputs.count == 1 }
        for index in 1...30 { pipeline.submit(id: UUID(), bytes: Data([UInt8(index)])) }
        #expect(await gate.inputs == [Data([0])])
        await gate.release()
        try await waitFor { await gate.inputs.count == 2 }
        #expect(await gate.inputs == [Data([0]), Data([30])])
        #expect(delivered.isEmpty)
        pipeline.submit(id: UUID(), bytes: Data([31]))
        pipeline.clear()
        await gate.release()
        // A new request must follow the second decode, without the cleared one.
        let final = UUID()
        pipeline.submit(id: final, bytes: Data([32]))
        try await waitFor { await gate.inputs.count == 3 }
        #expect(await gate.inputs.last == Data([32]))
        await gate.release()
        try await waitFor { delivered == [final] }
    }

    @Test @MainActor func removingRunningAndPendingCopiesLeavesOnlyOriginalFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flux-batch-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.txt")
        try Data("original".utf8).write(to: source)
        let shelf = ShelfFiles(root: root.appendingPathComponent("shelf"))
        let gate = CopyGate()
        let requests = [ShelfCopyBatch.Request(source: source), ShelfCopyBatch.Request(source: source)]
        var finished: (Int, Int)?
        let batch = ShelfCopyBatch(requests: requests, copy: { source in
            await gate.wait()
            return try await shelf.addCopy(of: source)
        }, remove: { try await shelf.remove([$0]) }, progress: { _ in }, finished: { finished = ($0, $1) })
        batch.start()
        try await waitFor { await gate.calls == 1 }
        batch.cancel(requests[0].id)
        batch.cancel(requests[1].id)
        await gate.release()
        try await waitFor { finished != nil }
        #expect(finished?.0 == 0)
        #expect(finished?.1 == 0)
        #expect(await gate.calls == 1)
        #expect(try await shelf.load().isEmpty)
        #expect(try Data(contentsOf: source) == Data("original".utf8))
    }
}
