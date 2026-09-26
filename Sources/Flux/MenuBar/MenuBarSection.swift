import Foundation

/// The three places an icon can live in Flux.
enum MenuBarSection: String, CaseIterable, Codable, Identifiable {
    case shown
    case hidden
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
        case .alwaysHidden: return "Revealed only with Option-click"
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
