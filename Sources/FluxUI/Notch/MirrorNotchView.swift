import AppKit
import SwiftUI

// Ported from Flux 0.21.35: Sources/Flux/Notch/Widgets/MirrorWidget.swift
// (MirrorExpandedView and CameraPreviewView). Text, layout, the 16 pt
// continuous corner and the selfie mirror flip are unchanged.

@MainActor
final class MirrorNotchModel: ObservableObject {
    @Published var status: MirrorWidgetStatus
    @Published var preview: NSView?
    let onAction: @MainActor (MirrorWidgetAction) -> Void

    init(status: MirrorWidgetStatus, preview: NSView?, onAction: @escaping @MainActor (MirrorWidgetAction) -> Void) {
        self.status = status
        self.preview = preview
        self.onAction = onAction
    }

    var gate: NotchPermissionGate {
        switch status {
        case .needsPermission: .notDetermined
        case .denied: .denied
        case .starting, .running, .unavailable, .interrupted, .failed: .granted
        }
    }
}

struct MirrorExpandedView: View {
    @ObservedObject var model: MirrorNotchModel

    var body: some View {
        PermissionGatedView(
            status: model.gate,
            icon: "video.fill",
            notDeterminedMessage: "Flux can show a quick mirror using your Mac's camera.",
            deniedMessage: "Camera access is off. Turn it on in System Settings to use the mirror.",
            request: { model.onAction(.requestPermission) },
            openSettings: { model.onAction(.openSettings) }
        ) {
            preview
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch model.status {
        case .unavailable, .failed:
            WidgetEmptyStateView(icon: "video.slash", message: "No camera found")
        default:
            ZStack(alignment: .bottom) {
                MirrorPreviewHost(preview: model.preview)
                    .scaleEffect(x: -1, y: 1, anchor: .center)
                if model.status != .running {
                    startingCaption
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
}

/// A rounded, clipped container for the parent's preview view.
private struct MirrorPreviewHost: NSViewRepresentable {
    let preview: NSView?

    func makeNSView(context: Context) -> Container {
        let view = Container()
        view.adopt(preview)
        return view
    }

    func updateNSView(_ nsView: Container, context: Context) {
        nsView.adopt(preview)
    }

    final class Container: NSView {
        private weak var hosted: NSView?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.cornerRadius = MirrorWidgetController.cornerRadius
            layer?.cornerCurve = .continuous
            layer?.masksToBounds = true
            setAccessibilityElement(false)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        func adopt(_ preview: NSView?) {
            guard hosted !== preview else { return }
            hosted?.removeFromSuperview()
            hosted = preview
            guard let preview else { return }
            preview.removeFromSuperview()
            preview.frame = bounds
            preview.autoresizingMask = [.width, .height]
            addSubview(preview)
        }

        override func layout() {
            super.layout()
            hosted?.frame = bounds
        }
    }
}
