import Foundation
import Testing
import FluxCore
import FluxPlatform
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

@MainActor private final class ShelfExpiryEffects: WidgetEffects {
    var failures: [WidgetFailure] = []
    func requestAccess(_ permission: WidgetPermission) async { Issue.record("Unexpected permission prompt") }
    func openSettings(_ permission: WidgetPermission) { Issue.record("Unexpected Settings") }
    func retry(_ service: FeatureService) { Issue.record("Unexpected service retry") }
    func report(_ failure: WidgetFailure) { failures.append(failure) }
    func widgetEvent(_ event: WidgetEvent) { Issue.record("Unexpected widget event") }
}

@MainActor private final class ShelfDropEffects: WidgetEffects {
    var completions = 0
    func requestAccess(_ permission: WidgetPermission) async { Issue.record("Unexpected permission prompt") }
    func openSettings(_ permission: WidgetPermission) { Issue.record("Unexpected Settings") }
    func retry(_ service: FeatureService) { Issue.record("Unexpected service retry") }
    func report(_ failure: WidgetFailure) { Issue.record("Unexpected shelf failure") }
    func widgetEvent(_ event: WidgetEvent) {
        if case .shelfCopyFinished(let added, let failed) = event {
            #expect(added == 1 && failed == 0)
            completions += 1
        } else { Issue.record("Unexpected widget event") }
    }
}

struct WidgetWorkTests {
    @Test @MainActor func windowShelfDropsUseOneOwnedCopyJobAndRejectAClosedVisit() async throws {
        let domain = "org.fluxfixture.shelf-drop.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = PreferenceStore(defaults: defaults, domain: domain, evidence: .init())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flux-shelf-drop-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.txt")
        let bytes = Data("preserve the original".utf8)
        try bytes.write(to: original)
        let shelf = ShelfFiles(root: root.appendingPathComponent("Shelf"))
        let effects = ShelfDropEffects()
        let widgets = WidgetCoordinator(preferences: preferences, shelf: shelf,
            clipboard: ClipboardRepository(historyURL: root.appendingPathComponent("unused.json")),
            pasteboard: PasteboardChannel(), mediaScript: root, mediaFramework: root, effects: effects)
        #expect(!widgets.acceptShelfDrop([original]))
        let controller = widgets.makeWidget(.shelf)
        try await waitFor { widgets.acceptsShelfDrop }
        #expect(widgets.acceptShelfDrop([original]))
        #expect(!widgets.acceptShelfDrop([original]))
        try await waitFor { effects.completions == 1 && widgets.acceptsShelfDrop }
        #expect(try await shelf.load().count == 1)
        #expect(try Data(contentsOf: original) == bytes)
        try preferences.set(false, for: Preferences.shelfEnabled)
        #expect(!widgets.acceptShelfDrop([original]))
        try preferences.set(true, for: Preferences.shelfEnabled)
        widgets.dismiss()
        #expect(!widgets.acceptShelfDrop([original]))
        #expect(try await shelf.load().count == 1)
        withExtendedLifetime(controller) {}
    }

    @Test @MainActor func aSavedShelfExpirySweepsOwnedCopiesWithoutOpeningAWidget() async throws {
        let domain = "org.fluxfixture.expiry.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = PreferenceStore(defaults: defaults, domain: domain, evidence: .init())
        try preferences.set(3, for: Preferences.shelfExpiryDays)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flux-expiry-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.txt")
        try Data("preserve original".utf8).write(to: original)
        let shelf = ShelfFiles(root: root.appendingPathComponent("Shelf"))
        let old = try await shelf.addCopy(of: original, at: Date().addingTimeInterval(-4 * 86_400))
        let recent = try await shelf.addCopy(of: original)
        let effects = ShelfExpiryEffects()
        let widgets = WidgetCoordinator(preferences: preferences, shelf: shelf,
            clipboard: ClipboardRepository(historyURL: root.appendingPathComponent("not-created.json")),
            pasteboard: PasteboardChannel(), mediaScript: root, mediaFramework: root, effects: effects)
        widgets.refresh()
        try await waitFor { (try? await shelf.load().count) == 1 }
        #expect(try await shelf.load().map(\.id) == [recent.id])
        #expect(!FileManager.default.fileExists(atPath: old.directory(in: root.appendingPathComponent("Shelf")).path))
        #expect(try Data(contentsOf: original) == Data("preserve original".utf8))
        #expect(effects.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("not-created.json").path))
    }

    @Test @MainActor func aCalendarCompanionKeepsThePrimaryWidgetBoundUntilOnlyTheCompanionCloses() throws {
        let domain = "org.fluxfixture.companion.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = PreferenceStore(defaults: defaults, domain: domain, evidence: .init())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flux-companion-\(UUID())")
        let effects = ShelfExpiryEffects()
        let widgets = WidgetCoordinator(preferences: preferences, shelf: ShelfFiles(root: root.appendingPathComponent("Shelf")),
            clipboard: ClipboardRepository(historyURL: root.appendingPathComponent("clipboard.json")),
            pasteboard: PasteboardChannel(), mediaScript: root, mediaFramework: root, effects: effects)
        let primary = widgets.makeWidget(.nowPlaying)
        let companion = widgets.makeCalendarCompanion()
        var changed: Set<Widget> = []
        widgets.onContentChange = { changed.insert($0) }
        widgets.refresh()
        #expect(changed == [.nowPlaying, .calendar])
        widgets.removeCalendarCompanion()
        changed = []
        widgets.refresh()
        #expect(changed == [.nowPlaying])
        widgets.dismiss()
        changed = []
        widgets.refresh()
        #expect(changed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        withExtendedLifetime((primary, companion)) {}
    }

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
