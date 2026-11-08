import Foundation

/// Exact legacy data paths. This value creates no folder or storage client.
public struct ApplicationFiles: Sendable {
    public let root: URL
    public var shelf: URL { root.appendingPathComponent("Shelf", isDirectory: true) }
    public var clipboardHistory: URL { root.appendingPathComponent("clipboard-history.json") }

    public init(applicationSupport: URL) { root = applicationSupport.appendingPathComponent("Flux", isDirectory: true) }

    /// Read before the instance lease, migration, session marker or analytics.
    /// The existence of a lock file alone must not turn a new profile into an upgrade.
    public var hasExistingData: Bool {
        [shelf, clipboardHistory].contains {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }
}
