import Darwin
import Foundation
import FluxCore
import FluxPlatform

/// Diagnostic commands only. A hide requires an explicit environment guard.
/// The journal is prepared before any OS write, so an independent watchdog can restore it.
@main struct VisibilityProbe {
    private struct Journal: Codable {
        let lease: NativeVisibilityLease
        let executableURLs: [URL]
    }

    static func main() async {
        do { try await run() }
        catch { print("Visibility probe failed: \(error)"); exit(1) }
    }

    private static func run() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else { throw Check.arguments }
        let channel = try NativePreferenceChannel()
        switch args[1] {
        case "prepare":
            guard args.count == 5, let application = ApplicationID(rawValue: args[2]) else { throw Check.arguments }
            let journalURL = URL(fileURLWithPath: args[3])
            try validateDirectory(journalURL.deletingLastPathComponent())
            guard !FileManager.default.fileExists(atPath: journalURL.path) else { throw Check.journalExists }
            let executable = URL(fileURLWithPath: args[4])
            let aliases = Array(Set([executable.standardizedFileURL, executable.resolvingSymlinksInPath()]))
            let document = try await channel.read()
            let entry = try document.inspect(application, executableURLs: aliases)
            guard entry.allowed else { throw Check.alreadyHidden }
            let journal = Journal(lease: .init(application: application, entry: entry, written: false), executableURLs: aliases)
            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
            print("prepared allowed=true aliases=unambiguous")
        case "hide", "restore", "read":
            guard args.count == 3 else { throw Check.arguments }
            let journal = try load(URL(fileURLWithPath: args[2]))
            if args[1] == "hide" {
                guard ProcessInfo.processInfo.environment["FLUX_ALLOW_NATIVE_VISIBILITY_PROBE"] == "1" else { throw Check.guardRequired }
                try await channel.apply(journal.lease, executableURLs: journal.executableURLs)
            } else if args[1] == "restore" {
                try await channel.restore(journal.lease, executableURLs: journal.executableURLs)
            }
            let entry = try await channel.read().inspect(journal.lease.application, executableURLs: journal.executableURLs)
            print("allowed=\(entry.allowed)")
        default: throw Check.arguments
        }
    }

    private static func load(_ url: URL) throws -> Journal {
        try validateDirectory(url.deletingLastPathComponent())
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) <= 65536 else { throw Check.unsafeJournal }
        return try JSONDecoder().decode(Journal.self, from: Data(contentsOf: url))
    }

    private static func validateDirectory(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else { throw Check.unsafeJournal }
    }

    private enum Check: Error { case arguments, journalExists, alreadyHidden, guardRequired, unsafeJournal }
}
