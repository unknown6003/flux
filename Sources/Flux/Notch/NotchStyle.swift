import Foundation

/// The canonical notch layout. The earlier release exposed a second Flux
/// envelope, which meant an existing install could silently keep a different
/// drawer size from the Alcove reference. The release now has one geometry
/// contract so switching pages cannot produce a subtle size jump.
enum NotchStyle: String, CaseIterable, Identifiable, Equatable {
    case alcove

    var id: String { rawValue }

    var title: String {
        "Alcove"
    }

    var subtitle: String {
        "Stable Alcove footprint"
    }
}
