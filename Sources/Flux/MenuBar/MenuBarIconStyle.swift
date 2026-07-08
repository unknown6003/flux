import Foundation

/// The glyph Flux draws for its chevron control item. Purely cosmetic — all
/// three behave identically. Kept deliberately small and monochrome to stay
/// nonintrusive in the menu bar.
enum MenuBarIconStyle: String, CaseIterable, Identifiable {
    case chevron
    case dot
    case line

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chevron: return "Chevron"
        case .dot: return "Dot"
        case .line: return "Line"
        }
    }

    /// SF Symbol shown when items are hidden (the "click me to reveal" state).
    var collapsedSymbol: String {
        switch self {
        case .chevron: return "chevron.left"
        case .dot: return "circle.fill"
        case .line: return "line.3.horizontal"
        }
    }

    /// SF Symbol shown when items are revealed (the "click me to re-hide" state).
    var revealedSymbol: String {
        switch self {
        case .chevron: return "chevron.right"
        case .dot: return "circle"
        case .line: return "xmark"
        }
    }
}
