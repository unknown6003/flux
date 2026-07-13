import SwiftUI
import AppKit
import Carbon.HIToolbox

/// The click-to-record shortcut field in Settings.
///
/// Recording has to happen at the **AppKit** layer: SwiftUI's key handling won't
/// give us raw modifier-only presses or let us swallow a chord like ⌘Q before the
/// app acts on it. So this is an `NSView` that becomes first responder while
/// recording and consumes every key event until it gets a valid chord or the user
/// backs out.
struct HotkeyRecorderView: NSViewRepresentable {
    @Binding var shortcut: HotkeyShortcut

    func makeNSView(context: Context) -> RecorderButton {
        let view = RecorderButton()
        view.onRecord = { shortcut = $0 }
        view.shortcut = shortcut
        return view
    }

    func updateNSView(_ view: RecorderButton, context: Context) {
        // Re-bind on every update: SwiftUI rebuilds this struct (and its `Binding`)
        // freely, and the callback captured back in `makeNSView` belongs to the
        // *original* struct. Refreshing it keeps recorded chords flowing into the
        // current binding rather than a stale one.
        view.onRecord = { shortcut = $0 }
        view.shortcut = shortcut
    }

    /// A button that flips into a "listening" state on click, then captures the
    /// next chord. While listening it is the first responder and returns `true`
    /// from `performKeyEquivalent`, so the chord never reaches the menu system —
    /// otherwise recording ⌘W would close the Settings window instead.
    final class RecorderButton: NSView {
        var onRecord: ((HotkeyShortcut) -> Void)?

        var shortcut: HotkeyShortcut = .default {
            didSet { needsDisplay = true }
        }

        private var isRecording = false {
            didSet { needsDisplay = true }
        }

        override var acceptsFirstResponder: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: 132, height: 26) }

        override func mouseDown(with event: NSEvent) {
            guard !isRecording else { return }
            isRecording = true
            window?.makeFirstResponder(self)
        }

        /// Key equivalents (anything with ⌘, plus Esc) are routed here *before*
        /// `keyDown`, so this is where a real chord has to be caught.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard isRecording else { return false }
            return handle(event)
        }

        override func keyDown(with event: NSEvent) {
            guard isRecording, handle(event) else {
                super.keyDown(with: event)
                return
            }
        }

        /// Returns `true` when the event was consumed.
        private func handle(_ event: NSEvent) -> Bool {
            // Esc cancels, leaving the existing binding untouched.
            if event.keyCode == UInt16(kVK_Escape) {
                endRecording()
                return true
            }
            // A modifier-less press can't be a global hotkey — ignore it and keep
            // listening rather than storing something that could never register.
            guard let recorded = HotkeyShortcut(event: event) else { return true }
            shortcut = recorded
            onRecord?(recorded)
            endRecording()
            return true
        }

        private func endRecording() {
            isRecording = false
            window?.makeFirstResponder(nil)
        }

        /// Clicking away while listening cancels, so the field can't get stuck.
        override func resignFirstResponder() -> Bool {
            isRecording = false
            return true
        }

        override func draw(_ dirtyRect: NSRect) {
            let radius: CGFloat = 6
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                    xRadius: radius, yRadius: radius)

            (isRecording ? Theme.accentWash : Theme.surfaceRaised).setFill()
            path.fill()

            (isRecording ? Theme.accent : Theme.hairline).setStroke()
            path.lineWidth = isRecording ? 1.5 : 1
            path.stroke()

            let text = isRecording ? "Type a shortcut…" : shortcut.displayString
            let color = isRecording ? Theme.accent : Theme.textPrimary
            let font = isRecording
                ? NSFont.systemFont(ofSize: 11)
                : NSFont.systemFont(ofSize: 13, weight: .medium)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(
                at: NSPoint(x: (bounds.width - size.width) / 2,
                            y: (bounds.height - size.height) / 2),
                withAttributes: attrs)
        }
    }
}
