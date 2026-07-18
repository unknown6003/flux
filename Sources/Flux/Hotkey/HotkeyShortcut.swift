import AppKit
import Carbon.HIToolbox

/// A user-recordable global hotkey: a virtual key code plus a modifier mask.
///
/// Stored in **Carbon's** representation because `RegisterEventHotKey` — still the
/// only dependency-free way to get a system-wide hotkey — speaks Carbon. The
/// AppKit side (the recorder view) hands us `NSEvent.ModifierFlags`, so the
/// conversion lives here rather than being duplicated at each call site.
struct HotkeyShortcut: Equatable {
    /// Carbon virtual key code (`kVK_*`).
    var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey | optionKey | controlKey | shiftKey`).
    var carbonModifiers: UInt32

    /// ⌃⌥⌘F — Flux's default.
    ///
    /// The old default (⌥⌘B) collides with real shortcuts: it's Favourites Bar in
    /// Safari, and Build in several editors. A global hotkey wins over the focused
    /// app's, so a collision silently breaks that app. Three modifiers puts this
    /// outside the space macOS and mainstream apps assign by default, while staying
    /// a one-hand chord.
    static let `default` = HotkeyShortcut(
        keyCode: UInt32(kVK_ANSI_F),
        carbonModifiers: UInt32(controlKey | optionKey | cmdKey)
    )

    /// ⌃⌥⌘N — the notch toggle's default, in the same three-modifier space as
    /// `.default` (⌃⌥⌘F) so the two built-in hotkeys never collide with each
    /// other or with mainstream app shortcuts.
    static let notchDefault = HotkeyShortcut(
        keyCode: UInt32(kVK_ANSI_N),
        carbonModifiers: UInt32(controlKey | optionKey | cmdKey)
    )

    /// A hotkey needs at least one modifier — registering a bare key would swallow
    /// that keypress system-wide, in every app.
    var isValid: Bool { carbonModifiers != 0 }

    // MARK: AppKit bridging

    /// Build from a recorded `NSEvent`, keeping only the four modifiers Carbon can
    /// register. Returns `nil` for a modifier-less press, which is never registrable.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option)  { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }
        guard carbon != 0 else { return nil }
        self.keyCode = UInt32(event.keyCode)
        self.carbonModifiers = carbon
    }

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    // MARK: Display

    /// The shortcut as macOS writes it — modifiers in the canonical ⌃⌥⇧⌘ order,
    /// then the key. e.g. `⌃⌥⌘F`.
    var displayString: String {
        var out = ""
        if carbonModifiers & UInt32(controlKey) != 0 { out += "⌃" }
        if carbonModifiers & UInt32(optionKey)  != 0 { out += "⌥" }
        if carbonModifiers & UInt32(shiftKey)   != 0 { out += "⇧" }
        if carbonModifiers & UInt32(cmdKey)     != 0 { out += "⌘" }
        return out + Self.keyName(keyCode)
    }

    /// A printable name for a virtual key code. Covers the keys a user can
    /// plausibly bind; anything unmapped falls back to its raw code so the UI never
    /// renders an empty shortcut.
    static func keyName(_ code: UInt32) -> String {
        if let named = namedKeys[Int(code)] { return named }
        if let letter = letterKeys[Int(code)] { return letter }
        return "Key \(code)"
    }

    private static let letterKeys: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
        kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
        kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
        kVK_ANSI_Grave: "`",
    ]

    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12",
    ]
}
