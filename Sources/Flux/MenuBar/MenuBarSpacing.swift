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

    /// True when **Flux's** compact spacing is in effect — i.e. the key holds
    /// exactly `compactValue`, not merely *some* value.
    ///
    /// This used to be `!= nil`, which read any pre-existing spacing (set by
    /// the user with `defaults write`, or by Ice/Bartender) as Flux's own.
    /// The toggle then showed ON at launch for a value Flux never wrote, and
    /// switching it off called `apply(compact: false)` — which cleared the
    /// key outright, destroying that setting instead of restoring it.
    static var isCompact: Bool {
        (CFPreferencesCopyValue(spacingKey, appID, user, host) as? Int) == compactValue
    }

    /// Write (compact) or restore both spacing keys.
    ///
    /// Turning compact ON stashes whatever was already there; turning it OFF
    /// puts that back, falling through to clearing the key (the true system
    /// default) only when there was nothing to restore. Blindly writing `nil`
    /// on the way out is what used to eat a user's own `NSStatusItemSpacing`.
    static func apply(compact: Bool) {
        if compact {
            stashCurrentValuesIfNeeded()
            let value = NSNumber(value: compactValue) as CFPropertyList
            CFPreferencesSetValue(spacingKey, value, appID, user, host)
            CFPreferencesSetValue(paddingKey, value, appID, user, host)
        } else {
            CFPreferencesSetValue(spacingKey, stashedValue(forKey: stashedSpacingKey), appID, user, host)
            CFPreferencesSetValue(paddingKey, stashedValue(forKey: stashedPaddingKey), appID, user, host)
            UserDefaults.standard.removeObject(forKey: stashedSpacingKey)
            UserDefaults.standard.removeObject(forKey: stashedPaddingKey)
        }
        CFPreferencesSynchronize(appID, user, host)
    }

    // MARK: - Restore stash
    //
    // Kept in Flux's OWN defaults domain, not the global one being edited:
    // this is Flux's bookkeeping about someone else's setting, and it must
    // not itself become another stray key in the global domain.

    private static let stashedSpacingKey = "flux.menuBar.previousStatusItemSpacing"
    private static let stashedPaddingKey = "flux.menuBar.previousStatusItemSelectionPadding"

    /// Records the pre-Flux values exactly once per compact session. Guarded
    /// on `isCompact` so re-applying (a settings sink re-delivering on launch,
    /// say) can't overwrite the real originals with Flux's own `compactValue`.
    private static func stashCurrentValuesIfNeeded() {
        guard !isCompact else { return }
        stash(CFPreferencesCopyValue(spacingKey, appID, user, host) as? Int, forKey: stashedSpacingKey)
        stash(CFPreferencesCopyValue(paddingKey, appID, user, host) as? Int, forKey: stashedPaddingKey)
    }

    private static func stash(_ value: Int?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// The stashed original, as something `CFPreferencesSetValue` accepts —
    /// `nil` (clear the key, restoring the true system default) when nothing
    /// was stashed, which is the common case of a user who never had a custom
    /// spacing to begin with.
    private static func stashedValue(forKey key: String) -> CFPropertyList? {
        guard UserDefaults.standard.object(forKey: key) != nil else { return nil }
        return NSNumber(value: UserDefaults.standard.integer(forKey: key)) as CFPropertyList
    }
}
