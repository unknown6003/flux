import AVFoundation
import Foundation
import Testing
@testable import FluxPlatform

private struct NoCameraPreview: CameraPreviewSource {
    @MainActor func connect(to layer: AVCaptureVideoPreviewLayer) {}
}

private actor GatedCameraDriver: CameraDriving {
    nonisolated let previewSource: any CameraPreviewSource = NoCameraPreview()
    private let stream: AsyncStream<CameraState>
    private let output: AsyncStream<CameraState>.Continuation
    private var pending: CheckedContinuation<CameraState, Never>?
    private var started = false
    private var stopped = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var stopWaiter: CheckedContinuation<Void, Never>?

    init() {
        let channel = AsyncStream<CameraState>.makeStream()
        stream = channel.stream
        output = channel.continuation
    }

    func events() -> AsyncStream<CameraState> { stream }
    func start() async -> CameraState {
        started = true
        return await withCheckedContinuation { continuation in
            pending = continuation
            startWaiter?.resume()
            startWaiter = nil
        }
    }
    func stop() {
        stopped = true
        output.finish()
        stopWaiter?.resume()
        stopWaiter = nil
    }
    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func waitForStop() async {
        if stopped { return }
        await withCheckedContinuation { stopWaiter = $0 }
    }
    func completeStart() { pending?.resume(returning: .running); pending = nil }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func closingMirrorDuringStartupStopsItsDriverAndReleasesItsFeed() async {
    let driver = GatedCameraDriver()
    var changes: [CameraState] = []
    var feed: CameraFeed? = CameraFeed(driver: driver) { changes.append($0) }
    weak var released = feed
    await driver.waitForStart()
    #expect(changes == [.starting])
    feed?.stop()
    feed = nil
    #expect(released == nil)
    await driver.waitForStop()
    await driver.completeStart()
    #expect(changes == [.starting])
}

@MainActor @Test(.timeLimit(.minutes(1)))
func releasingMirrorWithoutAnExplicitStopStillStopsItsDriver() async {
    let driver = GatedCameraDriver()
    var feed: CameraFeed? = CameraFeed(driver: driver) { _ in }
    weak var released = feed
    await driver.waitForStart()
    feed = nil
    #expect(released == nil)
    await driver.waitForStop()
    await driver.completeStart()
}
