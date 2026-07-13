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

    /// Which zones are revealed while arranging. On Macs with a notch, only the
    /// strip to the *right* of the notch can actually show status items — items
    /// pushed left of it vanish — so a user with more icons than fit there can't
    /// reveal every zone at once. The boundary-focused modes collapse the zone
    /// that isn't involved and show a single compact marker, freeing the most
    /// space for the edge being sorted. Bound directly by the Settings picker, so
    /// `MenuBarManager` observes it.
    enum Focus: String, CaseIterable, Identifiable {
        /// Reveal every zone at once — the default, best when it all fits.
        case all
        /// Sort the Shown ↔ Hidden edge: reveal Shown + Hidden, collapse
        /// Always-Hidden off-screen so its icons don't compete for space.
        case shownHidden
        /// Sort the Hidden ↔ Always-Hidden edge: reveal Hidden + Always-Hidden and
        /// show only the Always-Hidden marker, so the Shown zone is the only extra
        /// width competing for the space beside the notch.
        case hiddenAlwaysHidden

        var id: String { rawValue }

        /// Short label for the Settings segmented picker.
        var title: String {
            switch self {
            case .all:                return "All"
            case .shownHidden:        return "Shown · Hidden"
            case .hiddenAlwaysHidden: return "Hidden · Always"
            }
        }

        /// One-line explanation shown under the picker.
        var explanation: String {
            switch self {
            case .all:
                return "Every zone is on the bar. Best when your icons fit beside the notch."
            case .shownHidden:
                return "Always-Hidden is tucked away so you can sort which icons stay Shown vs. Hidden."
            case .hiddenAlwaysHidden:
                return "Shown stays put while you sort which Hidden icons move into Always-Hidden."
            }
        }
    }

    @Published var focus: Focus = .all

    /// True while arranging when Flux's revealed items don't all fit beside the
    /// notch, so the leftmost zone (and its marker) are pushed out of reach. Driven
    /// by `MenuBarManager`, which measures the live bar; surfaced in the Settings
    /// arrange panel and the floating hint as a warning.
    @Published private(set) var overflowsNotch = false

    /// How many icon-widths the leftmost marker is short by — the estimated number
    /// of icons that must move *out of* the crowded edge before it clears the notch.
    /// Powers the cascade coaching ("about N icons over"): each icon dragged across
    /// the marker frees roughly one icon-width, pulling the marker back toward view,
    /// so only the first move is blind. `0` when nothing overflows.
    @Published private(set) var overflowIconCount = 0

    /// True whenever items the user is trying to *see* are clipped behind the notch —
    /// during arranging (an edge won't fit) *or* during a normal reveal (revealed
    /// icons spill past it). Drives the notch highlight overlay. Distinct from
    /// `overflowsNotch`, which is arrange-only and drives the drawer's coaching.
    @Published private(set) var notchOverflow = false

    /// Installed by `MenuBarManager` to apply the real menu-bar side effects.
    /// Left `nil` in headless/preview contexts (snapshot, render) where there is
    /// no live engine — toggling then only flips the published flag.
    var onChange: ((Bool) -> Void)?

    func setArranging(_ on: Bool) {
        guard on != isArranging else { return }
        isArranging = on
        if !on {
            overflowsNotch = false   // clear stale warnings when arranging ends
            // The notch glow is left to the engine's next reveal-state measurement:
            // a normal reveal may still be clipping icons after arranging ends.
            focus = .all             // next session starts by revealing everything
        }
        onChange?(on)
    }

    func toggle() { setArranging(!isArranging) }

    /// Called by `MenuBarManager` after measuring the live bar.
    /// - `arrange`: the current arrange edge won't fit beside the notch (drawer warning).
    /// - `notch`: items the user is trying to see are clipped (notch glow) — a superset
    ///   of `arrange` that also covers normal reveals.
    /// - `iconCount`: estimated icons the leftmost marker is short by (0 when it fits).
    ///
    /// `arrange` is gated on `isArranging`, `notch` deliberately is not. The drawer
    /// warning is only ever meaningful while arranging, and the overflow monitor is a
    /// repeating timer that hops to the main actor — so a measurement taken just before
    /// the user clicked the chevron could otherwise land just *after* arranging ended
    /// and flash the banner during an ordinary reveal. Dropping a late `arrange: true`
    /// here makes that race unrepresentable instead of relying on every caller to check
    /// the flag first. The notch glow, by contrast, is supposed to fire outside Arrange
    /// Mode — a normal reveal can clip icons too — so it passes through untouched.
    func setOverflow(arrange: Bool, notch: Bool, iconCount: Int) {
        let arranging = isArranging && arrange
        let count = notch ? max(1, iconCount) : 0
        guard arranging != overflowsNotch || notch != notchOverflow || count != overflowIconCount
        else { return }
        overflowsNotch = arranging
        notchOverflow = notch
        overflowIconCount = count
    }
}
