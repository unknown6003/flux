import AppKit
import Carbon.HIToolbox

/// A key and Carbon modifier mask, as stored in `flux.hotkey.*` keys.
public struct Shortcut: Equatable, Sendable {
    public var keyCode: UInt32
    /// Carbon modifiers: `cmdKey`, `shiftKey`, `optionKey`, `controlKey`.
    public var carbonModifiers: UInt32

    public init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    init(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: carbon)
    }

    var displayText: String {
        var text = ""
        if carbonModifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    private static func keyName(_ code: UInt32) -> String {
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let name = special[Int(code)] { return name }
        let letters: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
            kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
            kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
            kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
            kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8",
            kVK_ANSI_9: "9",
        ]
        return letters[Int(code)] ?? String(format: L("shortcut.key", "Key %u"), code)
    }
}

/// A button that records one shortcut from local key events while it has
/// focus. It installs no global or local event monitor.
@MainActor
final class ShortcutRecorderView: NSButton {
    var shortcut: Shortcut? { didSet { refresh() } }
    var onRecord: ((Shortcut) -> Void)?
    private var recording = false { didSet { refresh() } }
    private let name: String

    init(name: String) {
        self.name = name
        super.init(frame: .zero)
        bezelStyle = .push
        target = self
        action = #selector(toggle)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        recording = false
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        if event.keyCode == UInt16(kVK_Escape) {
            recording = false
            return
        }
        let candidate = Shortcut(event: event)
        // A global shortcut needs at least one of ⌘, ⌃ or ⌥.
        let required = UInt32(cmdKey | controlKey | optionKey)
        guard candidate.carbonModifiers & required != 0 else {
            NSSound.beep()
            return
        }
        recording = false
        onRecord?(candidate)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    @objc private func toggle() {
        recording.toggle()
        if recording { window?.makeFirstResponder(self) }
    }

    private func refresh() {
        title = recording
            ? L("shortcut.recording", "Type Shortcut…")
            : (shortcut?.displayText ?? L("shortcut.none", "Record Shortcut"))
        setAccessibilityLabel(String(format: L("shortcut.ax", "%@ shortcut"), name))
        setAccessibilityValue(recording ? L("shortcut.recording", "Type Shortcut…") : shortcut?.displayText)
    }
}
