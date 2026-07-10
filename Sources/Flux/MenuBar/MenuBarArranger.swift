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

    /// Which zones are revealed while arranging. On Macs with a notch, a user with
    /// more icons than fit beside it can't reveal every zone at once — the leftmost
    /// spills behind the notch. `.shownHidden` tucks Always-Hidden away so fewer
    /// icons compete for the space while the Shown ↔ Hidden boundary is sorted.
    /// Bound directly by the Settings picker, so `MenuBarManager` observes it.
    enum Focus: String, CaseIterable, Identifiable {
        /// Reveal every zone at once — the default, best when it all fits.
        case all
        /// Reveal Shown + Hidden only; keep Always-Hidden collapsed off-screen.
        case shownHidden

        var id: String { rawValue }
        var title: String {
            switch self {
            case .all:         return "All zones"
            case .shownHidden: return "Shown & Hidden"
            }
        }
    }

    @Published var focus: Focus = .all

    /// True while arranging when Flux's revealed items don't all fit beside the
    /// notch, so the leftmost zone (and its marker) are pushed out of reach. Driven
    /// by `MenuBarManager`, which measures the live bar; surfaced in the Settings
    /// arrange panel and the floating hint as a warning.
    @Published private(set) var overflowsNotch = false

    /// Installed by `MenuBarManager` to apply the real menu-bar side effects.
    /// Left `nil` in headless/preview contexts (snapshot, render) where there is
    /// no live engine — toggling then only flips the published flag.
    var onChange: ((Bool) -> Void)?

    func setArranging(_ on: Bool) {
        guard on != isArranging else { return }
        isArranging = on
        if !on {
            overflowsNotch = false   // clear stale warnings when arranging ends
            focus = .all             // next session starts by revealing everything
        }
        onChange?(on)
    }

    func toggle() { setArranging(!isArranging) }

    /// Called by `MenuBarManager` after measuring the live bar.
    func setOverflow(_ over: Bool) {
        guard over != overflowsNotch else { return }
        overflowsNotch = over
    }
}
