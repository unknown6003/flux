import Foundation

enum AppInfo {
    static let name = "Flux"

    static var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return short ?? "1.0"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    static let tagline = "A calmer menu bar."
}
