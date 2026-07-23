import Foundation
import AVFoundation
import Combine
import OSLog

/// Shared logging point for the camera subsystem (M6's Mirror widget) —
/// mirrors `calendarLog`'s/`hudLog`'s file-scope-constant pattern rather than
/// adding a new case to `Log.swift`, since this is a self-contained M6
/// subsystem the notch suite owns.
let cameraLog = Logger(subsystem: "com.flux.menubar", category: "camera")

/// Headless data layer behind the notch's Mirror widget: owns one
/// `AVCaptureSession` wired to the Mac's built-in camera, and starts/stops
/// it. Publishes `isRunning` for the widget's "Starting camera…" caption,
/// and exposes `session` directly so `MirrorWidget`'s
/// `AVCaptureVideoPreviewLayer` can bind to it.
///
/// ## PERF/PRIVACY CONTRACT: the session NEVER runs unless the Mirror widget
/// is the one currently presented panel.
/// A running `AVCaptureSession` lights the camera's hardware indicator (the
/// green LED next to the lens on every Mac that has one) and spends real
/// CPU/power decoding frames whether or not anything is actually drawing
/// them — there is no such thing as a "cheap, idle" capture session. Every
/// call to `start()`/`stop()` in the whole app is expected to come from
/// `MirrorWidget`'s `willPresent()`/`didDismiss()` (see that type's own doc
/// comment) — never at launch, never on a timer, and never left running
/// after the widget stops being visible. A widget that forgets to call
/// `stop()` on `didDismiss()` is a privacy bug as much as a perf one — the
/// camera indicator staying lit with the notch collapsed is exactly the kind
/// of thing that erodes trust in a menu-bar utility fast.
@MainActor
final class CameraService: ObservableObject {
    /// `true` only once `session.startRunning()` has actually returned having
    /// taken effect — never set optimistically just because `start()` was
    /// called. `MirrorWidget`'s preview shows a "Starting camera…" caption
    /// for as long as this stays `false` after a `start()`, and flips back to
    /// `false` on `stop()`, a runtime error, or an interruption (device
    /// disconnected, claimed by another app, etc. — see
    /// `observeSessionNotifications()`).
    @Published private(set) var isRunning = false

    /// The live session — handed straight to `AVCaptureVideoPreviewLayer` by
    /// `MirrorWidget`'s preview view. Exposed as a plain `let` (rather than
    /// behind an accessor) since a preview layer needs a stable reference to
    /// bind to for this instance's entire lifetime — the same way
    /// `ShelfStore.directory` is exposed directly rather than through a
    /// getter.
    let session = AVCaptureSession()

    /// Whether a usable camera device exists on this Mac at all — resolved
    /// once, eagerly, at `init` (device presence doesn't change without a
    /// relaunch on any real Mac hardware, unlike TCC permission, which is
    /// `PermissionCenter`'s job to track, not this type's). `MirrorWidget`'s
    /// expanded view reads this to show a "no camera found" state instead of
    /// an indefinitely-starting preview.
    private(set) var isAvailable: Bool

    private let device: AVCaptureDevice?
    private var isConfigured = false

    /// Tracks whether the *widget* still wants the session running — set at
    /// the top of `start()`, cleared at the top of `stop()`. This is the only
    /// state this service has for "should I come back after an interruption
    /// ends": it doesn't know anything about `MirrorWidget`'s presentation
    /// state, only whether the most recent lifecycle call was a `start()`
    /// that hasn't since been followed by a `stop()`. `.AVCaptureSessionInterruptionEnded`
    /// checks this flag before restarting the session — an interruption that
    /// ends after `MirrorWidget.didDismiss()` already called `stop()` (e.g.
    /// the user closed the notch while the camera was claimed by another app)
    /// must NOT relight the camera indicator behind the user's back.
    private var wantsRunning = false

    /// Dedicated serial queue for the session itself. `startRunning()`
    /// blocks the calling thread until the session is actually up (per
    /// Apple's own documentation), so it must never run on the main actor —
    /// doing so would freeze the notch's UI for however long camera startup
    /// takes. `stopRunning()` runs on the same queue for the same reason,
    /// and so every session mutation this service performs stays serialized
    /// against every other one.
    private let sessionQueue = DispatchQueue(label: "com.flux.menubar.camera.session")

    /// Tokens for the three `NotificationCenter` observers registered in
    /// `observeSessionNotifications()` — held only so `deinit` can remove
    /// them; nothing else ever reads this array.
    private var sessionNotificationObservers: [NSObjectProtocol] = []

    init() {
        let device = Self.discoverDefaultDevice()
        self.device = device
        self.isAvailable = device != nil
        if !isAvailable {
            cameraLog.notice("CameraService: no built-in camera device found — Mirror widget will show its unavailable state")
        }
        observeSessionNotifications()
    }

