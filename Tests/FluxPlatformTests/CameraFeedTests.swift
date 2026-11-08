import AVFoundation
import Foundation
import Testing
@testable import FluxPlatform

private struct NoCameraPreview: CameraPreviewSource {
    @MainActor func connect(to layer: AVCaptureVideoPreviewLayer) {}
}

private actor GatedCameraDriver: CameraDriving {
    nonisolated let previewSource: any CameraPreviewSource
    private let stream: AsyncStream<CameraState>
    private let output: AsyncStream<CameraState>.Continuation
    private var pending: CheckedContinuation<CameraState, Never>?
    private var started = false
    private var stopped = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var stopWaiter: CheckedContinuation<Void, Never>?

    init(previewSource: any CameraPreviewSource = NoCameraPreview()) {
        self.previewSource = previewSource
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

private final class SessionPreview: CameraPreviewSource, @unchecked Sendable {
    let session = AVCaptureSession()
    @MainActor func connect(to layer: AVCaptureVideoPreviewLayer) { layer.session = session }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func retryingMirrorCannotLetOldShutdownDetachItsNewPreview() async {
    let originalSource = SessionPreview()
    let replacementSource = SessionPreview()
    let originalDriver = GatedCameraDriver(previewSource: originalSource)
    let replacementDriver = GatedCameraDriver(previewSource: replacementSource)
    let layer = AVCaptureVideoPreviewLayer()
    let original = CameraFeed(driver: originalDriver) { _ in }
    await originalDriver.waitForStart()
    original.connectPreview(to: layer)
    #expect(layer.session === originalSource.session)
    original.stop()
    // No actor hop: stop must release the layer before retry attaches it.
    #expect(layer.session == nil)
    let replacement = CameraFeed(driver: replacementDriver) { _ in }
    replacement.connectPreview(to: layer)
    await replacementDriver.waitForStart()
    await originalDriver.waitForStop()
    await originalDriver.completeStart()
    // Let the old feed's main-actor teardown finish too.
    try? await Task.sleep(for: .milliseconds(20))
    #expect(layer.session === replacementSource.session)
    replacement.stop()
    await replacementDriver.waitForStop()
    await replacementDriver.completeStart()
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
