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
                // Corner rounding is applied by `PreviewContainerView`'s own
                // layer rather than a SwiftUI `.clipShape`: the preview is a
                // `CALayer` sublayer of an AppKit view, which a SwiftUI clip
                // mask doesn't reliably reach.
                CameraPreviewView(service: service)
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
        WidgetEmptyStateView(icon: "video.slash", message: "No camera found")
    }
}

// MARK: - Live preview (AppKit bridge)

/// Hosts `CameraService.previewLayer`. A plain `NSViewRepresentable` rather
/// than any SwiftUI-native camera view, since SwiftUI has no such view — this
/// is the standard AVFoundation-on-AppKit bridge.
///
/// ## M12 crash fix: this view owns NO capture state
/// It neither creates the preview layer nor touches its capture connection —
/// it only re-parents the service's single, long-lived layer and keeps that
/// layer's geometry matched to its own bounds. Both of the things it used to
/// do (build a fresh `AVCaptureVideoPreviewLayer` per mount, and configure
/// `AVCaptureConnection.isVideoMirrored` on a
/// `.AVCaptureSessionDidStartRunning` observer plus a 500ms retry loop) were
/// session mutations happening at SwiftUI's mount/teardown timing rather than
/// the capture session's — which is precisely the timing that collapsing and
/// expanding the notch scrambles. See `CameraService.previewLayer` and
/// `CameraService.previewMirrorTransform` for the full reasoning.
private struct CameraPreviewView: NSViewRepresentable {
    @ObservedObject var service: CameraService

    func makeNSView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.adopt(service.previewLayer)
        return view
    }

    func updateNSView(_ nsView: PreviewContainerView, context: Context) {
        // Idempotent, and cheap when nothing changed — `adopt` no-ops if it's
        // already hosting this exact layer. Re-asserted here (rather than
        // only in `makeNSView`) because SwiftUI may reuse a representable's
        // NSView across a re-render in which some *other* instance of this
        // view took the shared layer away.
        nsView.adopt(service.previewLayer)
    }

    /// A plain layer-backed `NSView` that HOSTS the service's shared preview
    /// layer as a sublayer, and keeps its geometry matched to its own bounds.
    ///
    /// Deliberately a sublayer rather than the view's backing layer (which is
    /// what this used to be): the layer outlives this view — it belongs to
    /// `CameraService` — so it can't be handed to AppKit as a layer this view
    /// owns and discards. Hosting it also means the geometry sync below is
    /// explicit, which is what lets it be done with implicit CA animations
    /// disabled: the notch panel resizes its content continuously through the
    /// expand/collapse spring, and a preview layer that implicitly animated
    /// each of those ~60-120 bounds changes visibly lagged and stretched
    /// behind the shape it sits in.
    final class PreviewContainerView: NSView {
        /// Matches the expanded panel's inner corner rounding.
        private static let cornerRadius: CGFloat = 16

        /// The service-owned layer this view currently hosts, if any.
        private weak var hostedLayer: CALayer?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.cornerRadius = Self.cornerRadius
            layer?.cornerCurve = .continuous
            layer?.masksToBounds = true
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        /// Re-parents `previewLayer` into this view. A no-op when it's already
        /// hosted here, so `updateNSView` can call it on every SwiftUI
        /// invalidation. `addSublayer` removes the layer from whatever
        /// superlayer it had, which is exactly the handoff wanted when a
        /// collapse's outgoing preview view is still alive (mid fade-out)
        /// while an expand has already built its replacement.
        ///
        /// ## Only a view that is actually on screen may take the layer
        /// The `window != nil` gate is load-bearing, not defensive. Two
        /// `PreviewContainerView`s genuinely coexist for the ~0.35s of a
        /// collapse transition, `updateNSView` re-asserts adoption on EVERY
        /// SwiftUI invalidation, and the order SwiftUI updates the two
        /// instances in is undefined. `service.isRunning` flipping true is
        /// exactly such an invalidation and lands squarely inside that
        /// window — so without this gate the *outgoing*, fading-out view
        /// could win the race and pull the layer back out of the panel the
        /// user is actually looking at, leaving it black until something
        /// else happened to trigger a re-layout.
        func adopt(_ previewLayer: CALayer) {
            hostedLayer = previewLayer
            guard window != nil else { return }
            guard previewLayer.superlayer !== layer else { return }
            layer?.addSublayer(previewLayer)
            layoutHostedLayer()
        }

        /// A view that was built before it had a window (SwiftUI mounts
        /// representables that way) claims the layer the moment it lands on
        /// screen — the other half of the `window != nil` gate above.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let hostedLayer { adopt(hostedLayer) }
        }

        override func layout() {
            super.layout()
            // Reclaim the layer, but ONLY when it is genuinely orphaned —
            // its current superlayer belongs to a view that has left the
            // window (or to nothing at all).
            //
            // The last clause is what keeps this from being worse than the
            // problem. Without it the test is merely "somebody else has it",
            // and during the ~0.35s when both preview views are alive and
            // BOTH in the window, each would re-adopt on its own `layout()`.
            // `addSublayer` implicitly removes the layer from the other
            // view's backing layer, which dirties that view's layout, which
            // re-adopts, which dirties this one: a mutual loop that
            // re-parents every frame rather than converging — and whichever
            // view happens to hold it when the outgoing one is removed
            // decides the outcome, so it can still end orphaned with no
            // further `layout()` coming to rescue it.
            if let hostedLayer, window != nil, hostedLayer.superlayer !== layer,
               (hostedLayer.superlayer?.delegate as? NSView)?.window == nil {
                adopt(hostedLayer)
            }
            layoutHostedLayer()
        }

        /// Sets `bounds`/`position` rather than `frame`: `frame` is a derived
        /// property on a layer carrying a non-identity transform (this one
        /// carries `CameraService.previewMirrorTransform`), so writing the two
        /// underlying properties directly is the unambiguous form.
        private func layoutHostedLayer() {
            guard let hostedLayer, hostedLayer.superlayer === layer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostedLayer.bounds = CGRect(origin: .zero, size: bounds.size)
            hostedLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
        }
    }
}
