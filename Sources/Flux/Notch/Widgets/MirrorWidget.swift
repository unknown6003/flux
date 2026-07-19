import SwiftUI
import AVFoundation
import AppKit
import Combine

/// Wraps `CameraService` + `PermissionCenter` as a `NotchWidget`: a live,
/// mirrored camera preview when camera access is granted, or a permission
/// explainer (via the shared `PermissionGatedView` — see that type's own doc
/// comment, which already anticipated this exact reuse) when it isn't.
///
/// ## Lifecycle ownership: THIS widget owns `CameraService.start()`/`stop()`
/// directly — unlike `CalendarWidget`, which deliberately owns none of
/// `CalendarService`'s lifecycle (see that type's own doc comment on why:
/// Calendar has a second, independent reason to run — the event-soon live
/// activity — so a shared router had to own it centrally to avoid two
/// owners fighting over `start()`/`stop()`). The camera has no such second
/// consumer: the ONLY reason `CameraService` should ever run is this widget
/// being open, so a single, simple owner is the correct shape here, not an
/// unnecessary generalization to match Calendar's more complex case.
///
/// `willPresent()` subscribes to `permissions.$statuses` for as long as the
/// widget stays open (rather than only checking once) so a grant that lands
/// *during* this presentation — the user taps "Grant Access" right here, or
/// returns from System Settings while the panel is still open — starts the
/// camera immediately, instead of leaving the view stuck on its now-stale
/// explainer until the next time the widget happens to be reopened. Every
/// change in that live status (not just the initial one) also calls
/// `stop()` when access isn't granted, so a permission revoked mid-session
/// can't leave the session running.
///
/// `didDismiss()` unconditionally calls `service.stop()` — the notch suite's
/// perf/privacy contract on this service (see `CameraService`'s own doc
/// comment) is enforced here, in the one place that matters.
@MainActor
final class MirrorWidget: NotchWidget {
    let id: WidgetID = .mirror

    /// Settings-driven; set by the wiring agent's Combine sink from
    /// `SettingsStore.notchMirrorEnabled` (or equivalent). `NotchWidgetRegistry`
    /// reads this every time it computes `enabledWidgets`.
    var isEnabled: Bool

    let service: CameraService
    let permissions: PermissionCenter

    /// Holds the `permissions.$statuses` subscription started in
    /// `willPresent()` and torn down in `didDismiss()` — see the type's own
    /// doc comment for why this widget needs a *live* subscription rather
    /// than a one-shot check.
    private var cancellables = Set<AnyCancellable>()

    init(service: CameraService,
         permissions: PermissionCenter,
         isEnabled: Bool = true) {
        self.service = service
        self.permissions = permissions
        self.isEnabled = isEnabled
    }

    // MARK: - NotchWidget

    func makeExpandedView() -> AnyView {
        AnyView(MirrorExpandedView(service: service, permissions: permissions))
    }

    /// No compact/collapsed-strip presence — like `ShelfWidget`/
    /// `CalendarWidget`, the mirror only shows once expanded. There's no
    /// collapsed-notch signal worth showing for "the camera is available"
    /// the way there is for Now Playing or an imminent calendar event.
    func makeCompactView() -> AnyView? { nil }

    /// Re-checks the *current* permission status, then subscribes to every
    /// future change in it for as long as this presentation lasts — see the
    /// type's own doc comment. `permissions.$statuses` immediately re-emits
    /// its current value to a brand-new subscriber, so this single
    /// subscription alone (no separate initial check needed) covers both
    /// "already granted when the widget opened" and "granted moments after."
    func willPresent() {
        permissions.refresh(.camera)
        permissions.$statuses
            .sink { [weak self] statuses in
                guard let self else { return }
                if statuses[.camera] == .granted {
                    self.service.start()
                } else {
                    self.service.stop()
                }
            }
            .store(in: &cancellables)
    }

