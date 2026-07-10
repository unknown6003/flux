import Foundation

/// The three zones of the menu bar, mirroring Bartender's mental model.
///
/// Layout along the bar, left → right:
///
///     [ alwaysHidden items ] (⊟) [ hidden items ] (⊟) [ shown items ] (⌄) [ clock ]
///                            └ alwaysHidden divider    └ hidden divider   └ chevron
///
/// Each divider is one of Flux's own status items. Collapsing a divider expands
/// its width, pushing everything to its left off the visible menu bar.
enum MenuBarSection: String, CaseIterable, Codable, Identifiable {
    /// Always visible. Items live to the right of the hidden divider.
    case shown
    /// Hidden by default, revealed when the user clicks the chevron.
    case hidden
    /// Revealed only with a modifier (option-click) — Bartender's "Always Hide".
    case alwaysHidden

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .shown: return "Shown"
        case .hidden: return "Hidden"
        case .alwaysHidden: return "Always Hidden"
        }
    }

    /// A short tag for the live menu-bar marker. On notched Macs every point of
    /// menu-bar width is scarce — a full "Always Hidden" pill can be the difference
    /// between a zone landing on-screen or vanishing behind the notch — so the
    /// painted marker uses this compact form. The colour, tooltip, and the hint /
    /// Settings legend still carry the full name.
    var markerLabel: String {
        switch self {
        case .shown: return "Shown"
        case .hidden: return "Hidden"
        case .alwaysHidden: return "Always"
        }
    }

    var subtitle: String {
        switch self {
        case .shown: return "Always visible in the menu bar"
        case .hidden: return "Revealed when you click the Flux chevron"
        case .alwaysHidden: return "Revealed only with ⌥ (option) — kept out of the way"
        }
    }

    var symbolName: String {
        switch self {
        case .shown: return "eye"
        case .hidden: return "eye.slash"
        case .alwaysHidden: return "eye.slash.fill"
        }
    }
}
