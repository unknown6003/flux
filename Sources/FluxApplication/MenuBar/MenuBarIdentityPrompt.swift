import AppKit

@MainActor final class MenuBarIdentityPrompt {
    private var alert: NSAlert?
    private var completion: CheckedContinuation<Bool, Never>?

    func confirm(name: String) async -> Bool {
        guard alert == nil, let window = NSApp.keyWindow, window.attachedSheet == nil else { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Review \(name)"
                alert.informativeText = "This copy no longer matches its saved signing identity. Approve it only if you installed it from a source you trust. Your saved visibility choice will be kept."
                alert.addButton(withTitle: "Use This Copy")
                alert.addButton(withTitle: "Cancel")
                alert.buttons[0].keyEquivalent = ""
                alert.buttons[1].keyEquivalent = "\r"
                self.alert = alert
                self.completion = continuation
                alert.beginSheetModal(for: window) { [weak self] response in
                    self?.finish(response == .alertFirstButtonReturn, dismiss: false)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(false) }
        }
    }

    private func finish(_ accepted: Bool, dismiss: Bool = true) {
        guard let completion else { return }
        self.completion = nil
        let alert = self.alert
        self.alert = nil
        if dismiss, let alert, let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .cancel) }
        completion.resume(returning: accepted)
    }
}