    /// Tears down the live permission subscription and — unconditionally,
    /// regardless of whether the camera ever actually started — stops the
    /// session. This is the enforcement point for `CameraService`'s
    /// perf/privacy contract: the camera indicator must never stay lit past
    /// the moment this widget stops being visible.
    func didDismiss() {
        cancellables.removeAll()
        service.stop()
    }
}

// MARK: - Expanded panel view

/// The expanded panel: the permission explainer/preview split is entirely
/// `PermissionGatedView`'s job — this view only supplies the mirror-specific
/// copy/icon and the live preview shown once granted.
private struct MirrorExpandedView: View {
    @ObservedObject var service: CameraService
    @ObservedObject var permissions: PermissionCenter

    var body: some View {
        PermissionGatedView(
            kind: .camera,
            permissions: permissions,
            icon: "video.fill",
            notDeterminedMessage: "Flux can show a quick mirror using your Mac's camera.",
            deniedMessage: "Camera access is off. Turn it on in System Settings to use the mirror."
        ) {
            preview
        }
    }

    @ViewBuilder
    private var preview: some View {
        if service.isAvailable {
            ZStack(alignment: .bottom) {
                CameraPreviewView(service: service)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                if !service.isRunning {
                    startingCaption
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            unavailableState
        }
    }

    private var startingCaption: some View {
        Text("Starting camera…")
            .font(.caption)
            .foregroundStyle(Color.white.opacity(0.8))
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(Color.black.opacity(0.45), in: Capsule())
            .padding(.bottom, 10)
    }

    private var unavailableState: some View {
        VStack(spacing: 6) {
            Image(systemName: "video.slash")
                .font(.system(size: 22))
                .foregroundStyle(Theme.accentColor.opacity(0.5))
            Text("No camera found")
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Live preview (AppKit bridge)

/// Hosts an `AVCaptureVideoPreviewLayer` bound to `service.session`. A plain
/// `NSViewRepresentable` rather than any SwiftUI-native camera view, since
/// SwiftUI has no such view — this is the standard AVFoundation-on-AppKit
/// bridge.
private struct CameraPreviewView: NSViewRepresentable {
    @ObservedObject var service: CameraService

    func makeNSView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.previewLayer.session = service.session
        view.configureMirroringIfNeeded()
        return view
    }

    func updateNSView(_ nsView: PreviewContainerView, context: Context) {
        // `service.session` itself never changes identity across this
        // `CameraService`'s lifetime (`session` is a `let`), so the only
        // thing worth redoing on every SwiftUI update is the mirroring
        // setup — see `configureMirroringIfNeeded()`'s own doc comment for
        // why that can't always be finished in `makeNSView` alone.
        nsView.configureMirroringIfNeeded()
    }

    /// A plain `NSView` whose backing layer *is* the preview layer (rather
    /// than a sublayer host), so `AVCaptureVideoPreviewLayer` automatically
    /// tracks the view's size via AppKit's normal layer-backing resize
    /// behavior, with no extra `layout()` override needed to keep the
    /// preview layer's frame in sync.
    final class PreviewContainerView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = previewLayer
            previewLayer.videoGravity = .resizeAspectFill
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        /// Flips the preview horizontally so it reads as an actual mirror —
        /// what the user sees matches what they'd see holding up a physical
        /// mirror, rather than the as-captured (left/right reversed from
        /// that) image most camera *recording* apps intentionally show.
        /// `automaticallyAdjustsVideoMirroring = false` is required before
        /// `isVideoMirrored` can be set explicitly; otherwise AVFoundation
        /// manages mirroring on its own and won't apply it here.
        ///
        /// `previewLayer.connection` is `nil` until the preview layer has
        /// actually resolved a connection to `session` — which can't happen
        /// until the session has a video input attached (`CameraService`
        /// adds that input from `start()`, which may run after this view is
        /// first created). Guarding on `automaticallyAdjustsVideoMirroring`
        /// still being `true` makes this both safe to call before the
        /// connection exists (a no-op) and idempotent once it does (only
        /// ever configures the connection once).
        func configureMirroringIfNeeded() {
            guard let connection = previewLayer.connection, connection.automaticallyAdjustsVideoMirroring else { return }
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
    }
}
