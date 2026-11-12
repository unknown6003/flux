import AppKit

struct StatusPreviewMenuWindow {
    let id: CGWindowID
    let application: String
    let displayID: CGDirectDisplayID
    let frame: CGRect
}

/// Reads only validated narrow MenuBarAgent surfaces. The owner supplies
/// screenshots; no display image or permission request belongs here.
@MainActor final class StatusMenuWindowPreview {
    private let windows: [StatusPreviewMenuWindow]
    private let displays: [StatusPreviewDisplay]
    private let takeImage: @MainActor (StatusPreviewMenuWindow) async throws -> CGImage

    init(windows: [StatusPreviewMenuWindow], displays: [StatusPreviewDisplay],
         capture: @escaping @MainActor (StatusPreviewMenuWindow) async throws -> CGImage) {
        self.windows = windows
        self.displays = displays
        self.takeImage = capture
    }

    func capture(_ plan: StatusPreviewPlan) async throws -> CGImage? {
        nil
    }
}