    /// Preview/testing seam (M8 fix): constructs a service that reports
    /// `isAvailable == false` unconditionally, regardless of what real camera
    /// hardware the host machine actually has. `NotchSnapshot`'s
    /// `expanded-mirror` render needs its "No camera found" branch to be what
    /// actually renders deterministically — not a coincidence of whichever
    /// machine happens to run `--snapshot-notch` next, which could have a
    /// real built-in camera. `discoverDefaultDevice()` is skipped entirely
    /// when `forcingUnavailable` is `true` (not merely discarding its
    /// result) — the smallest, most honest seam: this never touches
    /// `AVCaptureDevice.DiscoverySession` at all, so a snapshot render can
    /// never accidentally probe/claim real capture hardware.
    init(forcingUnavailable: Bool) {
        if forcingUnavailable {
            self.device = nil
            self.isAvailable = false
            cameraLog.notice("CameraService: constructed with forcingUnavailable — isAvailable is false regardless of real hardware (preview/snapshot use only)")
        } else {
            let device = Self.discoverDefaultDevice()
            self.device = device
            self.isAvailable = device != nil
            if !isAvailable {
                cameraLog.notice("CameraService: no built-in camera device found — Mirror widget will show its unavailable state")
            }
        }
        observeSessionNotifications()
    }

    deinit {
        // Plain teardown of what this instance itself registered, called
        // directly from a nonisolated `deinit` — mirrors
        // `VolumeMonitor.deinit`'s reasoning for doing the same with its own
        // C/notification registrations rather than routing through an
        // instance method. In practice this service
        // is expected to live for the whole app lifetime (owned alongside
        // every other notch-suite service), so this is a defensive
        // safety-net rather than a path exercised in normal operation.
        let center = NotificationCenter.default
        for observer in sessionNotificationObservers {
            center.removeObserver(observer)
        }
        if session.isRunning {
            session.stopRunning()
        }
    }

    // MARK: - Discovery

