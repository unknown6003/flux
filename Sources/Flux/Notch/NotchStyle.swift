import Foundation

/// The two supported notch layouts. Both styles use a solid-black surface so
/// the collapsed shape disappears into the camera housing; the choice only
/// changes the expanded drawer's proportions and content footprint.
enum NotchStyle: String, CaseIterable, Identifiable, Equatable {
    case alcove
    case flux

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alcove: return "Alcove"
        case .flux: return "Flux"
        }
    }

    var subtitle: String {
        switch self {
        case .alcove: return "Compact, content-sized drawer"
        case .flux: return "Roomier fixed drawer"
        }
    }
}
