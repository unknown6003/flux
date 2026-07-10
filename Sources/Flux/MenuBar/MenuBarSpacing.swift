import Foundation

/// Controls global macOS menu-bar item spacing via the undocumented
/// `NSStatusItemSpacing` / `NSStatusItemSelectionPadding` defaults, written to
/// the per-host global domain (the `defaults -currentHost -g …` location).
///
/// Shrinking these reclaims ~10pt of padding around **every** menu-bar icon, so
/// noticeably more of the user's icons fit beside the notch — the single biggest
/// lever Flux has against notch overflow, and it needs no special permission and
/// no private API. macOS reads the value when a process lays out its status
/// items, so a change takes full effect once the menu-bar apps next launch
/// (practically, after the next login); we surface that in the UI rather than
/// force anything to restart.
enum MenuBarSpacing {
    /// macOS's built-in spacing is ~16pt; 6 is tight but still visually separates
    /// icons. Reclaims ~10pt per icon — enough that a dozen-plus icons stop
    /// overflowing behind the notch.
    static let compactValue = 6

    private static let spacingKey = "NSStatusItemSpacing" as CFString
    private static let paddingKey = "NSStatusItemSelectionPadding" as CFString
    // AnyApplication == the global domain (`-g`); CurrentHost == the `-currentHost`
    // scope. This is exactly where the working `defaults -currentHost -g` write lands.
    private static let appID = kCFPreferencesAnyApplication
    private static let user = kCFPreferencesCurrentUser
    private static let host = kCFPreferencesCurrentHost

    /// True when Flux's compact spacing is currently in effect (the key is set).
    static var isCompact: Bool {
        (CFPreferencesCopyValue(spacingKey, appID, user, host) as? Int) != nil
    }

    /// Write (compact) or clear (restore the system default) both spacing keys.
    static func apply(compact: Bool) {
        let value: CFPropertyList? = compact ? NSNumber(value: compactValue) : nil
        CFPreferencesSetValue(spacingKey, value, appID, user, host)
        CFPreferencesSetValue(paddingKey, value, appID, user, host)
        CFPreferencesSynchronize(appID, user, host)
    }
}
