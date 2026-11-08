import AVFoundation
import Foundation
import FluxCore

public enum CameraState: Equatable, Sendable {
    case starting, running, needsPermission, unavailable, interrupted, failed
}

/// The preview connection is the only capture object exposed to a view.
public protocol CameraPreviewSource: Sendable {
    @MainActor func connect(to layer: AVCaptureVideoPreviewLayer)
}

public protocol CameraDriving: Sendable {
    var previewSource: any CameraPreviewSource { get }
    func start() async -> CameraState
    func stop() async
}

/// Only the immutable session reference crosses actors. The UI attaches its
/// preview layer; all session configuration and running state stay on CameraDriver.
/// This is the preview-source separation used by Apple's AVCam sample.
private final class PreviewConnection: CameraPreviewSource, @unchecked Sendable {
    private let session: AVCaptureSession
    init(session: AVCaptureSession) { self.session = session }
    @MainActor func connect(to layer: AVCaptureVideoPreviewLayer) { layer.session = session }
}

/// A fresh driver is created only for a visible, permitted Mirror. It has no
/// microphone input, frame buffers, photo output, recording output or disk path.
public actor CameraDriver: CameraDriving {
    public nonisolated let previewSource: any CameraPreviewSource
    private let session: AVCaptureSession
    private var ended = false
    private var configured = false

    public init() {
        let session = AVCaptureSession()
        self.session = session
        previewSource = PreviewConnection(session: session)
    }

    public func start() -> CameraState {
        guard !ended, !Task.isCancelled else { return .unavailable }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return .needsPermission }
        do {
            if !configured {
                guard let device = AVCaptureDevice.default(for: .video) else { return .unavailable }
                let input = try AVCaptureDeviceInput(device: device)
                session.beginConfiguration()
                guard session.canAddInput(input) else {
                    session.commitConfiguration()
                    return .unavailable
                }
                if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
                session.addInput(input)
                session.commitConfiguration()
                configured = true
            }
            guard !Task.isCancelled else { return .unavailable }
            session.startRunning()
            return session.isRunning ? .running : .failed
        } catch { return .failed }
    }

    public func stop() {
        ended = true
        if session.isRunning { session.stopRunning() }
        if configured {
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            session.commitConfiguration()
            configured = false
        }
    }
}

/// The app creates this handle only while Mirror is visible. Stop cancels
/// startup, rejects late state updates and drains the driver off the UI actor.
@MainActor public final class CameraFeed: FeatureServiceHandle {
    public var onChange: ((CameraState) -> Void)?
    private let driver: any CameraDriving
    private var startup: Task<Void, Never>?
    private weak var preview: AVCaptureVideoPreviewLayer?
    private var active = true

    public init(driver: any CameraDriving, onChange: @escaping (CameraState) -> Void) {
        self.driver = driver
        self.onChange = onChange
        onChange(.starting)
        startup = Task { @MainActor [weak self, driver] in
            let state = await driver.start()
            guard let self, self.active, !Task.isCancelled else { return }
            self.onChange?(state)
        }
    }

    deinit {
        startup?.cancel()
        let driver = driver
        Task { await driver.stop() }
    }

    public func connectPreview(to layer: AVCaptureVideoPreviewLayer) {
        guard active else { return }
        preview = layer
        layer.videoGravity = .resizeAspectFill
        driver.previewSource.connect(to: layer)
    }

    public func stop() {
        guard active else { return }
        active = false
        onChange = nil
        startup?.cancel()
        startup = nil
        let driver = driver
        let layer = preview
        preview = nil
        Task { @MainActor in
            await driver.stop()
            layer?.session = nil
        }
    }
}