    /// Resolves the Mac's built-in wide-angle camera via
    /// `AVCaptureDevice.DiscoverySession`. Tries `.front` first — the
    /// position any future/Continuity-Camera-style device that genuinely
    /// self-reports as front-facing would use — then falls back to
    /// `.unspecified`, which is what a plain Mac's built-in FaceTime camera
    /// has historically reported (Macs only ever have one camera, so
    /// "front" vs "back" isn't a meaningful distinction the way it is on
    /// iOS), then finally to `.back` as a last resort so this never misses a
    /// real built-in wide-angle device purely because of which position
    /// enum case it happens to report. `nil` only when no
    /// `.builtInWideAngleCamera` exists at any position at all.
    private static func discoverDefaultDevice() -> AVCaptureDevice? {
        for position in [AVCaptureDevice.Position.front, .unspecified, .back] {
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera],
                mediaType: .video,
                position: position
            )
            if let match = discovery.devices.first {
                return match
            }
        }
        return nil
    }

    // MARK: - Preview mirroring

    /// Whether `MirrorWidget`'s preview-layer connection may have its mirror
    /// configured *right now*. Pure so `--selftest` can cover it without a
    /// camera — the actual `AVCaptureConnection` mutation lives in
    /// `MirrorWidget.CameraPreviewView`, but the *decision* is centralized and
    /// tested here.
    ///
    /// Both conditions are load-bearing against an uncatchable
    /// `NSInvalidArgumentException` (an Obj-C exception Swift can't catch =
    /// instant crash):
    /// - `sessionRunning`: the connection's mirror MUST only be touched once
    ///   `startRunning()` has actually returned. Configuring it while
    ///   `startRunning()` is still executing on `sessionQueue` races that call
    ///   — which re-initializes the connection's own
    ///   `automaticallyAdjustsVideoMirroring` back to `true` as it activates
    ///   connections — so a `isVideoMirrored = true` on the main thread can
    ///   land in the window where auto-adjust flipped back to `true`, and
    ///   setting `isVideoMirrored` while `automaticallyAdjustsVideoMirroring`
    ///   is `true` throws. Gating on the session actually running is what keeps
    ///   the configuration off that race entirely.
    /// - `mirroringSupported`: setting `isVideoMirrored` on a connection whose
    ///   `isVideoMirroringSupported` is `false` throws outright.
    static func shouldConfigureMirroring(sessionRunning: Bool, mirroringSupported: Bool) -> Bool {
        sessionRunning && mirroringSupported
    }

    // MARK: - Lifecycle

    /// Starts the capture session. A no-op if there's no camera device
    /// (`isAvailable == false`) or camera access isn't currently authorized
    /// — checked directly via `AVCaptureDevice.authorizationStatus`, the same
    /// underlying API `PermissionCenter` itself wraps. This is a deliberate,
    /// defensive check rather than a hard dependency on `PermissionCenter`
    /// (mirroring `CalendarService.refresh()` querying
    /// `EKEventStore.authorizationStatus` directly): it means this service
    /// can never be coaxed into lighting the camera indicator without a real
    /// grant, even if some future caller skipped `MirrorWidget`'s own
    /// permission gate.
    ///
    /// Configuration (adding the device input) happens once, guarded by
    /// `isConfigured` — re-adding the same input on every `start()` would
    /// throw. The actual `startRunning()` call is dispatched onto
    /// `sessionQueue` (see its own doc comment for why), and `isRunning` is
    /// only flipped once that call has returned and actually taken effect —
    /// never optimistically before it's known to have worked.
    func start() {
        wantsRunning = true
        guard isAvailable, let device else { return }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            cameraLog.notice("CameraService.start() called without camera authorization — refusing to start")
            return
        }

        configureIfNeeded(device: device)

        let session = session
        sessionQueue.async { [weak self] in
            if !session.isRunning {
                session.startRunning()
            }
            let started = session.isRunning
            DispatchQueue.main.async {
                self?.isRunning = started
            }
        }
    }

    /// Stops the session on the same dedicated queue `start()` uses.
    /// Idempotent and safe to call even if the session was never started —
    /// `MirrorWidget.didDismiss()` calls this unconditionally, every time,
    /// per this type's own perf/privacy contract above.
    func stop() {
        wantsRunning = false
        let session = session
        sessionQueue.async { [weak self] in
            if session.isRunning {
                session.stopRunning()
            }
            DispatchQueue.main.async {
                self?.isRunning = false
            }
        }
    }

    /// Adds the camera's device input to `session` exactly once. Wrapped in
    /// `beginConfiguration()`/`commitConfiguration()` per AVFoundation's own
    /// requirement that input/output/preset changes be batched that way.
    /// Runs on whichever thread `start()` was called from (the main actor) —
    /// deliberately not hopped to `sessionQueue`, since constructing an
    /// `AVCaptureDeviceInput` and adding it is fast; only the actually-
    /// blocking `startRunning()` call needs the background queue.
    private func configureIfNeeded(device: AVCaptureDevice) {
        guard !isConfigured else { return }
        isConfigured = true

        session.beginConfiguration()
        session.sessionPreset = .medium
        defer { session.commitConfiguration() }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                cameraLog.error("CameraService: session refused the camera input")
                return
            }
            session.addInput(input)
        } catch {
            cameraLog.error("CameraService: failed to create a capture input for \(device.localizedName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Session health

    /// Registers for the notifications that can make the session stop
    /// running out from under this service — without any call to `stop()`
    /// of its own. Delivered via `queue: .main` explicitly (not the default
    /// "whichever thread posted it," which for `AVCaptureSession`
    /// notifications is an arbitrary background thread per Apple's own
    /// documentation) so every handler below can touch `isRunning` — a
    /// `@Published`, main-actor-isolated property — directly and safely.
    private func observeSessionNotifications() {
        let center = NotificationCenter.default

        // `AVCaptureSessionInterruptionReasonKey`/`AVCaptureSession.InterruptionReason`
        // are iOS-only (`API_UNAVAILABLE(macos)` on the SDK) — macOS's own
        // `userInfo` for this notification carries no decodable reason at
        // all, so there's nothing further to extract here beyond the fact of
        // the interruption itself.
        let interrupted = center.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: .main) { [weak self] _ in
            self?.isRunning = false
            cameraLog.notice("CameraService: session interrupted — the camera likely became unavailable (another app claimed it, the device was disconnected, etc.)")
        }

        // The counterpart to `.AVCaptureSessionWasInterrupted` above — fired
        // when whatever claimed the camera (another app, a device
        // reconfiguration, ...) releases it again. Without this, a Mirror
        // widget left open across an interruption (e.g. someone opens Camera
        // to scan a QR code, then closes it again) would sit on a
        // permanently-stopped session and "Starting camera…" forever, even
        // though the widget itself never called `stop()`. Only restarts if
        // `wantsRunning` is still `true` — see that property's own doc
        // comment for why this must not resurrect a session the widget
        // itself already asked to stop.
        let interruptionEnded = center.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: .main) { [weak self] _ in
            guard let self, self.wantsRunning else { return }
            cameraLog.notice("CameraService: interruption ended — restarting the session since the widget still wants it running")
            self.start()
        }

        let runtimeError = center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: .main) { [weak self] note in
            self?.isRunning = false
            let message = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "unknown error"
            cameraLog.error("CameraService: runtime error — \(message, privacy: .public)")
        }

        // Purely informational — a physical disconnect is expected to also
        // surface as `.AVCaptureSessionWasInterrupted` or
        // `.AVCaptureSessionRuntimeError` above (which are what actually
        // flip `isRunning`); this just gives the log a clearer breadcrumb
        // for exactly *why* when it was a disconnect specifically.
        let disconnected = center.addObserver(forName: .AVCaptureDeviceWasDisconnected, object: device, queue: .main) { _ in
            cameraLog.notice("CameraService: the camera device was disconnected")
        }

        sessionNotificationObservers = [interrupted, interruptionEnded, runtimeError, disconnected]
    }
}
