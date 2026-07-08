import Foundation
import Combine

/// Transient, non-persisted bridge for **Arrange Menu Bar** mode.
///
/// The menu-bar engine (`MenuBarManager`) does the real work — showing labeled
/// zone markers in the live bar and revealing every icon so the user can ⌘-drag
/// each one into the zone they want. This tiny object just *publishes* whether
/// arranging is active, so the Settings window and the status-item menu can both
/// reflect it and toggle it from either side.
///
/// It is deliberately **not** a preference: it never touches `UserDefaults` and
/// always starts `false`, so the app never relaunches into arrange mode.
@MainActor
final class MenuBarArranger: ObservableObject {
    /// True while the user is arranging zones (labeled markers shown in the bar).
    @Published private(set) var isArranging = false

    /// Installed by `MenuBarManager` to apply the real menu-bar side effects.
    /// Left `nil` in headless/preview contexts (snapshot, render) where there is
    /// no live engine — toggling then only flips the published flag.
    var onChange: ((Bool) -> Void)?

    func setArranging(_ on: Bool) {
        guard on != isArranging else { return }
        isArranging = on
        onChange?(on)
    }

    func toggle() { setArranging(!isArranging) }
}
